import 'package:flutter/material.dart';

import '../../core/chapters.dart';
import '../../core/format.dart';

/// Full description in a sheet, with any chapters listed as tappable rows.
///
/// A sheet rather than an inline expansion: descriptions run to hundreds of
/// lines, and expanding one in place pushes the comments and up-next list off
/// the bottom of the page.
Future<void> showDescriptionSheet(
  BuildContext context, {
  required String title,
  required String description,
  required void Function(Duration) onSeek,
}) {
  final chapters = parseChapters(description);

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Text(
                  'Description',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(sheetContext),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (chapters.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(
                    'Chapters',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  for (final chapter in chapters)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: SizedBox(
                        width: 56,
                        child: Text(
                          clockLabel(chapter.start),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      title: Text(
                        chapter.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      onTap: () {
                        onSeek(chapter.start);
                        Navigator.pop(sheetContext);
                      },
                    ),
                  const Divider(height: 28),
                ],
                SelectableText(
                  description,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
