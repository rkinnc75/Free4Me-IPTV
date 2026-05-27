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
        // fix61: relaxed line height improves readability of longer help text.
        content: SingleChildScrollView(
          child: Text(
            body,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(height: 1.35),
          ),
        ),
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
