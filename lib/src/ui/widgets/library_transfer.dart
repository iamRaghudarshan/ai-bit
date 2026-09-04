/// Getting the library in and out of the app, in one place.
///
/// These three actions are reachable from Settings, Storage and the Library
/// page, and the logic lived in whichever screen happened to grow it first.
/// Sharing it here is not tidiness: a fix to the Takeout importer that only
/// landed in one of three copies would look like the feature was broken on
/// some screens and fine on others.
///
/// Each function owns its own dialogs and messages and never throws, so a
/// caller is a single `onTap`.
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/backup_service.dart';
import '../../data/db.dart';
import '../../data/takeout_service.dart';
import '../../data/yt_repository.dart';


/// Writes the library to a JSON file and hands it to the share sheet.
Future<void> exportLibrary(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final database = context.read<AppDatabase>();
  try {
    final path = await BackupService(database).export();
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], text: 'AI BIT library backup'),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Backup failed: $e')));
  }
}

/// Merges a previously exported JSON backup into this device.
Future<void> restoreLibrary(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final database = context.read<AppDatabase>();

  // FileType.any, not a json extension filter: some Android document
  // providers hide files the filter should show, and a picker that appears
  // empty reads as a broken feature. Nothing is lost by being permissive -
  // BackupService.restore rejects anything that is not an AI BIT backup, and
  // that check is on the content rather than the name.
  final picked = await FilePicker.pickFiles(type: FileType.any);
  if (picked.isEmpty) return;
  final path = picked.first.path;
  if (path == null) return;

  try {
    final summary = await BackupService(database).restore(path);
    messenger.showSnackBar(SnackBar(content: Text(summary)));
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Restore failed — is it an AI BIT backup? ($e)')),
    );
  }
}

/// Imports playlists, subscriptions and watch history from a Google Takeout
/// export.
///
/// Takeout rather than a Google sign-in on purpose: signing in would put a real
/// account behind a client that violates YouTube's terms, and this reaches
/// private playlists without ever authenticating.
///
/// [onDone] fires after a successful import so a screen showing playlists can
/// reload.
Future<void> importFromTakeout(
  BuildContext context, {
  VoidCallback? onDone,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  final service = TakeoutService(
    database: context.read<AppDatabase>(),
    repository: context.read<YtRepository>(),
  );

  final picked = await FilePicker.pickFiles(
    // Not FileType.custom with an extension filter: some Android providers
    // hide the very files it is meant to show, and a picker that appears empty
    // reads as a broken feature. The export also mixes .csv and .html.
    type: FileType.any,
  );
  if (picked.isEmpty) return;

  final paths = picked.map((f) => f.path).whereType<String>().toList();
  if (paths.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('No files could be read.')),
    );
    return;
  }

  if (!context.mounted) return;

  final progress = ValueNotifier<TakeoutProgress?>(null);
  var dialogOpen = true;
  // Not dismissible: the import writes rows as it goes, so dismissing it would
  // leave a half-filled playlist with nothing to say it is still growing.
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TakeoutProgressDialog(progress: progress),
    ).then((_) => dialogOpen = false),
  );

  TakeoutResult result;
  try {
    result = await service.importFiles(
      paths,
      onProgress: (p) => progress.value = p,
    );
  } catch (e) {
    result = const TakeoutResult(playlists: 0, imported: 0, failed: 0);
    debugPrint('AI BIT: takeout import failed - $e');
  }

  if (dialogOpen) navigator.pop();
  progress.dispose();
  onDone?.call();

  messenger.showSnackBar(
    SnackBar(
      content: Text(
        result.isEmpty && result.skippedFiles > 0
            ? 'Those files held nothing to import. Pick the "-videos.csv" '
                  'playlist files, subscriptions.csv, or watch-history.html.'
            : result.summary,
      ),
      duration: const Duration(seconds: 6),
    ),
  );
}

/// Progress while a Takeout import runs.
///
/// Shows the playlist being filled and a count, because a playlist import is
/// one network lookup per video - Takeout stores ids and nothing else - and a
/// bare spinner for two minutes reads as a hang.
class _TakeoutProgressDialog extends StatelessWidget {
  const _TakeoutProgressDialog({required this.progress});

  final ValueNotifier<TakeoutProgress?> progress;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Importing'),
      content: ValueListenableBuilder<TakeoutProgress?>(
        valueListenable: progress,
        builder: (context, value, _) {
          final total = value?.total ?? 0;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value?.playlistName ?? 'Reading the export…',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                // Indeterminate until the first file is parsed: a bar sitting
                // at zero looks stuck. Subscriptions and history finish before
                // this ever gets a total, which is the point of them not
                // needing lookups.
                value: total == 0 ? null : (value!.done / total),
              ),
              const SizedBox(height: 8),
              Text(
                total == 0
                    ? 'Reading files. Playlists then look up every video, one '
                          'at a time.'
                    : '${value!.done} of $total'
                          '${value.failed > 0 ? ' — ${value.failed} unavailable' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
    );
  }
}
