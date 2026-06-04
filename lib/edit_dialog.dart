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

  // fix256: per-source browse order. true = provider order, false = alphabetical.
  late bool _providerSort = widget.source.sortMode == 'provider';

  @override
  Widget build(BuildContext context) {
    return Center(
        child: SingleChildScrollView(
            child: AlertDialog(
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
                      defaultEngine: widget.source.defaultEngine,
                      // fix256: persist the per-source browse order choice.
                      color: widget.source.color,
                      sortMode: _providerSort ? 'provider' : 'alpha',
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
      content: FormBuilder(
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
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    validator: FormBuilderValidators.compose(
                        [FormBuilderValidators.required()]),
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      prefixIcon: Icon(Icons.password),
                      border: OutlineInputBorder(),
                    ),
                    name: 'password',
                  ))),
              const SizedBox(height: 10),
              // fix256: per-source channel order. Provider order preserves the
              // provider's intended sequence (incl. "#### SECTION ####" header
              // channels next to their channels); off = alphabetical by name.
              SwitchListTile(
                value: _providerSort,
                onChanged: (v) => setState(() => _providerSort = v),
                title: const Text('Use provider channel order'),
                subtitle: const Text(
                    'Keep the provider\'s order instead of sorting A–Z. '
                    'Applies to Live, Movies, Series and All.'),
                secondary: const Icon(Icons.sort),
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
          ))),
    )));
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
