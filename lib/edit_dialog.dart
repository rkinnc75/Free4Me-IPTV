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
                      defaultEngine: widget.source.defaultEngine)),
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
            ],
          ))),
    )));
  }
}
