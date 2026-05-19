import 'package:flutter/material.dart';

class SettingHelpDialog {
  /// Show an informational dialog explaining a setting.
  /// Tapping "Got it" or the device Back button closes it.
  static void show(
    BuildContext context, {
    required String title,
    required String body,
  }) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}
