import 'package:flutter/material.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/widgets/dpad_text_field.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/source.dart';

/// Manual EPG channel mapping screen.
///
/// Shows all live channels for a source. For each channel the user can:
///   • See the current EPG assignment (or "Unmatched")
///   • Tap to open a searchable list of available EPG IDs
///   • Clear a mapping with a long-press
///
/// Changes are persisted immediately via [Sql.setManualEpgOverride].
class EpgChannelMappingView extends StatefulWidget {
  final Source source;

  const EpgChannelMappingView({super.key, required this.source});

  @override
  State<EpgChannelMappingView> createState() => _EpgChannelMappingViewState();
}

class _EpgChannelMappingViewState extends State<EpgChannelMappingView> {
  List<Channel>? _channels;
  List<(String, String)>? _epgIds; // (epg_channel_id, sample_title)
  String _channelFilter = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        Sql.getLiveChannelsForMapping(widget.source.id!),
        Sql.getAvailableEpgIds(widget.source.id!),
      ]);
      if (!mounted) return;
      setState(() {
        _channels = results[0] as List<Channel>;
        _epgIds = results[1] as List<(String, String)>;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  List<Channel> get _filtered {
    final q = _channelFilter.trim().toLowerCase();
    final channels = _channels ?? [];
    if (q.isEmpty) return channels;
    return channels
        .where((c) => c.name.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('EPG Mapping — ${widget.source.name}'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: DpadTextField(
              decoration: InputDecoration(
                hintText: 'Filter channels…',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                filled: true,
              ),
              onChanged: (v) => setState(() => _channelFilter = v),
            ),
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    final channels = _channels;
    if (channels == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_epgIds?.isEmpty == true) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No EPG data available yet.\n\n'
            'Go to Settings → Refresh EPG now, then return here to map channels.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final visible = _filtered;
    if (visible.isEmpty) {
      return const Center(child: Text('No channels match the filter.'));
    }

    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (ctx, i) => _channelTile(visible[i]),
    );
  }

  Widget _channelTile(Channel ch) {
    final isMatched = ch.epgChannelId != null;
    return ListTile(
      leading: Icon(
        isMatched ? Icons.check_circle_outline : Icons.help_outline,
        color: isMatched
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.outline,
      ),
      title: Text(ch.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        isMatched ? ch.epgChannelId! : 'Unmatched — tap to assign',
        style: TextStyle(
          color: isMatched
              ? null
              : Theme.of(context).colorScheme.outline,
          fontStyle: isMatched ? FontStyle.normal : FontStyle.italic,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: isMatched
          ? IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Clear mapping',
              onPressed: () => _clearMapping(ch),
            )
          : null,
      onTap: () => _showPickerDialog(ch),
    );
  }

  Future<void> _showPickerDialog(Channel ch) async {
    final epgIds = _epgIds;
    if (epgIds == null) return;

    final chosen = await showDialog<String>(
      context: context,
      builder: (_) => _EpgIdPickerDialog(
        channelName: ch.name,
        currentId: ch.epgChannelId,
        epgIds: epgIds,
      ),
    );

    if (chosen != null && mounted) {
      await _applyMapping(ch, chosen);
    }
  }

  Future<void> _applyMapping(Channel ch, String epgChannelId) async {
    await Sql.setManualEpgOverride(ch.id!, epgChannelId);
    if (!mounted) return;
    setState(() {
      // Update the in-memory channel so the tile updates instantly
      ch.epgChannelId = epgChannelId;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('"${ch.name}" → $epgChannelId'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _clearMapping(Channel ch) async {
    await Sql.setManualEpgOverride(ch.id!, null);
    if (!mounted) return;
    setState(() => ch.epgChannelId = null);
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _EpgIdPickerDialog extends StatefulWidget {
  final String channelName;
  final String? currentId;
  final List<(String, String)> epgIds;

  const _EpgIdPickerDialog({
    required this.channelName,
    required this.currentId,
    required this.epgIds,
  });

  @override
  State<_EpgIdPickerDialog> createState() => _EpgIdPickerDialogState();
}

class _EpgIdPickerDialogState extends State<_EpgIdPickerDialog> {
  String _query = '';

  List<(String, String)> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.epgIds;
    return widget.epgIds
        .where(
          (e) =>
              e.$1.toLowerCase().contains(q) ||
              e.$2.toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Assign EPG for "${widget.channelName}"',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ),
          // Search box
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DpadTextField(
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search EPG IDs…',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          const SizedBox(height: 8),
          // List
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.45,
            ),
            child: _buildList(),
          ),
          // Cancel
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    final items = _filtered;
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('No EPG IDs match.', textAlign: TextAlign.center),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: items.length,
      itemBuilder: (ctx, i) {
        final (id, sample) = items[i];
        final isCurrent = id == widget.currentId;
        return ListTile(
          dense: true,
          leading: isCurrent
              ? Icon(
                  Icons.check,
                  color: Theme.of(context).colorScheme.primary,
                  size: 18,
                )
              : const SizedBox(width: 18),
          title: Text(id, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: sample.isNotEmpty
              ? Text(
                  sample,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                )
              : null,
          selected: isCurrent,
          onTap: () => Navigator.pop(ctx, id),
        );
      },
    );
  }
}
