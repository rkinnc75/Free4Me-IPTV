import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_tv/widgets/dpad_text_field.dart';
import 'package:animations/animations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:form_builder_validators/form_builder_validators.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/epg_service.dart';
import 'package:open_tv/backend/settings_io.dart';
import 'package:open_tv/backend/export_server.dart'; // fix368
import 'package:open_tv/models/device_detector.dart'; // fix368
import 'package:qr_flutter/qr_flutter.dart'; // fix368
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/correction_modal.dart';
import 'package:open_tv/home.dart';
import 'package:open_tv/widgets/sources_refresh_dialog.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:open_tv/models/steps.dart';
import 'package:open_tv/models/view_type.dart';

/// fix381: replaced the 4–5 screen Add Source wizard (name → url →
/// username → password → epgUrl) with a single form page that
/// conditionally shows the fields relevant to the selected source
/// type, all on one screen. The user picks the source type, sees
/// every required field at once, and taps "Add Source" once.
///
/// The welcome/finish pages and the import-backup / receive-via-QR
/// flows are unchanged (they were the working parts of the wizard
/// and were already single-screen).
class Setup extends StatefulWidget {
  final bool showAppBar;
  const Setup({super.key, this.showAppBar = false});

  @override
  State<Setup> createState() => _SetupState();
}

class _SetupState extends State<Setup> {
  Steps step = Steps.welcome;
  SourceType selectedSourceType = SourceType.xtream;
  bool isForward = true;
  bool formValid = false;
  bool _isFinishing = false;
  String? _pickedM3uPath; // fix381: M3U file picker result.

  // fix381: one FormBuilder for the whole form, plus one
  // TextEditingController per visible field and one focus node per
  // field for explicit D-pad order (see Steps.form page below).
  final _formKey = GlobalKey<FormBuilderState>();
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _epgUrlController = TextEditingController();
  final _nameFocus = FocusNode();
  final _urlFocus = FocusNode();
  final _filePickerFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _epgUrlFocus = FocusNode();
  final nextButtonFocusNode = FocusNode();
  Set<String> existingSourceNames = {};

  @override
  void initState() {
    super.initState();
    nextButtonFocusNode.requestFocus();
    _nameController.addListener(_recomputeFormValid);
    _urlController.addListener(_recomputeFormValid);
    _usernameController.addListener(_recomputeFormValid);
    _passwordController.addListener(_recomputeFormValid);
    _epgUrlController.addListener(_recomputeFormValid);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _epgUrlController.dispose();
    _nameFocus.dispose();
    _urlFocus.dispose();
    _filePickerFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _epgUrlFocus.dispose();
    nextButtonFocusNode.dispose();
    super.dispose();
  }

  /// fix381: auto-fix a raw M3U URL — prepend http:// when no scheme
  /// is present. (Same as the pre-fix381 per-step helper.)
  String _autoFixM3uUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return trimmed;
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      return 'http://$trimmed';
    }
    return trimmed;
  }

  /// fix381: re-evaluate form validity from the current controllers
  /// and the picked-file path. Called on every controller change. The
  /// form's own validators run per-field on user interaction; this
  /// is the cross-field "are all REQUIRED fields for this source
  /// type populated and syntactically valid" check.
  void _recomputeFormValid() {
    if (!mounted) return;
    setState(() {
      final nameOk = _nameController.text.trim().isNotEmpty &&
          !existingSourceNames.contains(_nameController.text.trim());
      final urlOk = _urlController.text.trim().isNotEmpty;
      final userOk = _usernameController.text.isNotEmpty;
      final passOk = _passwordController.text.isNotEmpty;
      final fileOk = _pickedM3uPath != null && _pickedM3uPath!.isNotEmpty;
      switch (selectedSourceType) {
        case SourceType.xtream:
          formValid = nameOk && urlOk && userOk && passOk;
          break;
        case SourceType.m3uUrl:
          formValid = nameOk && urlOk;
          break;
        case SourceType.m3u:
          formValid = nameOk && fileOk;
          break;
      }
    });
  }

  Future<void> finish() async {
    if (_isFinishing) return;
    _isFinishing = true;
    final sourceName = _nameController.text.trim();
    final epgUrlValue = _epgUrlController.text.trim();
    final urlValue = _urlController.text.trim();

    // Progress dialog state
    String progressStatus = 'Connecting…';
    void Function(void Function())? dialogSetState;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (sCtx, setSt) {
          dialogSetState = setSt;
          return AlertDialog(
            title: Text('Setting up "$sourceName"…'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(
                  progressStatus,
                  style: Theme.of(sCtx).textTheme.bodySmall,
                ),
              ],
            ),
          );
        },
      ),
    );

    try {
      await Utils.processSource(
        Source(
          name: sourceName,
          sourceType: selectedSourceType,
          url: selectedSourceType == SourceType.m3u
              ? _pickedM3uPath!
              : await fixUrl(urlValue),
          username: selectedSourceType == SourceType.xtream
              ? _usernameController.text
              : null,
          password: selectedSourceType == SourceType.xtream
              ? _passwordController.text
              : null,
          epgUrl: epgUrlValue.isEmpty ? null : epgUrlValue,
        ),
        false,
        (status) {
          dialogSetState?.call(() => progressStatus = status);
        },
      );

      if (mounted) Navigator.of(context, rootNavigator: true).pop();

      // Trigger EPG in background if an EPG URL was supplied. Fire-and-forget
      // so the user reaches the Home screen immediately; EPG imports silently.
      if (epgUrlValue.isNotEmpty) {
        final sources = await Sql.getSources();
        final saved =
            sources.where((s) => s.name == sourceName).firstOrNull;
        if (saved != null) {
          // ignore: unawaited_futures
          EpgService.refreshSource(saved);
        }
      }

      if (mounted) setState(() => step = Steps.finish);
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add source: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      _isFinishing = false;
    }
  }

  Future<String> fixUrl(String url) async {
    var uri = Uri.parse(url.trim());
    if (uri.scheme.isEmpty) {
      uri = Uri.parse("http://$uri");
    }
    if (uri.path == "/" || uri.path.isEmpty) {
      if (await showXtreamCorrectionModal()) {
        uri = uri.resolve("player_api.php");
      }
    }
    return uri.toString();
  }

  Future showXtreamCorrectionModal() async {
    return await showDialog(
      context: context,
      builder: (context) => CorrectionModal(),
    );
  }

  /// fix381: M3U file picker. Stores the picked path in [_pickedM3uPath]
  /// and recomputes form validity. The path is used by [finish] when
  /// the source type is [SourceType.m3u].
  Future<bool> selectFile() async {
    final path = (await FilePicker.platform.pickFiles())?.files.single.path;
    if (path == null) return false;
    if (!mounted) return false; // finding 164
    setState(() {
      _pickedM3uPath = path;
    });
    _recomputeFormValid();
    return true;
  }

  void prevStep() {
    isForward = false;
    if (step == Steps.form) {
      setState(() => step = Steps.sourceType);
    } else if (step == Steps.sourceType) {
      setState(() => step = Steps.welcome);
    } else if (step == Steps.finish) {
      setState(() => step = Steps.form);
    } else {
      return; // Steps.welcome — no previous step
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (step == Steps.welcome) {
        nextButtonFocusNode.requestFocus();
      }
    });
  }

  Future<void> handleNext() async {
    isForward = true;
    if (step == Steps.welcome) {
      setState(() => step = Steps.sourceType);
    } else if (step == Steps.sourceType) {
      // Reset URL when the user changes source type (matches the
      // pre-fix381 behaviour: tapping a different source-type card
      // cleared the URL field so an old URL from a different type
      // doesn't leak into the new one).
      if (selectedSourceType == SourceType.m3u) {
        // m3u uses file picker, not URL — clear the URL controller
        // and any previously-picked path so the form is fresh.
        _urlController.clear();
        setState(() => _pickedM3uPath = null);
      } else {
        _urlController.clear();
      }
      _recomputeFormValid();
      setState(() => step = Steps.form);
    } else if (step == Steps.form) {
      // finding 163: run the FormBuilder field validators (incl. the URL
      // format check in _buildUrlField) before proceeding, so a syntactically
      // invalid URL is rejected on the submit press instead of only gating the
      // button's enabled state.
      if (!(_formKey.currentState?.validate() ?? false)) {
        return;
      }
      // Duplicate name check.
      final name = _nameController.text.trim();
      if (await Sql.sourceNameExists(name)) {
        existingSourceNames.add(name);
        _formKey.currentState?.validate();
        return;
      }
      // M3U URL: auto-fix the URL.
      if (selectedSourceType == SourceType.m3uUrl) {
        final raw = _urlController.text.trim();
        final fixed = _autoFixM3uUrl(raw);
        if (fixed != raw && fixed.isNotEmpty) {
          _urlController.text = fixed;
        }
      }
      await finish();
      return;
    } else if (step == Steps.finish) {
      navigateToHome();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (step == Steps.welcome) {
        nextButtonFocusNode.requestFocus();
      } else if (step == Steps.form) {
        _nameFocus.requestFocus();
      }
    });
  }

  void navigateToHome() {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => Home(
          home: HomeManager(filters: Filters(viewType: ViewType.all)),
        ),
      ),
      (route) => false,
    );
  }

  /// fix511: first-run setup is the one place a brand-new install must be
  /// diagnosable even though debug logging defaults OFF — a failed backup/QR
  /// import here otherwise leaves the user stuck with no log (the 6.8 MB
  /// upload that disconnected left no trace). Force the file logger on for the
  /// rest of this app SESSION (not persisted; a normal launch still respects
  /// the saved setting) so the whole import path is captured.
  Future<void> _ensureSetupLogging(String flow) async {
    if (AppLog.enabled) return;
    await AppLog.setEnabled(true);
    await AppLog.stampVersion('setup diagnostics ($flow, fix511)');
    AppLog.info('Setup: diagnostic logging force-enabled for $flow on a '
        'fresh install (debug-off); session-only, not persisted');
  }

  /// Import a backup file from the welcome screen. If the import
  /// produces at least one source, block on a refresh of all enabled
  /// sources with a progress dialog, then jump straight to
  /// Home with channels actually loaded. Otherwise stay on the
  /// welcome screen so the user can fall back to adding a source
  /// manually.
  ///
  /// SettingsIo.importFromFile() handles the file picker, schema
  /// validation, the confirm dialog, and persistence. We just react
  /// to its outcome.
  Future<void> _importBackup() async {
    await _ensureSetupLogging('import-backup');
    AppLog.info('Setup: import backup — started');
    // fix513: guard context across the logging-setup await above before
    // passing it into importFromFile (use_build_context_synchronously).
    if (!mounted) return;

    final imported = await SettingsIo.importFromFile(context);
    if (!mounted) return;
    if (!imported) {
      AppLog.info('Setup: import backup — cancelled or failed, staying on welcome');
      return;
    }

    AppLog.info('Setup: import backup — file accepted, checking sources');

    // Bail early if the import produced no sources (e.g. settings-only
    // backup). No point showing a refresh dialog with nothing to do.
    final sources = await Sql.getSources();
    if (!mounted) return;

    if (sources.isEmpty) {
      AppLog.info('Setup: import backup — no sources in backup, staying on welcome');
      return;
    }

    final enabledCount = sources.where((s) => s.enabled).length;
    AppLog.info(
      'Setup: import backup — ${sources.length} sources imported'
      ' ($enabledCount enabled):'
      ' ${sources.map((s) => '"${s.name}"(${s.enabled ? "on" : "off"})').join(", ")}',
    );
    AppLog.info('Setup: import backup — launching source refresh dialog');

    // Block on a full refresh of all enabled sources with a progress
    // dialog. The user lands on Home only after channels are actually
    // loaded — no more "empty Home screen while the refresh runs in the
    // background" experience.
    await showSourcesRefreshDialog(context);

    if (!mounted) return;
    AppLog.info('Setup: import backup — refresh dialog complete, navigating to Home');
    navigateToHome();
  }

  /// fix368: receive sources from another device via the LAN export portal
  /// during first-run setup.
  Future<void> _receiveViaQr() async {
    await _ensureSetupLogging('receive-via-QR');
    AppLog.info('Setup: receive via QR — starting portal');
    var imported = 0;
    final deviceName = await DeviceDetector.deviceLabel();
    if (!mounted) return;

    final server = ExportServer(
      const [],
      deviceName: deviceName,
      onImportSources: (bytes) async {
        AppLog.info('Setup: receive via QR — upload received'
            ' ${bytes.length} bytes; parsing sources');
        try {
          final n = await SettingsIo.importSourcesOnly(bytes);
          AppLog.info('Setup: receive via QR — importSourcesOnly returned $n');
          if (n > 0) imported = n;
          return n;
        } catch (e) {
          AppLog.error('Setup: receive via QR — importSourcesOnly threw — $e');
          return -1;
        }
      },
    );

    List<String> urls;
    try {
      urls = await server.start();
    } catch (e) {
      AppLog.error('Setup: receive via QR — server start failed — $e');
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Could not start receiver'),
            content: Text('The local network server could not start.\n\n$e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return;
    }

    final primaryUrl = urls.isNotEmpty ? urls.first : '';
    try {
      if (mounted) {
        await showDialog<void>(
          context: context,
          barrierDismissible: true,
          builder: (ctx) => AlertDialog(
            title: const Text('Receive sources from another device'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'On your phone or PC (same Wi-Fi), open this address and '
                  'upload a settings/sources backup:',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                if (primaryUrl.isNotEmpty)
                  QrImageView(
                    data: primaryUrl,
                    size: 200,
                    backgroundColor: Colors.white,
                  ),
                const SizedBox(height: 12),
                for (final u in urls)
                  SelectableText(u, textAlign: TextAlign.center),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done'),
              ),
            ],
          ),
        );
      }
    } finally {
      await server.stop();
    }
    if (!mounted) return;

    if (imported <= 0) {
      AppLog.info('Setup: receive via QR — closed, no sources imported');
      return;
    }
    AppLog.info('Setup: receive via QR — $imported source(s) imported,'
        ' launching refresh');
    await showSourcesRefreshDialog(context);
    if (!mounted) return;
    navigateToHome();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: step == Steps.welcome,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) prevStep();
      },
      child: Scaffold(
        appBar: widget.showAppBar ? AppBar() : null,
        body: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24.0,
                  vertical: 16,
                ),
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(
                    begin: 0,
                    // fix381: progress bar uses the new 4-step flow.
                    end: (step.index + 1) / Steps.values.length,
                  ),
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeInOut,
                  builder: (context, value, child) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: value,
                        minHeight: 6,
                      ),
                    );
                  },
                ),
              ),
              Expanded(
                child: PageTransitionSwitcher(
                  duration: const Duration(milliseconds: 400),
                  reverse: !isForward,
                  transitionBuilder:
                      (child, primaryAnimation, secondaryAnimation) {
                        return SharedAxisTransition(
                          animation: primaryAnimation,
                          secondaryAnimation: secondaryAnimation,
                          transitionType: SharedAxisTransitionType.horizontal,
                          child: child,
                        );
                      },
                  child: currentPage,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: FocusTraversalGroup(
                  policy: OrderedTraversalPolicy(),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      AnimatedOpacity(
                        opacity: step != Steps.welcome && step != Steps.finish
                            ? 1
                            : 0,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                        child: IgnorePointer(
                          ignoring:
                              step == Steps.welcome || step == Steps.finish,
                          child: FocusTraversalOrder(
                            order: const NumericFocusOrder(2.0),
                            child: FilledButton.tonal(
                              onPressed: prevStep,
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 16,
                                ),
                              ),
                              child: const Text(
                                "Back",
                                style: TextStyle(fontSize: 18),
                              ),
                            ),
                          ),
                        ),
                      ),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(1.0),
                        child: FilledButton(
                          focusNode: nextButtonFocusNode,
                          onPressed: _isFinishing
                              ? null
                              : (step == Steps.form
                                  ? (formValid ? handleNext : null)
                                  : (step == Steps.finish
                                      ? handleNext
                                      : handleNext)),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 16,
                            ),
                          ),
                          child: Text(
                            // fix381: on the form, the single button is
                            // "Add Source" (was "Next" → EPG → "Add Source"
                            // on the old multi-step flow). On finish,
                            // "Finish". On welcome/sourceType, "Next".
                            step == Steps.form
                                ? "Add Source"
                                : step == Steps.finish
                                    ? "Finish"
                                    : "Next",
                            style: const TextStyle(fontSize: 18),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget get currentPage {
    switch (step) {
      case Steps.welcome:
        return getPage(
          "Welcome to Free4Me-IPTV",
          "Let's set up your ${widget.showAppBar ? "new" : "first"} source",
          widget.showAppBar
              ? null
              : [
                  const SizedBox(height: 32),
                  Text(
                    'Already have a backup file?',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.7),
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: _isFinishing ? null : _importBackup,
                    icon: const Icon(Icons.download_for_offline),
                    label: const Text('Import settings backup'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: _isFinishing ? null : _receiveViaQr,
                    icon: const Icon(Icons.qr_code_2),
                    label: const Text('Receive via QR / Wi-Fi'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                    ),
                  ),
                ],
        );
      case Steps.sourceType:
        return getPage(
          "What is your provider type?",
          null,
          List.generate(SourceType.values.length, (i) {
            final isLast = i == SourceType.values.length - 1;
            final card = Card(
              color: selectedSourceType.index == i
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).cardTheme.color,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              elevation: 2,
              child: ListTile(
                title: Text((SourceType.values[i]).label),
                onTap: () {
                  setState(() {
                    selectedSourceType = SourceType.values[i];
                  });
                },
              ),
            );
            if (isLast) {
              return Focus(
                canRequestFocus: false,
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.arrowDown) {
                    nextButtonFocusNode.requestFocus();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: card,
              );
            }
            return card;
          }),
        );
      case Steps.form:
        // fix381: single FormBuilder for all fields. Required fields
        // depend on the selected source type; conditional rendering
        // means FormBuilder only sees the fields actually in the tree
        // when computing isValid, so the per-source-type required
        // set is implicit. D-pad order is explicit via
        // FocusTraversalOrder on each field/widget — see the
        // NumericFocusOrder values below.
        return getPage(
          "Source details",
          "Fill in your provider's information. Leave optional fields blank.",
          [
            FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: FormBuilder(
                key: _formKey,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                child: Column(
                  children: [
                    FocusTraversalOrder(
                      order: const NumericFocusOrder(1.0),
                      child: _buildNameField(),
                    ),
                    if (selectedSourceType != SourceType.m3u)
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(2.0),
                        child: _buildUrlField(),
                      ),
                    if (selectedSourceType == SourceType.m3u)
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(2.0),
                        child: _buildFilePickerField(),
                      ),
                    if (selectedSourceType == SourceType.xtream) ...[
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(3.0),
                        child: _buildUsernameField(),
                      ),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(4.0),
                        child: _buildPasswordField(),
                      ),
                    ],
                    FocusTraversalOrder(
                      order: const NumericFocusOrder(5.0),
                      child: _buildEpgUrlField(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      case Steps.finish:
        return getPage("Done!", "You're all set 🎉", null);
    }
  }

  Widget _buildNameField() => DpadFocusEscape(
        child: FormBuilderTextField(
          key: const ValueKey('setup.name.field'),
          name: 'name',
          controller: _nameController,
          focusNode: _nameFocus,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: "Name",
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.label_outline),
          ),
          validator: FormBuilderValidators.compose([
            FormBuilderValidators.required(),
            (value) {
              final trimmed = value?.trim();
              if (trimmed == null || trimmed.isEmpty) return null;
              if (existingSourceNames.contains(trimmed)) {
                return "Name already exists";
              }
              return null;
            },
          ]),
        ),
      );

  Widget _buildUrlField() => DpadFocusEscape(
        child: FormBuilderTextField(
          key: const ValueKey('setup.url.field'),
          name: 'url',
          controller: _urlController,
          focusNode: _urlFocus,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: "URL",
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.link),
            helperText: "http:// will be added automatically if omitted",
          ),
          validator: FormBuilderValidators.compose([
            FormBuilderValidators.required(),
            (value) {
              if (value == null || value.trim().isEmpty) return null;
              final uri = Uri.tryParse(value.trim());
              if (uri == null || uri.host.isEmpty && !value.contains('.')) {
                return 'Enter a valid URL (e.g. http://provider.com)';
              }
              return null;
            },
          ]),
        ),
      );

  Widget _buildFilePickerField() => Focus(
        focusNode: _filePickerFocus,
        child: InkWell(
          onTap: () => selectFile(),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: "M3U file",
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.folder_open),
              helperText: _pickedM3uPath == null
                  ? "Tap to choose a .m3u / .m3u8 file from device storage"
                  : _pickedM3uPath!,
            ),
            child: Text(
              _pickedM3uPath == null
                  ? "(no file selected)"
                  : _pickedM3uPath!.split('/').last,
              style: TextStyle(
                color: _pickedM3uPath == null
                    ? Theme.of(context).hintColor
                    : Theme.of(context).colorScheme.onSurface,
                fontStyle:
                    _pickedM3uPath == null ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
        ),
      );

  Widget _buildUsernameField() => DpadFocusEscape(
        child: FormBuilderTextField(
          key: const ValueKey('setup.username.field'),
          name: 'username',
          controller: _usernameController,
          focusNode: _usernameFocus,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: "Username",
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.person),
          ),
          validator: FormBuilderValidators.required(),
        ),
      );

  Widget _buildPasswordField() => DpadFocusEscape(
        child: FormBuilderTextField(
          key: const ValueKey('setup.password.field'),
          name: 'password',
          controller: _passwordController,
          focusNode: _passwordFocus,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: "Password",
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.password),
          ),
          validator: FormBuilderValidators.required(),
        ),
      );

  Widget _buildEpgUrlField() => DpadTextField(
        controller: _epgUrlController,
        focusNode: _epgUrlFocus,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          labelText: "EPG URL (optional)",
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.tv),
          helperText: "Leave blank to skip",
        ),
        onSubmitted: (_) {
          if (formValid) handleNext();
        },
      );

  Widget getPage(
    final String title,
    final String? subtitle,
    final List<Widget>? content,
  ) {
    return Center(
      key: ValueKey(title),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 12),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 20),
                textAlign: TextAlign.center,
              ),
            ],
            if (content != null) ...[const SizedBox(height: 24), ...content],
          ],
        ),
      ),
    );
  }
}
