import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:open_tv/widgets/dpad_text_field.dart';
import 'package:form_builder_validators/form_builder_validators.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/xtream.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:open_tv/source_color_picker.dart';
import 'package:open_tv/error.dart';

/// Edit Source dialog.
///
/// Bug/UX fix batch (this file):
/// - #1: name is editable (was: read-only, carried from source).
/// - #4: shows current color, allows change via [showSourceColorPicker].
/// - #6: default focus is Cancel, not Save.
/// - #9: counts info (Connections / Live TV / Movies / Series) moved
///   to the top of the dialog, above the editable form fields.
/// - #10: "Counts appear after the next refresh." placeholder shown
///   when ANY count is null (was: only when ALL three are null).
/// - #11: URL field has a real URL validator (Uri host check).
/// - #16: a "Test connection" button in the form, dispatches per
///   source type (Xtream → get_user_info probe, M3U URL → HTTP HEAD
///   probe, M3U file → file-exists check).
/// - #21: title truncates the source name with ellipsis.
class EditDialog extends StatefulWidget {
  final Source source;
  final AsyncCallback afterSave;
  const EditDialog({super.key, required this.source, required this.afterSave});

  @override
  State<EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<EditDialog> {
  final _formKey = GlobalKey<FormBuilderState>();

  // fix385/#1: set of source names that exist OTHER than the one
  // being edited. Populated from Sql.getSources() in initState.
  // Used by the name validator to catch rename collisions.
  Set<String> _otherSourceNames = const {};

  // fix385/#1: name editable. Late-init from the source so a rename
  // is possible. Saved back to Sql.updateSource as a new Source
  // object with the new name.
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;

  // fix256/fix272: per-source sort mode.
  late String _sortMode = (widget.source.sortMode == 'provider' ||
          widget.source.sortMode == 'category')
      ? widget.source.sortMode!
      : 'alpha';
  // fix272: hide provider divider (#### header ####) channels.
  late bool _hideDividers = widget.source.hideDividers == 1;
  // fix385/#4: color editable in this dialog. Carried through
  // Sql.updateSource on save. Init in initState to avoid the
  // instance-member-in-initializer Dart restriction.
  int? _color;
  // fix385/#6: default focus is Cancel (autofocus on the Cancel
  // button), not Save. The previous autofocus on Save risked
  // accidental save-on-open.
  final _cancelFocus = FocusNode();
  // fix326: password is masked by default; tap the eye to reveal.
  bool _obscurePassword = true;

  // fix385/#16: connection test in-flight state.
  bool _testing = false;
  String? _testResultMessage;
  bool _testResultOk = false;

  @override
  void initState() {
    super.initState();
    _color = widget.source.color;
    _nameController = TextEditingController(text: widget.source.name);
    _urlController = TextEditingController(text: widget.source.url);
    _usernameController =
        TextEditingController(text: widget.source.username);
    _passwordController =
        TextEditingController(text: widget.source.password);
    // fix385/#1: populate the duplicate-name Set in the background
    // so the validator can catch renames that collide with another
    // source. Fire-and-forget; if the DB is slow the validator just
    // allows the rename through (validated again on Save via
    // Sql.sourceNameExists by the caller, if desired).
    Sql.getSources().then((sources) {
      if (!mounted) return;
      setState(() {
        _otherSourceNames = sources
            .where((s) => s.id != widget.source.id)
            .map((s) => s.name)
            .toSet();
      });
    }).catchError((_) {
      // On any DB failure, leave the Set empty — the validator
      // will fall through and the caller is responsible for any
      // final uniqueness check.
    });
    // Focus the Cancel button on open so D-pad Center / Enter
    // doesn't fire Save on the (unchanged) form.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cancelFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _cancelFocus.dispose();
    super.dispose();
  }

  /// fix385/#16: run a cheap connection probe appropriate for the
  /// source type. Xtream → fetchXtreamMaxConnections (calls
  /// player_api.php?action= which returns user_info, no channel
  /// fetch). M3U URL → HEAD on the URL, expect 2xx. M3U file →
  /// just check the file path exists and is non-empty.
  ///
  /// Returns null on success, or a human-readable error string.
  Future<String?> _testConnection() async {
    setState(() {
      _testing = true;
      _testResultMessage = null;
    });
    String? err;
    try {
      switch (widget.source.sourceType) {
        case SourceType.xtream:
          // Build a temporary Source reflecting the form's current
          // values so the probe uses what the user *typed*, not
          // what's already saved. Source has no copyWith; construct
          // a fresh instance.
          final probe = Source(
            id: widget.source.id,
            name: widget.source.name,
            sourceType: widget.source.sourceType,
            url: _urlController.text.trim(),
            username: _usernameController.text,
            password: _passwordController.text,
            enabled: widget.source.enabled,
            epgUrl: widget.source.epgUrl,
            maxConnections: widget.source.maxConnections,
            color: widget.source.color,
            sortMode: widget.source.sortMode,
            hideDividers: widget.source.hideDividers,
            lastLiveCount: widget.source.lastLiveCount,
            lastMovieCount: widget.source.lastMovieCount,
            lastSeriesCount: widget.source.lastSeriesCount,
          );
          final maxConn = await fetchXtreamMaxConnections(probe);
          if (maxConn == null) {
            err = 'Xtream login failed — check URL, username, password.';
          }
          break;
        case SourceType.m3uUrl:
          // Cheap HEAD on the URL using dart:io HttpClient.
          final probe = _urlController.text.trim();
          if (probe.isEmpty) {
            err = 'URL is empty.';
          } else {
            try {
              final uri = Uri.tryParse(probe);
              if (uri == null || !uri.hasScheme) {
                err = 'URL is not a valid URI.';
              } else {
                final client = HttpClient();
                client.connectionTimeout = const Duration(seconds: 8);
                final req = await client.headUrl(uri);
                final resp = await req.close();
                if (resp.statusCode < 200 || resp.statusCode >= 400) {
                  err = 'HTTP ${resp.statusCode} for $probe';
                }
                client.close(force: true);
              }
            } catch (e) {
              err = 'HEAD failed: $e';
            }
          }
          break;
        case SourceType.m3u:
          // file picker path stored in widget.source.url (kept
          // untouched here; the URL field is not shown for M3U file).
          final path = widget.source.url ?? '';
          if (path.isEmpty) {
            err = 'No file selected.';
          } else if (!File(path).existsSync()) {
            err = 'File not found: $path';
          }
          break;
      }
    } catch (e) {
      err = 'Test failed: $e';
    }
    if (!mounted) return err;
    setState(() {
      _testing = false;
      _testResultMessage = err ?? 'Connection OK';
      _testResultOk = err == null;
    });
    return err;
  }

  @override
  Widget build(BuildContext context) {
    // fix326 (corrects fix324): plain AlertDialog + SingleChildScrollView
    // is the canonical pattern (the content scrolls, title + actions
    // stay fixed and D-pad-traversable).
    return AlertDialog(
      // fix385/#21: truncate the source name in the title with
      // ellipsis so a long name doesn't overflow the dialog title.
      title: Text(
        'Edit source ${widget.source.name}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        // fix385/#6: Cancel is autofocused (D-pad Center / Enter on
        // dialog open → Cancel, not Save). Removes the risk of an
        // accidental save-without-changes.
        TextButton(
          focusNode: _cancelFocus,
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Cancel"),
        ),
        TextButton(
            onPressed: () async {
              if (!_formKey.currentState!.saveAndValidate()) {
                return;
              }
              Navigator.of(context).pop();
              // fix385/#1: read the (possibly new) name from the form,
              // not the original source. fix385/#4: read the (possibly
              // new) color from the in-state _color.
              final formName = _nameController.text.trim();
              await Error.tryAsyncNoLoading(
                  () async => await Sql.updateSource(Source(
                      id: widget.source.id,
                      name: formName,
                      sourceType: widget.source.sourceType,
                      url: _urlController.text.trim(),
                      username: widget.source.sourceType == SourceType.xtream
                          ? _usernameController.text
                          : null,
                      password: widget.source.sourceType == SourceType.xtream
                          ? _passwordController.text
                          : null,
                      enabled: widget.source.enabled,
                      epgUrl: widget.source.epgUrl,
                      // fix190: carry max_connections through edit.
                      maxConnections: widget.source.maxConnections,
                      // fix385/#4: persist the (possibly new) color.
                      color: _color,
                      sortMode: _sortMode,
                      hideDividers: _hideDividers ? 1 : 0,
                      // fix268: carry refresh counts through edit.
                      lastLiveCount: widget.source.lastLiveCount,
                      lastMovieCount: widget.source.lastMovieCount,
                      lastSeriesCount: widget.source.lastSeriesCount)),
                  context);
              await widget.afterSave();
            },
            child: const Text("Save")),
      ],
      content: SingleChildScrollView(
        child: FormBuilder(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // fix385/#9: read-only info section at the TOP of the
              // dialog. Counts + connection info + color. The
              // editable form fields come below.
              _infoSection(context),
              const Divider(height: 24),
              // fix385/#1: name editable. Validator checks non-empty
              // and uniqueness via _otherSourceNames.
              DpadFocusEscape(
                child: FormBuilderTextField(
                  name: 'name',
                  controller: _nameController,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    prefixIcon: Icon(Icons.label_outline),
                    border: OutlineInputBorder(),
                  ),
                  validator: FormBuilderValidators.compose([
                    FormBuilderValidators.required(),
                    (value) {
                      final trimmed = value?.trim();
                      if (trimmed == null || trimmed.isEmpty) return null;
                      // Don't flag the original name as a duplicate
                      // (a user opening Edit on an unchanged name
                      // should be able to hit Save without renaming).
                      if (trimmed == widget.source.name) return null;
                      if (_otherSourceNames.contains(trimmed)) {
                        return 'Name already exists';
                      }
                      return null;
                    },
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              DpadFocusEscape(
                child: FormBuilderTextField(
                  name: 'url',
                  controller: _urlController,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  // fix385/#11: URL format validation. Same shape
                  // as the Setup wizard's URL field.
                  validator: FormBuilderValidators.compose([
                    FormBuilderValidators.required(),
                    (value) {
                      if (value == null || value.trim().isEmpty) return null;
                      final uri = Uri.tryParse(value.trim());
                      if (uri == null ||
                          (uri.host.isEmpty && !value.contains('.'))) {
                        return 'Enter a valid URL (e.g. http://provider.com)';
                      }
                      return null;
                    },
                  ]),
                  decoration: InputDecoration(
                    labelText: widget.source.sourceType == SourceType.m3u
                        ? 'URL (M3U file — not editable here)'
                        : 'URL',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.link),
                    helperText: widget.source.sourceType == SourceType.m3u
                        ? 'Re-pick the file from the source list to change.'
                        : 'http:// will be added automatically if omitted',
                  ),
                  enabled: widget.source.sourceType != SourceType.m3u,
                ),
              ),
              if (widget.source.sourceType == SourceType.xtream) ...[
                const SizedBox(height: 12),
                DpadFocusEscape(
                  child: FormBuilderTextField(
                    name: 'username',
                    controller: _usernameController,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    validator: FormBuilderValidators.compose(
                        [FormBuilderValidators.required()]),
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      prefixIcon: Icon(Icons.account_circle),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                DpadFocusEscape(
                  child: FormBuilderTextField(
                    name: 'password',
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    validator: FormBuilderValidators.compose(
                        [FormBuilderValidators.required()]),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.password),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword
                            ? Icons.visibility_off
                            : Icons.visibility),
                        tooltip:
                            _obscurePassword ? 'Show password' : 'Hide password',
                        onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              // fix385/#16: Test connection button. Probes the source
              // per its type (see [_testConnection]). Result shown
              // inline below the button.
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _testing ? null : _testConnection,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_tethering),
                    label: Text(_testing ? 'Testing…' : 'Test connection'),
                  ),
                  const SizedBox(width: 12),
                  if (_testResultMessage != null)
                    Expanded(
                      child: Text(
                        _testResultMessage!,
                        style: TextStyle(
                          color: _testResultOk ? Colors.green : Colors.red,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              // fix256/fix272: per-source channel order.
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 4),
                child: Text('Channel order',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              RadioGroup<String>(
                groupValue: _sortMode,
                onChanged: (v) => setState(() => _sortMode = v!),
                child: const Column(
                  children: [
                    RadioListTile<String>(
                      value: 'alpha',
                      dense: true,
                      title: Text('Alphabetical (A–Z)'),
                    ),
                    RadioListTile<String>(
                      value: 'provider',
                      dense: true,
                      title: Text('Provider order'),
                      subtitle: Text(
                          'The provider\'s exact sequence, including its section headers.'),
                    ),
                    RadioListTile<String>(
                      value: 'category',
                      dense: true,
                      title: Text('By category'),
                      subtitle: Text(
                          'Group channels by their category, then A–Z within each.'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              // fix272: hide provider divider rows.
              SwitchListTile(
                value: _hideDividers,
                onChanged: (v) => setState(() => _hideDividers = v),
                title: const Text('Hide section-header rows'),
                subtitle: const Text(
                    'Hide the provider\'s "#### … ####" divider entries, which '
                    'are labels and do not play.'),
                secondary: const Icon(Icons.label_off_outlined),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// fix385/#9: read-only info section at the top of the dialog.
  /// Connection info, the last-refresh counts, the per-source color
  /// swatch, and a hint placeholder when counts aren't all set.
  Widget _infoSection(BuildContext context) {
    final anyCountNull = widget.source.lastLiveCount == null ||
        widget.source.lastMovieCount == null ||
        widget.source.lastSeriesCount == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // fix385/#4: current color shown as a tap-to-edit swatch.
        InkWell(
          onTap: () async {
            final result = await showSourceColorPicker(context, current: _color);
            if (result == null) return;
            if (!result.chose) return;
            setState(() => _color = result.color);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            child: Row(
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    if (_color != null)
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: Color(_color!),
                          shape: BoxShape.circle,
                        ),
                      ),
                    const Icon(Icons.palette_outlined),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _color == null
                        ? 'Color: none (tap to set)'
                        : 'Color: tap to change',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        _infoRow(
          Icons.lan_outlined,
          'Connections',
          widget.source.maxConnections == null
              ? 'Unknown'
              : '${widget.source.maxConnections}',
        ),
        _infoRow(
          Icons.live_tv_outlined,
          'Live TV',
          _countText(widget.source.lastLiveCount),
        ),
        _infoRow(
          Icons.movie_outlined,
          'Movies',
          _countText(widget.source.lastMovieCount),
        ),
        _infoRow(
          Icons.video_library_outlined,
          'Series',
          _countText(widget.source.lastSeriesCount),
        ),
        // fix385/#10: placeholder when ANY count is null
        // (was: only when all three were null).
        if (anyCountNull)
          const Padding(
            padding: EdgeInsets.only(top: 4, left: 4),
            child: Text(
              'Counts appear after the next refresh.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
      ],
    );
  }

  /// fix268: a count value, or an en-dash when not yet recorded.
  String _countText(int? n) => n == null ? '—' : '$n';

  /// fix268: a compact read-only "icon · label · value" row.
  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
