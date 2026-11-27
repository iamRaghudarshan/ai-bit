import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/comments_client.dart';
import '../../data/yt_repository.dart';
import '../../player/playback_controller.dart';
import 'library_widgets.dart';

/// Collapsed comments card shown under the video, matching the real app: a
/// heading and the top comment, opening the full list on tap.
///
/// Comments cost two network round trips, so they are loaded lazily and their
/// failure is silent — a video that has them disabled should simply show no
/// card rather than an error the user can do nothing about.
class CommentsPreview extends StatefulWidget {
  const CommentsPreview({super.key, required this.videoId});

  final String videoId;

  @override
  State<CommentsPreview> createState() => _CommentsPreviewState();
}

class _CommentsPreviewState extends State<CommentsPreview> {
  CommentPage? _page;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CommentsPreview old) {
    super.didUpdateWidget(old);
    if (old.videoId != widget.videoId) {
      setState(() {
        _page = null;
        _loading = true;
      });
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final page = await context.read<YtRepository>().comments(widget.videoId);
      if (!mounted) return;
      setState(() {
        _page = page;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final page = _page;

    // Nothing to show and nothing to say: comments are off, or unavailable.
    if (!_loading && (page == null || page.comments.isEmpty)) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Material(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: page == null
              ? null
              : () => showCommentsSheet(context, widget.videoId, page),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Comments',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (page?.totalLabel != null)
                      Text(
                        page!.totalLabel!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                    const Spacer(),
                    const Icon(Icons.unfold_more, size: 18),
                  ],
                ),
                const SizedBox(height: 10),
                if (_loading)
                  const SizedBox(
                    height: 20,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else
                  _CommentRow(comment: page!.comments.first, compact: true),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full comment list, paged as it is scrolled.
Future<void> showCommentsSheet(
  BuildContext context,
  String videoId,
  CommentPage first,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _CommentsSheet(videoId: videoId, first: first),
  );
}

/// Opens the comment list at once, with the loading state inside the sheet,
/// for callers that would otherwise wait on the network before anything
/// appears (the Shorts rail). [initialSize] is the sheet's starting height as
/// a fraction of the screen; [barrierColor] lets the caller keep what is
/// above the sheet visible.
Future<void> showCommentsSheetLoading(
  BuildContext context,
  String videoId,
  Future<CommentPage> first, {
  double initialSize = 0.6,
  Color? barrierColor,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: barrierColor,
    builder: (_) => FutureBuilder<CommentPage>(
      future: first,
      builder: (context, snap) {
        final page = snap.data;
        if (page != null && page.comments.isNotEmpty) {
          return _CommentsSheet(
            videoId: videoId,
            first: page,
            initialSize: initialSize,
          );
        }
        final done = snap.connectionState == ConnectionState.done;
        return DraggableScrollableSheet(
          initialChildSize: initialSize,
          minChildSize: initialSize < 0.5 ? initialSize : 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, _) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  children: [
                    Text(
                      'Comments',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Center(
                  child: !done
                      ? const CircularProgressIndicator()
                      : Text(
                          snap.hasError
                              ? 'Comments unavailable'
                              : 'No comments yet',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _CommentsSheet extends StatefulWidget {
  const _CommentsSheet({
    required this.videoId,
    required this.first,
    this.initialSize = 0.85,
  });

  final String videoId;
  final CommentPage first;
  final double initialSize;

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final _scroll = ScrollController();
  final _repliesScroll = ScrollController();

  late List<VideoComment> _comments = widget.first.comments.toList();
  late String? _continuation = widget.first.continuation;
  late final List<CommentSort> _sorts = widget.first.sorts;
  late int _sort = _initialSort();
  bool _loadingMore = false;
  bool _sorting = false;

  /// The comment whose replies are open, or null for the main list. Replies
  /// open as their own view inside this sheet — back arrow, the comment on
  /// top, the thread under it — rather than expanding in place, which is
  /// how YouTube does it and keeps a long thread from shoving the rest of
  /// the list off screen.
  VideoComment? _thread;
  List<VideoComment> _replies = const [];
  String? _repliesContinuation;
  bool _loadingReplies = false;

  int _initialSort() {
    final i = widget.first.sorts.indexWhere((s) => s.selected);
    return i < 0 ? 0 : i;
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _repliesScroll.addListener(_onRepliesScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _repliesScroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    // Fetch the next page before the end is reached, so scrolling does not
    // visibly stall at the bottom.
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  void _onRepliesScroll() {
    if (_repliesScroll.position.pixels >
        _repliesScroll.position.maxScrollExtent - 400) {
      _loadMoreReplies();
    }
  }

  Future<void> _loadMore() async {
    final token = _continuation;
    if (_loadingMore || _sorting || token == null) return;
    setState(() => _loadingMore = true);
    try {
      final page = await context.read<YtRepository>().moreComments(token);
      if (!mounted) return;
      setState(() {
        _comments.addAll(page.comments);
        _continuation = page.comments.isEmpty ? null : page.continuation;
        _loadingMore = false;
      });
    } catch (e) {
      debugPrint('AI BIT: comments paging failed — $e');
      if (!mounted) return;
      // Stop trying rather than retrying forever on every scroll tick.
      setState(() {
        _continuation = null;
        _loadingMore = false;
      });
    }
  }

  Future<void> _sortBy(int index) async {
    if (index == _sort || _sorting) return;
    final previous = _sort;
    setState(() {
      _sort = index;
      _sorting = true;
    });
    try {
      final page = await context.read<YtRepository>().sortedComments(
        _sorts,
        index,
      );
      if (!mounted) return;
      setState(() {
        _comments = page.comments.toList();
        _continuation = page.continuation;
        _sorting = false;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (e) {
      debugPrint('AI BIT: comments sort failed — $e');
      if (!mounted) return;
      setState(() {
        _sort = previous;
        _sorting = false;
      });
    }
  }

  Future<void> _openReplies(VideoComment comment) async {
    final token = comment.repliesToken;
    if (token == null) return;
    setState(() {
      _thread = comment;
      _replies = const [];
      _repliesContinuation = token;
    });
    await _loadMoreReplies();
  }

  Future<void> _loadMoreReplies() async {
    final token = _repliesContinuation;
    final thread = _thread;
    if (_loadingReplies || token == null || thread == null) return;
    setState(() => _loadingReplies = true);
    try {
      final page = await context.read<YtRepository>().commentRepliesPage(token);
      if (!mounted || _thread != thread) return;
      setState(() {
        _replies = [..._replies, ...page.comments];
        _repliesContinuation = page.comments.isEmpty ? null : page.continuation;
        _loadingReplies = false;
      });
    } catch (e) {
      debugPrint('AI BIT: replies failed — $e');
      if (!mounted) return;
      setState(() {
        _repliesContinuation = null;
        _loadingReplies = false;
      });
    }
  }

  void _closeReplies() => setState(() {
    _thread = null;
    _replies = const [];
    _repliesContinuation = null;
  });

  /// A timestamp in a comment: jump the video there and get out of the way,
  /// as YouTube does. Only for the video these comments belong to.
  void _seek(Duration to) {
    final player = context.read<PlaybackController>();
    if (player.current?.id != widget.videoId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Open the video to jump to that moment.')),
      );
      return;
    }
    player.seek(to);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thread = _thread;
    return PopScope(
      // Back from a replies view returns to the list rather than closing.
      canPop: thread == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _thread != null) _closeReplies();
      },
      child: DraggableScrollableSheet(
        initialChildSize: widget.initialSize,
        minChildSize: widget.initialSize < 0.5 ? widget.initialSize : 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, sheetScroll) => Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(thread == null ? 16 : 4, 4, 8, 4),
              child: Row(
                children: [
                  if (thread != null)
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: 'Back to comments',
                      onPressed: _closeReplies,
                    ),
                  Text(
                    thread == null ? 'Comments' : 'Replies',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (thread == null && widget.first.totalLabel != null)
                    Text(
                      widget.first.totalLabel!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    // pop, not maybePop: closes the sheet from a replies
                    // view too, where PopScope only intercepts Back.
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            if (thread == null && _sorts.length >= 2)
              FeedChipRow(
                labels: [for (final s in _sorts) s.label],
                selected: _sort,
                onSelected: _sortBy,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              ),
            const Divider(height: 1),
            if (_sorting) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: thread == null ? _buildList() : _buildThread(thread),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _comments.length + (_continuation != null ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _comments.length) {
          return const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final comment = _comments[i];
        return _CommentRow(
          comment: comment,
          onSeek: _seek,
          onReplies: comment.repliesToken == null
              ? null
              : () => _openReplies(comment),
        );
      },
    );
  }

  Widget _buildThread(VideoComment thread) {
    final theme = Theme.of(context);
    return ListView.builder(
      controller: _repliesScroll,
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: _replies.length + 2,
      itemBuilder: (context, i) {
        if (i == 0) {
          return ColoredBox(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
            child: Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: _CommentRow(comment: thread, onSeek: _seek, expanded: true),
            ),
          );
        }
        if (i == _replies.length + 1) {
          if (_repliesContinuation == null && !_loadingReplies) {
            return _replies.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No replies could be loaded.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  )
                : const SizedBox(height: 16);
          }
          return const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        // Replies sit indented under the comment, threaded.
        return Padding(
          padding: const EdgeInsets.only(left: 40),
          child: _CommentRow(comment: _replies[i - 1], onSeek: _seek, small: true),
        );
      },
    );
  }
}

/// One comment as YouTube draws it: an optional "Pinned by" line, the
/// author (in a grey pill when it is the creator) and age, the text
/// collapsed at four lines with "Read more" and its timestamps as links,
/// then likes, the creator's heart, and the replies link.
class _CommentRow extends StatefulWidget {
  const _CommentRow({
    required this.comment,
    this.compact = false,
    this.onSeek,
    this.onReplies,
    this.expanded = false,
    this.small = false,
  });

  final VideoComment comment;

  /// Two lines and no toolbar, for the collapsed preview card.
  final bool compact;

  /// A tapped timestamp; null draws timestamps as plain text.
  final ValueChanged<Duration>? onSeek;

  /// Opens this comment's replies; null hides the link.
  final VoidCallback? onReplies;

  /// Starts with the full text shown (the parent comment above its replies).
  final bool expanded;

  /// A reply: a smaller avatar.
  final bool small;

  @override
  State<_CommentRow> createState() => _CommentRowState();
}

class _CommentRowState extends State<_CommentRow> {
  static const _collapsedLines = 4;
  static const _link = Color(0xFF3EA6FF);

  late bool _expanded = widget.expanded;
  final List<TapGestureRecognizer> _recognizers = [];

  VideoComment get comment => widget.comment;
  bool get compact => widget.compact;

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  void _clearRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  /// The text with each timestamp a link, when a seek target exists.
  TextSpan _textSpan(TextStyle style) {
    _clearRecognizers();
    final onSeek = widget.onSeek;
    if (onSeek == null || compact) return TextSpan(text: comment.text, style: style);
    return TextSpan(
      style: style,
      children: [
        for (final span in splitCommentTimestamps(comment.text))
          if (span.seekTo == null)
            TextSpan(text: span.text)
          else
            TextSpan(
              text: span.text,
              style: const TextStyle(color: _link, fontWeight: FontWeight.w500),
              recognizer: (TapGestureRecognizer()
                    ..onTap = () => onSeek(span.seekTo!))
                  .also(_recognizers.add),
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final textStyle = theme.textTheme.bodyMedium!.copyWith(height: 1.35);
    final span = _textSpan(textStyle);

    final author = comment.isCreator
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              child: Text(
                comment.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          )
        : Text(
            comment.author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(fontSize: 12, color: muted),
          );

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 0 : 16,
        vertical: compact ? 0 : 10,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: compact ? 12 : (widget.small ? 12 : 18),
            backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.1),
            foregroundImage: comment.avatarUrl == null
                ? null
                : CachedNetworkImageProvider(
                    comment.avatarUrl!,
                    maxWidth: 96,
                    maxHeight: 96,
                  ),
            child: const Icon(Icons.person, size: 16),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (comment.pinnedText != null && !compact) ...[
                  Row(
                    children: [
                      Icon(Icons.push_pin_outlined, size: 13, color: muted),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          comment.pinnedText!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11.5,
                            color: muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                ],
                Row(
                  children: [
                    Flexible(child: author),
                    if (comment.publishedText != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        comment.publishedText!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 12,
                          color: muted,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                if (compact)
                  Text(
                    comment.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textStyle,
                  )
                else
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final painter = TextPainter(
                        text: span,
                        maxLines: _collapsedLines,
                        textDirection: Directionality.of(context),
                        textScaler: MediaQuery.textScalerOf(context),
                      )..layout(maxWidth: constraints.maxWidth);
                      final long = painter.didExceedMaxLines;
                      painter.dispose();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text.rich(
                            span,
                            maxLines: _expanded ? null : _collapsedLines,
                            overflow: _expanded ? null : TextOverflow.ellipsis,
                          ),
                          if (long)
                            GestureDetector(
                              onTap: () => setState(() => _expanded = !_expanded),
                              child: Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  _expanded ? 'Show less' : 'Read more',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: muted,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                if (!compact) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.thumb_up_outlined, size: 15, color: muted),
                      // Nothing beside the thumb when nobody has liked it,
                      // rather than an empty label holding the gap open.
                      if (comment.likeLabel != null) ...[
                        const SizedBox(width: 5),
                        Text(
                          comment.likeLabel!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 12,
                            color: muted,
                          ),
                        ),
                      ],
                      const SizedBox(width: 18),
                      Icon(Icons.thumb_down_outlined, size: 15, color: muted),
                      if (comment.isHearted) ...[
                        const SizedBox(width: 16),
                        _CreatorHeart(avatarUrl: comment.heartAvatarUrl),
                      ],
                    ],
                  ),
                  if (comment.replyCount > 0 && widget.onReplies != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: widget.onReplies,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 4,
                          ),
                          child: Text(
                            comment.replyCount == 1
                                ? '1 reply'
                                : '${comment.replyCount} replies',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: _link,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The creator's heart: their avatar with a small red heart on its corner.
class _CreatorHeart extends StatelessWidget {
  const _CreatorHeart({this.avatarUrl});

  final String? avatarUrl;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Hearted by the creator',
      child: SizedBox(
        width: 22,
        height: 20,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            CircleAvatar(
              radius: 9,
              backgroundColor:
                  Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
              foregroundImage: avatarUrl == null
                  ? null
                  : CachedNetworkImageProvider(avatarUrl!, maxWidth: 54, maxHeight: 54),
            ),
            const Positioned(
              right: -2,
              bottom: -2,
              child: Icon(Icons.favorite, size: 11, color: Color(0xFFFF4E45)),
            ),
          ],
        ),
      ),
    );
  }
}

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}
