import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/search_perf_test.dart';
import 'package:open_tv/models/settings.dart';

/// fix612: runs [SearchPerfTest] and presents the results. Each method is
/// tappable to switch to it; the fastest (by warm median) is pre-selected.
/// Returns the [SearchMethod] the user chose to apply, or null if they
/// cancelled without changing anything.
Future<SearchMethod?> showSearchPerfDialog(
  BuildContext context, {
  required List<int> enabledSourceIds,
  required bool safeMode,
}) {
  return showDialog<SearchMethod>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SearchPerfDialog(
      enabledSourceIds: enabledSourceIds,
      safeMode: safeMode,
    ),
  );
}

String _methodLabel(SearchMethod m) => switch (m) {
      SearchMethod.ftsAnd => 'FTS AND',
      SearchMethod.ftsPhrase => 'FTS Phrase',
      SearchMethod.likeSubstring => 'LIKE Scan',
      SearchMethod.inMemory => 'In-Memory',
    };

class _SearchPerfDialog extends StatefulWidget {
  final List<int> enabledSourceIds;
  final bool safeMode;
  const _SearchPerfDialog({
    required this.enabledSourceIds,
    required this.safeMode,
  });

  @override
  State<_SearchPerfDialog> createState() => _SearchPerfDialogState();
}

class _SearchPerfDialogState extends State<_SearchPerfDialog> {
  bool _running = true;
  String _status = 'Starting…';
  Object? _error;
  List<SearchMethodPerfResult> _results = const [];
  SearchMethod? _selected;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final results = await SearchPerfTest.run(
        enabledSourceIds: widget.enabledSourceIds,
        safeMode: widget.safeMode,
        onProgress: (s) {
          if (mounted) setState(() => _status = s);
        },
      );
      final best = SearchPerfTest.recommend(results);
      if (mounted) {
        setState(() {
          _results = results;
          _selected = best;
          _running = false;
        });
      }
    } catch (e) {
      AppLog.warn('SearchPerfTest: failed — $e');
      if (mounted) {
        setState(() {
          _error = e;
          _running = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Search performance'),
      content: _running
          ? _buildRunning()
          : _error != null
              ? Text('Could not run the test:\n$_error')
              : _buildResults(context),
      actions: _running
          ? null
          : _error != null
              ? [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ]
              : [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    autofocus: true,
                    onPressed: () => Navigator.of(context).pop(_selected),
                    child: Text('Use ${_methodLabel(_selected!)}'),
                  ),
                ],
    );
  }

  Widget _buildRunning() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(_status, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          'Testing each method against your channels…',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildResults(BuildContext context) {
    final best = SearchPerfTest.recommend(_results);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tap a method to select it. The fastest by warm (steady-state) '
            'time is pre-selected.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          ..._results.map((r) => _resultRow(context, r, r.method == best)),
          const SizedBox(height: 12),
          Text(
            'Warm = median of repeated searches (drives the recommendation). '
            'Cold = first search after a refresh; compare cold loosely — the '
            'system keeps data cached after the first method runs, so later '
            'methods read warmer.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                ),
          ),
        ],
      ),
    );
  }

  Widget _resultRow(
    BuildContext context,
    SearchMethodPerfResult r,
    bool isBest,
  ) {
    final isSelected = r.method == _selected;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      color: isSelected
          ? Theme.of(context).colorScheme.primaryContainer
          : null,
      child: InkWell(
        onTap: () => setState(() => _selected = r.method),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          _methodLabel(r.method),
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        if (isBest) ...[
                          const SizedBox(width: 6),
                          _chip(context, 'Fastest'),
                        ],
                        if (r.degraded) ...[
                          const SizedBox(width: 6),
                          _chip(context, 'No results'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Warm ${r.warmMedianMs.toStringAsFixed(0)} ms'
                      '   ·   Cold ${r.coldMs.toStringAsFixed(0)} ms',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}
