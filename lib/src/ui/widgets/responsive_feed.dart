import 'package:flutter/material.dart';

import '../../data/models.dart';

/// How many feed columns a viewport of [width] logical pixels should show.
///
/// 600 is Material's phone/tablet boundary: a small tablet held portrait is
/// 600–720dp wide, and a single stretched phone card there looks nothing like
/// the YouTube app, which switches to a two-column grid at exactly this size.
int feedColumnsFor(double width) {
  if (width >= 1400) return 4;
  if (width >= 1000) return 3;
  if (width >= 600) return 2;
  return 1;
}

/// A video feed that is a plain single-column list on phones and fans out into
/// a spaced multi-column grid on wider screens, the way the YouTube app lays
/// its feed out on tablets.
///
/// The two builders exist because the phone and tablet items are different
/// widgets, not the same widget resized: Home shows full-width [VideoCard]s on
/// a phone while Subscriptions and channel tabs show compact rows, but on a
/// tablet they all converge on the same rounded grid card.
class ResponsiveVideoFeed extends StatelessWidget {
  const ResponsiveVideoFeed({
    super.key,
    required this.videos,
    required this.listItemBuilder,
    required this.gridItemBuilder,
    this.header,
    this.listPadding = EdgeInsets.zero,
  });

  final List<VideoBrief> videos;

  /// Builds the item at index for the single-column phone layout.
  final Widget Function(BuildContext context, int index) listItemBuilder;

  /// Builds the item at index for a grid cell on wider screens.
  final Widget Function(BuildContext context, int index) gridItemBuilder;

  /// Optional widget that scrolls with the feed above the first row —
  /// the Continue-watching shelf on Home.
  final Widget? header;

  final EdgeInsets listPadding;

  /// Horizontal inset of the grid and the gap between its columns.
  static const _gutter = 16.0;

  /// Vertical room under a cell's thumbnail for avatar, two title lines and
  /// the meta line, with slack so large fonts do not clip against the fixed
  /// cell height.
  static const _metaHeight = 108.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = feedColumnsFor(width);
        final headerCount = header == null ? 0 : 1;

        if (columns == 1) {
          return ListView.builder(
            padding: listPadding,
            itemCount: videos.length + headerCount,
            addAutomaticKeepAlives: false,
            itemBuilder: (context, index) {
              if (header != null && index == 0) return header!;
              return listItemBuilder(context, index - headerCount);
            },
          );
        }

        // Cells need a fixed height (thumbnail for the cell width plus the
        // meta block) so no row ever clips regardless of the column count.
        final cellWidth =
            (width - _gutter * 2 - _gutter * (columns - 1)) / columns;
        final cellHeight = cellWidth * 9 / 16 + _metaHeight;

        return CustomScrollView(
          slivers: [
            if (header != null) SliverToBoxAdapter(child: header),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(_gutter, 8, _gutter, 8),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: _gutter,
                  mainAxisSpacing: 8,
                  mainAxisExtent: cellHeight,
                ),
                delegate: SliverChildBuilderDelegate(
                  gridItemBuilder,
                  childCount: videos.length,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
