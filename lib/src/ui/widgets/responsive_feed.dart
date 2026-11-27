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

/// Horizontal inset of the tablet grid and the gap between its columns.
const feedGridGutter = 16.0;

/// Vertical room under a grid cell's thumbnail for avatar, two title lines and
/// the meta line, with slack so large fonts do not clip against the fixed
/// cell height. Shared with [FeedSkeleton] so the skeleton grid is the real
/// grid's shape.
const feedGridMetaHeight = 112.0;

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

  static const _gutter = feedGridGutter;
  static const _metaHeight = feedGridMetaHeight;

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

/// [ResponsiveVideoFeed] as a single sliver, for a feed that shares one
/// CustomScrollView with a floating app bar — Home, where the bar and chip
/// row scroll away with the cards and snap back on the first scroll up.
///
/// A nested scrollable cannot do that: the bar has to live in the same
/// scroll view as the rows it hides behind. Same phone/grid rule, same
/// near-end callback, plus one optional [insert] widget placed after
/// [insertAfter] videos (the Shorts shelf on Home), which in the grid spans
/// the full width between two grids rather than squeezing into a cell.
class SliverVideoFeed extends StatelessWidget {
  const SliverVideoFeed({
    super.key,
    required this.videos,
    required this.listItemBuilder,
    required this.gridItemBuilder,
    this.onNearEnd,
    this.insert,
    this.insertAfter = 2,
  });

  final List<VideoBrief> videos;
  final Widget Function(BuildContext context, int index) listItemBuilder;
  final Widget Function(BuildContext context, int index) gridItemBuilder;
  final VoidCallback? onNearEnd;

  /// A full-width widget dropped into the feed after [insertAfter] videos.
  /// Skipped when the feed is shorter than that.
  final Widget? insert;
  final int insertAfter;

  static const _prefetchRows = ResponsiveVideoFeed._prefetchRows;

  void _maybeNearEnd(int index) {
    if (index >= videos.length - _prefetchRows) onNearEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final at = insertSlot(videos.length, insertAfter, hasInsert: insert != null);
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        final columns = feedColumnsFor(width);

        if (columns == 1) {
          final total = videos.length + (at == null ? 0 : 1);
          return SliverList.builder(
            itemCount: total,
            itemBuilder: (context, index) {
              if (at != null && index == at) return _KeptAlive(child: insert!);
              final row = at != null && index > at ? index - 1 : index;
              _maybeNearEnd(row);
              return listItemBuilder(context, row);
            },
          );
        }

        final cellWidth =
            (width - feedGridGutter * 2 - feedGridGutter * (columns - 1)) /
                columns;
        final delegate = SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: feedGridGutter,
          mainAxisSpacing: 8,
          mainAxisExtent: cellWidth * 9 / 16 + feedGridMetaHeight,
        );
        Widget grid(int from, int to) => SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                  feedGridGutter, 8, feedGridGutter, 8),
              sliver: SliverGrid.builder(
                gridDelegate: delegate,
                itemCount: to - from,
                itemBuilder: (context, i) {
                  _maybeNearEnd(from + i);
                  return gridItemBuilder(context, from + i);
                },
              ),
            );
        if (at == null) return grid(0, videos.length);
        // In the grid the shelf goes after the first full row rather than
        // after a fixed count, so it never leaves a half-empty row above it.
        final split = columns.clamp(0, videos.length);
        return SliverMainAxisGroup(
          slivers: [
            grid(0, split),
            SliverToBoxAdapter(child: insert),
            if (split < videos.length) grid(split, videos.length),
          ],
        );
      },
    );
  }
}

/// Where an inserted widget lands in a feed of [length] videos, or null when
/// there is nothing to insert or too few videos to put it after.
///
/// Pure so the rule is testable: after [after] videos, and only when the
/// feed actually reaches that far — a shelf below a feed of one card would
/// sit under nothing it was meant to break up.
int? insertSlot(int length, int after, {required bool hasInsert}) {
  if (!hasInsert || after < 0 || length < after) return null;
  return after;
}

/// Keeps the inserted shelf's state while it is scrolled off screen, so
/// scrolling past it and back does not refetch its contents.
class _KeptAlive extends StatefulWidget {
  const _KeptAlive({required this.child});

  final Widget child;

  @override
  State<_KeptAlive> createState() => _KeptAliveState();
}

class _KeptAliveState extends State<_KeptAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
