import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/empty_state.dart';
import 'mapping_database.dart';

class SyncLogScreen extends StatefulWidget {
  const SyncLogScreen({super.key});

  @override
  State<SyncLogScreen> createState() => _SyncLogScreenState();
}

class _SyncLogScreenState extends State<SyncLogScreen> {
  final _mappingDb = MappingDatabase();

  List<Map<String, Object?>> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final entries = await _mappingDb.getSyncLog();
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  String _formatLine(Map<String, Object?> entry) {
    final ts = entry['timestamp'] as String;
    final dt = DateTime.tryParse(ts);
    final when = dt == null
        ? ts
        : '${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
            '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:'
            '${dt.second.toString().padLeft(2, '0')}';
    return '$when ${entry['message']}';
  }

  Future<void> _copy() async {
    // Oldest first reads more naturally when pasted elsewhere.
    final text = _entries.reversed.map(_formatLine).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Log copied to clipboard')),
    );
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear log?'),
        content: const Text('This removes all detailed log entries.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _mappingDb.clearSyncLog();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Detailed Log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy',
            onPressed: _entries.isEmpty ? null : _copy,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear',
            onPressed: _entries.isEmpty ? null : _clear,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? const EmptyState(
                  icon: Icons.notes,
                  title: 'No log entries yet',
                  subtitle: 'Each sync records what it\ncreated, updated and deleted',
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: _entries.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: SelectableText(
                        _formatLine(_entries[index]),
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ),
    );
  }
}
