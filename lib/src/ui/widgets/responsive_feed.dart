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
    this.onNearEnd,
    this.footer,
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

  /// Called while building a row within [_prefetchRows] of the end, so the
  /// caller can fetch more.
  ///
  /// Driven from the item builder rather than a ScrollController because both
  /// layouts here scroll — a ListView on phones and a CustomScrollView on
  /// tablets — and a controller would have to be threaded through both and
  /// kept in step with the column count. The builder already knows which row
  /// it is on, in either layout.
  ///
  /// The caller is responsible for ignoring repeat calls: building is not a
  /// one-shot event and this will fire several times as rows come into view.
  final VoidCallback? onNearEnd;

  /// Optional widget below the last row — the "loading more" spinner.
  final Widget? footer;

  /// How far from the end to ask for more. Three rows is roughly a screen on
  /// a phone, which is enough to have the next batch in hand before the user
  /// reaches the bottom and sees an end that should not be there.
  static const _prefetchRows = 3;

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

        final footerCount = footer == null ? 0 : 1;

        if (columns == 1) {
          return ListView.builder(
            padding: listPadding,
            itemCount: videos.length + headerCount + footerCount,
            addAutomaticKeepAlives: false,
            itemBuilder: (context, index) {
              if (header != null && index == 0) return header!;
              final row = index - headerCount;
              if (row >= videos.length) return footer!;
              if (row >= videos.length - _prefetchRows) onNearEnd?.call();
              return listItemBuilder(context, row);
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
                  (context, index) {
                    if (index >= videos.length - _prefetchRows) {
                      onNearEnd?.call();
                    }
                    return gridItemBuilder(context, index);
                  },
                  childCount: videos.length,
                ),
              ),
            ),
            if (footer != null) SliverToBoxAdapter(child: footer),
          ],
        );
      },
    );
  }
}
