import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/comments_client.dart';
import '../../data/yt_repository.dart';

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

class _CommentsSheet extends StatefulWidget {
  const _CommentsSheet({required this.videoId, required this.first});

  final String videoId;
  final CommentPage first;

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final _scroll = ScrollController();
  late final List<VideoComment> _comments = widget.first.comments.toList();
  late String? _continuation = widget.first.continuation;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    // Fetch the next page before the end is reached, so scrolling does not
    // visibly stall at the bottom.
    if (_scroll.position.pixels >
        _scroll.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    final token = _continuation;
    if (_loadingMore || token == null) return;
    setState(() => _loadingMore = true);
    try {
      final page = await context.read<YtRepository>().moreComments(token);
      if (!mounted) return;
      setState(() {
        _comments.addAll(page.comments);
        _continuation = page.continuation;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      // Stop trying rather than retrying forever on every scroll tick.
      setState(() {
        _continuation = null;
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, sheetScroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Text(
                  'Comments',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(width: 8),
                if (widget.first.totalLabel != null)
                  Text(
                    widget.first.totalLabel!,
                    style: Theme.of(context).textTheme.bodySmall,
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
            child: ListView.builder(
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
                return _CommentRow(comment: _comments[i]);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CommentRow extends StatefulWidget {
  const _CommentRow({required this.comment, this.compact = false});

  final VideoComment comment;

  /// Single-line, for the collapsed preview card.
  final bool compact;

  @override
  State<_CommentRow> createState() => _CommentRowState();
}

class _CommentRowState extends State<_CommentRow> {
  List<VideoComment>? _replies;
  bool _loadingReplies = false;
  bool _showReplies = false;

  VideoComment get comment => widget.comment;
  bool get compact => widget.compact;

  /// Replies are a separate request, so they are fetched the first time the
  /// thread is opened and kept afterwards.
  Future<void> _toggleReplies() async {
    if (_showReplies) {
      setState(() => _showReplies = false);
      return;
    }
    setState(() => _showReplies = true);
    if (_replies != null || _loadingReplies) return;

    setState(() => _loadingReplies = true);
    try {
      final replies = await context.read<YtRepository>().commentReplies(
        comment.repliesToken!,
      );
      if (!mounted) return;
      setState(() {
        _replies = replies;
        _loadingReplies = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _replies = const [];
        _loadingReplies = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 0 : 16,
        vertical: compact ? 0 : 10,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: compact ? 14 : 18,
            backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.1),
            backgroundImage: comment.avatarUrl == null
                ? null
                : CachedNetworkImageProvider(comment.avatarUrl!),
            child: comment.avatarUrl != null
                ? null
                : const Icon(Icons.person, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (comment.isPinned) ...[
                      const Icon(Icons.push_pin, size: 12),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        comment.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11,
                          color: muted,
                        ),
                      ),
                    ),
                    if (comment.publishedText != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        comment.publishedText!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11,
                          color: muted,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  comment.text,
                  maxLines: compact ? 2 : null,
                  overflow: compact ? TextOverflow.ellipsis : null,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
                ),
                if (!compact) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.thumb_up_outlined, size: 14, color: muted),
                      const SizedBox(width: 5),
                      Text(
                        comment.likeLabel ?? '',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11,
                          color: muted,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Icon(Icons.thumb_down_outlined, size: 14, color: muted),
                      if (comment.replyCount > 0) ...[
                        const SizedBox(width: 12),
                        InkWell(
                          onTap: comment.repliesToken == null
                              ? null
                              : _toggleReplies,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _showReplies
                                      ? Icons.expand_less
                                      : Icons.expand_more,
                                  size: 15,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  '${comment.replyCount} replies',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (_showReplies) _buildReplies(theme),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Replies, indented under the comment they belong to.
  Widget _buildReplies(ThemeData theme) {
    if (_loadingReplies) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(0, 10, 0, 4),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final replies = _replies ?? const <VideoComment>[];
    if (replies.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          'No replies could be loaded.',
          style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10, left: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final reply in replies)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _CommentRow(comment: reply),
            ),
          if (replies.length < widget.comment.replyCount)
            Text(
              'Showing ${replies.length} of ${widget.comment.replyCount}',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 10,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
        ],
      ),
    );
  }
}
