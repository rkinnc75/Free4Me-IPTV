import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:animations/animations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:form_builder_validators/form_builder_validators.dart';
import 'package:open_tv/backend/epg_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/correction_modal.dart';
import 'package:open_tv/home.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:open_tv/models/steps.dart';
import 'package:open_tv/models/view_type.dart';

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
  final Map<Steps, FocusNode> focusNodes = {
    Steps.name: FocusNode(),
    Steps.url: FocusNode(),
    Steps.username: FocusNode(),
    Steps.password: FocusNode(),
  };
  final formPages = {Steps.name, Steps.url, Steps.username, Steps.password};
  final _formKeys = {
    Steps.name: GlobalKey<FormBuilderState>(),
    Steps.url: GlobalKey<FormBuilderState>(),
    Steps.username: GlobalKey<FormBuilderState>(),
    Steps.password: GlobalKey<FormBuilderState>(),
  };
  final formValues = {
    Steps.name: "",
    Steps.url: "",
    Steps.username: "",
    Steps.password: "",
  };
  final _epgUrlController = TextEditingController();
  final nextButtonFocusNode = FocusNode();
  Set<String> existingSourceNames = {};

  @override
  void initState() {
    nextButtonFocusNode.requestFocus();
    super.initState();
  }

  @override
  void dispose() {
    for (var focus in focusNodes.values) {
      focus.dispose();
    }
    nextButtonFocusNode.dispose();
    _epgUrlController.dispose();
    super.dispose();
  }

  /// Auto-fix a raw M3U URL: prepend http:// when no scheme is present.
  String _autoFixM3uUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return trimmed;
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      return 'http://$trimmed';
    }
    return trimmed;
  }

  Future<void> finish() async {
    final sourceName = formValues[Steps.name]!;
    final epgUrlValue = _epgUrlController.text.trim();

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
              ? formValues[Steps.url]!
              : await fixUrl(formValues[Steps.url]!),
          username: selectedSourceType == SourceType.xtream
              ? formValues[Steps.username]
              : null,
          password: selectedSourceType == SourceType.xtream
              ? formValues[Steps.password]
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

  Future<bool> selectFile() async {
    var path = (await FilePicker.platform.pickFiles())?.files.single.path;
    if (path == null) return false;
    formValues[Steps.url] = path;
    return true;
  }

  void prevStep() {
    isForward = false;
    if (formPages.contains(step)) {
      formValues[step] =
          _formKeys[step]?.currentState?.fields[step.name]?.value;
    }
    // M3U URL skips username/password: going back from epgUrl returns to url.
    Steps target;
    if (step == Steps.epgUrl && selectedSourceType == SourceType.m3uUrl) {
      target = Steps.url;
    } else {
      target = Steps.values[step.index - 1];
    }
    setState(() => step = target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      setState(() {
        formValid = _formKeys[step]?.currentState?.isValid == true;
      });
      if (formPages.contains(step)) focusNodes[step]?.requestFocus();
      if (step == Steps.welcome) {
        nextButtonFocusNode.requestFocus();
      }
    });
  }

  Future<void> handleNext() async {
    isForward = true;
    if (formPages.contains(step)) {
      formValues[step] =
          _formKeys[step]?.currentState?.fields[step.name]?.value;
    }

    // Duplicate name check
    if (step == Steps.name) {
      var sourceName = formValues[step]!;
      if (await Sql.sourceNameExists(sourceName)) {
        existingSourceNames.add(sourceName);
        _formKeys[step]?.currentState?.validate();
        return;
      }
    }

    // M3U file: pick file then finish immediately
    if (step == Steps.name && selectedSourceType == SourceType.m3u) {
      if (!await selectFile()) return;
      finish();
      return;
    }

    // M3U URL: auto-fix the URL then go to the optional EPG URL step
    if (step == Steps.url && selectedSourceType == SourceType.m3uUrl) {
      final raw = formValues[Steps.url]!.trim();
      final fixed = _autoFixM3uUrl(raw);
      if (fixed != raw && fixed.isNotEmpty) {
        formValues[Steps.url] = fixed;
        _formKeys[Steps.url]?.currentState?.fields[Steps.url.name]
            ?.didChange(fixed);
      }
      _advanceToEpgUrl();
      return;
    }

    // Xtream: after password, go to the optional EPG URL step
    if (step == Steps.password) {
      _advanceToEpgUrl();
      return;
    }

    // EPG URL step (optional): proceed to finish
    if (step == Steps.epgUrl) {
      finish();
      return;
    }

    if (step == Steps.finish) {
      navigateToHome();
      return;
    }

    // Default: advance to the next step
    setState(() {
      step = Steps.values[step.index + 1];
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      setState(() {
        if (formValues[step]?.isNotEmpty == true) {
          _formKeys[step]?.currentState?.validate();
        }
        formValid = _formKeys[step]?.currentState?.isValid == true;
      });
      if (formPages.contains(step)) focusNodes[step]?.requestFocus();
    });
  }

  void _advanceToEpgUrl() {
    setState(() => step = Steps.epgUrl);
    // epgUrl is optional — focus falls through to the Next button.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nextButtonFocusNode.requestFocus();
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
                            order: NumericFocusOrder(2.0),
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
                        order: NumericFocusOrder(1.0),
                        child: FilledButton(
                          focusNode: nextButtonFocusNode,
                          onPressed: !formPages.contains(step) || formValid
                              ? handleNext
                              : null,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 16,
                            ),
                          ),
                          child: Text(
                            step == Steps.name &&
                                    selectedSourceType == SourceType.m3u
                                ? "Select file"
                                : step == Steps.finish
                                ? "Finish"
                                : step == Steps.epgUrl
                                ? "Add Source"
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
          null,
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
                    formValues[Steps.url] = "";
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
      case Steps.name:
        return getPage("What should we name this source?", null, [
          FormBuilder(
            onChanged: () {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                setState(() {
                  formValid =
                      _formKeys[Steps.name]!.currentState?.isValid == true;
                });
              });
            },
            initialValue: {Steps.name.name: formValues[Steps.name]},
            key: _formKeys[Steps.name],
            child: FormBuilderTextField(
              autocorrect: false,
              focusNode: focusNodes[Steps.name],
              decoration: const InputDecoration(
                labelText: "Name",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.label_outline),
              ),
              textInputAction: TextInputAction.next,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: FormBuilderValidators.compose([
                FormBuilderValidators.required(),
                (value) {
                  var trimmed = value?.trim();
                  if (trimmed == null || trimmed.isEmpty) {
                    return null;
                  }
                  if (existingSourceNames.contains(trimmed)) {
                    return "Name already exists";
                  }
                  return null;
                },
              ]),
              name: 'name',
            ),
          ),
        ]);
      case Steps.url:
        return getPage("What is your provider's URL?", null, [
          FormBuilder(
            onChanged: () {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                setState(() {
                  formValid =
                      _formKeys[Steps.url]!.currentState?.isValid == true;
                });
              });
            },
            initialValue: {Steps.url.name: formValues[Steps.url]},
            key: _formKeys[Steps.url],
            child: FormBuilderTextField(
              autocorrect: false,
              focusNode: focusNodes[Steps.url],
              decoration: const InputDecoration(
                labelText: "URL",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
                helperText:
                    "http:// will be added automatically if omitted",
              ),
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              autovalidateMode: AutovalidateMode.onUserInteraction,
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
              name: 'url',
            ),
          ),
        ]);
      case Steps.username:
        return getPage("What is your username?", null, [
          FormBuilder(
            onChanged: () {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                setState(() {
                  formValid =
                      _formKeys[Steps.username]!.currentState?.isValid == true;
                });
              });
            },
            initialValue: {Steps.username.name: formValues[Steps.username]},
            key: _formKeys[Steps.username],
            child: FormBuilderTextField(
              autocorrect: false,
              focusNode: focusNodes[Steps.username],
              decoration: const InputDecoration(
                labelText: "Username",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
              textInputAction: TextInputAction.next,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: FormBuilderValidators.required(),
              name: 'username',
            ),
          ),
        ]);
      case Steps.password:
        return getPage("What is your password?", null, [
          FormBuilder(
            initialValue: {Steps.password.name: formValues[Steps.password]},
            onChanged: () {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                setState(() {
                  formValid =
                      _formKeys[Steps.password]!.currentState?.isValid == true;
                });
              });
            },
            key: _formKeys[Steps.password],
            child: FormBuilderTextField(
              autocorrect: false,
              focusNode: focusNodes[Steps.password],
              decoration: const InputDecoration(
                labelText: "Password",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.password),
              ),
              textInputAction: TextInputAction.next,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: FormBuilderValidators.required(),
              name: 'password',
            ),
          ),
        ]);
      case Steps.epgUrl:
        return getPage(
          "EPG URL (optional)",
          "Enter your Electronic Programme Guide URL to enable programme\nschedules. You can also add or change this later in Settings.",
          [
            TextField(
              controller: _epgUrlController,
              decoration: const InputDecoration(
                labelText: "EPG URL (optional)",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.tv),
                helperText: "Leave blank to skip",
              ),
              autocorrect: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => handleNext(),
            ),
          ],
        );
      case Steps.finish:
        return getPage("Done!", "You're all set 🎉", null);
    }
  }

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
