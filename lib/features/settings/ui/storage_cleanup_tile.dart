import 'package:flutter/material.dart';
import 'package:openhiit/core/media/media_store.dart';

class StorageCleanupTile extends StatefulWidget {
  const StorageCleanupTile({super.key});

  @override
  State<StorageCleanupTile> createState() => _StorageCleanupTileState();
}

class _StorageCleanupTileState extends State<StorageCleanupTile> {
  bool _working = false;
  bool _confirming = false;

  String _size(int bytes) => bytes < 1024
      ? '$bytes B'
      : bytes < 1024 * 1024
          ? '${(bytes / 1024).toStringAsFixed(1)} KB'
          : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _clean() async {
    setState(() => _working = true);
    try {
      final candidates = await MediaStore.instance.scanUnused();
      if (!mounted) return;
      if (candidates.isEmpty) {
        _message('No unused media to clean.');
        return;
      }
      final bytes =
          candidates.fold<int>(0, (total, item) => total + item.bytes);
      setState(() => _confirming = true);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Clean unused media?'),
          scrollable: true,
          content: Text(
            '${candidates.length} unused file(s), approximately ${_size(bytes)}, can be removed.\n\n'
            'This permanently deletes imported audio and images that no saved timer uses. '
            'Files used by an open editor or preview are also kept. '
            'Your timer settings, media still in use, and original files outside the app will not be deleted.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
              key: const Key('confirm-clean-unused-media'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Clean'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      setState(() => _confirming = false);
      if (confirmed != true) return;
      final result = await MediaStore.instance.cleanUnused();
      _message(result.failed > 0
          ? 'Removed ${result.deleted} file(s) (${_size(result.bytes)}). ${result.failed} file(s) could not be removed. Try again.'
          : result.deleted == 0
              ? 'No unused media to clean.'
              : 'Removed ${result.deleted} unused file(s). Freed ${_size(result.bytes)}.');
    } on MediaBusyException catch (error) {
      _message(error.toString());
    } catch (_) {
      _message(
          'Unable to check unused media. Cleanup stopped; please try again.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
        key: const Key('clean-unused-media'),
        leading: const Icon(Icons.cleaning_services_outlined),
        title: const Text('Clean unused media'),
        subtitle:
            const Text('Remove imported audio and images that no timer uses'),
        trailing: _working && !_confirming
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
            : null,
        enabled: !_working,
        onTap: _working ? null : _clean,
      );
}
