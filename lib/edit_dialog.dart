import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:open_tv/widgets/dpad_text_field.dart';
import 'package:form_builder_validators/form_builder_validators.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:open_tv/error.dart';

class EditDialog extends StatefulWidget {
  final Source source;
  final AsyncCallback afterSave;
  const EditDialog({super.key, required this.source, required this.afterSave});

  @override
  State<EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<EditDialog> {
  final _formKey = GlobalKey<FormBuilderState>();

  // fix256/fix272: per-source sort mode — 'alpha', 'provider', or 'category'.
  late String _sortMode = (widget.source.sortMode == 'provider' ||
          widget.source.sortMode == 'category')
      ? widget.source.sortMode!
      : 'alpha';
  // fix272: hide provider divider (#### header ####) channels.
  late bool _hideDividers = widget.source.hideDividers == 1;

  // fix326: provider credentials are assigned (not user-chosen) and cannot be
  // rotated, so the password must not render in clear text by default. Masked
  // with a tap-to-reveal toggle so the user can still verify it.
  bool _obscurePassword = true;

  @override
  Widget build(BuildContext context) {
    // fix326 (corrects fix324): `scrollable: true` + ConstrainedBox(maxHeight)
    // was wrong — the scrollable wrapper gives the content UNBOUNDED height, so
    // the ConstrainedBox capped the Column and the Column painted past the
    // dialog bottom (seen on TV: "By category" bleeding outside the dialog,
    // info rows unreachable). Canonical pattern instead: a plain AlertDialog
    // whose CONTENT is a SingleChildScrollView. The dialog bounds the content
    // height to the screen automatically; the inner scroll view scrolls the
    // form while the title and Save/Cancel actions stay fixed and always
    // visible. D-pad focus traversal auto-scrolls to the focused child.
    return AlertDialog(
      title: Text("Edit source ${widget.source.name}"),
      actions: [
        TextButton(
            autofocus: true,
            onPressed: () async {
              if (!_formKey.currentState!.saveAndValidate()) {
                return;
              }
              Navigator.of(context).pop();
              await Error.tryAsyncNoLoading(
                  () async => await Sql.updateSource(Source(
                      id: widget.source.id,
                      name: widget.source.name,
                      sourceType: widget.source.sourceType,
                      url: _formKey.currentState?.value["url"],
                      username: widget.source.sourceType == SourceType.xtream
                          ? _formKey.currentState?.value["username"]
                          : null,
                      password: widget.source.sourceType == SourceType.xtream
                          ? _formKey.currentState?.value["password"]
                          : null,
                      enabled: widget.source.enabled,
                      epgUrl: widget.source.epgUrl,
                      // fix190: carry the detected max_connections through edit.
                      // Without this it defaults to null and updateSource writes
                      // NULL, wiping the connection limit on every source edit.
                      maxConnections: widget.source.maxConnections,
                      // fix256: persist the per-source browse order choice.
                      color: widget.source.color,
                      sortMode: _sortMode,
                      hideDividers: _hideDividers ? 1 : 0,
                      // fix268: carry refresh counts through edit (else NULL
                      // wipes them on every manual save, like maxConnections).
                      lastLiveCount: widget.source.lastLiveCount,
                      lastMovieCount: widget.source.lastMovieCount,
                      lastSeriesCount: widget.source.lastSeriesCount)),
                  context);
              await widget.afterSave();
            },
            child: const Text("Save")),
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text("Cancel"))
      ],
      content: SingleChildScrollView(
        child: FormBuilder(
          key: _formKey,
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 15),
              DpadFocusEscape(
                child: FormBuilderTextField(
                initialValue: widget.source.url,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                validator: FormBuilderValidators.compose(
                    [FormBuilderValidators.required()]),
                decoration: const InputDecoration(
                  labelText: 'Url',
                  prefixIcon: Icon(Icons.link),
                  border: OutlineInputBorder(),
                ),
                name: 'url',
              )),
              Visibility(
                  visible: widget.source.sourceType == SourceType.xtream,
                  child: const SizedBox(height: 30)),
              Visibility(
                  visible: widget.source.sourceType == SourceType.xtream,
                  child: DpadFocusEscape(
                    child: FormBuilderTextField(
                    initialValue: widget.source.username,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    validator: FormBuilderValidators.compose(
                        [FormBuilderValidators.required()]),
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      prefixIcon: Icon(Icons.account_circle),
                      border: OutlineInputBorder(),
                    ),
                    name: 'username',
                  ))),
              Visibility(
                  visible: widget.source.sourceType == SourceType.xtream,
                  child: const SizedBox(height: 30)),
              Visibility(
                  visible: widget.source.sourceType == SourceType.xtream,
                  child: DpadFocusEscape(
                    child: FormBuilderTextField(
                    initialValue: widget.source.password,
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
                    name: 'password',
                  ))),
              const SizedBox(height: 10),
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
              // fix272: hide the provider's unplayable "#### header ####" rows.
              SwitchListTile(
                value: _hideDividers,
                onChanged: (v) => setState(() => _hideDividers = v),
                title: const Text('Hide section-header rows'),
                subtitle: const Text(
                    'Hide the provider\'s "#### … ####" divider entries, which '
                    'are labels and do not play.'),
                secondary: const Icon(Icons.label_off_outlined),
              ),
              // fix268: read-only source info — connection limit + the counts
              // from the most recent refresh.
              const Divider(height: 24),
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
              if (widget.source.lastLiveCount == null &&
                  widget.source.lastMovieCount == null &&
                  widget.source.lastSeriesCount == null)
                const Padding(
                  padding: EdgeInsets.only(top: 4, left: 4),
                  child: Text(
                    'Counts appear after the next refresh.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
            ],
          )),
        ),
      ),
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
