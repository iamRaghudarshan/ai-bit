import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/db.dart';
import '../data/models.dart';
import '../data/saved_playlists.dart';
import '../data/yt_repository.dart';
import 'channel_page.dart';
import 'watch_page.dart';
import 'widgets/playlist_header.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// A YouTube playlist — someone else's, as opposed to the local ones in
/// `PlaylistDetailPage`.
///
/// Playing any entry queues the rest behind it, so a playlist behaves like a
/// playlist rather than a list of unrelated videos. Pages past the first
/// hundred load as the list is scrolled, which the page could not do before:
/// a 1,800-video uploads playlist stopped at 100.
class PlaylistPage extends StatefulWidget {
  const PlaylistPage({super.key, required this.playlist});

  final PlaylistBrief playlist;

  static Future<void> open(BuildContext context, PlaylistBrief playlist) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PlaylistPage(playlist: playlist)),
    );
  }

  /// Opens by id alone, for a pasted playlist link.
  static Future<void> openById(BuildContext context, String playlistId) {
    return open(
      context,
      PlaylistBrief(id: playlistId, title: 'Playlist'),
    );
  }

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  final _scroll = ScrollController();
  bool _collapsed = false;

  List<VideoBrief> _videos = const [];
  late PlaylistBrief _header = widget.playlist;
  String? _continuation;
  bool _loading = true;
  bool _loadingMore = false;
  bool _saved = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final collapsed = _scroll.hasClients && _scroll.offset > 280;
      if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
    });
    SavedPlaylists.contains(widget.playlist.id).then((saved) {
      if (mounted) setState(() => _saved = saved);
    });
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = context.read<YtRepository>();
    try {
      final page = await repo.remotePlaylistPage(widget.playlist.id);
      if (!mounted) return;
      if (page.videos.isEmpty) throw StateError('empty first page');
      setState(() {
        _header = _merge(page.header);
        _videos = page.videos;
        _continuation = page.continuation;
        _loading = false;
      });
      return;
    } catch (e) {
      debugPrint('AI BIT: playlist page failed for ${widget.playlist.id} — $e');
    }
    // The older route: the package for the header, the plain list for rows.
    try {
      final videos = await repo.remotePlaylist(widget.playlist.id);
      if (!mounted) return;
      setState(() {
        _videos = videos;
        _loading = false;
      });
      if (_header.title == 'Playlist') {
        final info = await repo.playlistInfo(widget.playlist.id);
        if (mounted) setState(() => _header = _merge(info));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// What the page fetched, over what the caller already knew.
  PlaylistBrief _merge(PlaylistBrief fetched) {
    final known = widget.playlist;
    return PlaylistBrief(
      id: known.id,
      title: fetched.title != 'Playlist' ? fetched.title : known.title,
      videoCount: fetched.videoCount ?? known.videoCount,
      thumbnailUrl: fetched.thumbnailUrl ?? known.thumbnailUrl,
      channelId: fetched.channelId ?? known.channelId,
      author: fetched.author ?? known.author,
      description: fetched.description ?? known.description,
      viewCountLabel: fetched.viewCountLabel ?? known.viewCountLabel,
    );
  }

  void _maybeMore(int index) {
    if (_continuation == null || _loadingMore || index < _videos.length - 5) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _more());
  }

  Future<void> _more() async {
    final token = _continuation;
    if (!mounted || token == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await context.read<YtRepository>().remotePlaylistMore(token);
      if (!mounted) return;
      final seen = _videos.map((v) => v.id).toSet();
      setState(() {
        _videos = [..._videos, ...page.videos.where((v) => seen.add(v.id))];
        _continuation = page.videos.isEmpty ? null : page.continuation;
        _loadingMore = false;
      });
    } catch (e) {
      debugPrint('AI BIT: playlist paging failed — $e');
      if (!mounted) return;
      setState(() {
        _continuation = null;
        _loadingMore = false;
      });
    }
  }

  Future<void> _toggleSaved() async {
    final messenger = ScaffoldMessenger.of(context);
    final saved = await SavedPlaylists.toggle(
      PlaylistBrief(
        id: _header.id,
        title: _header.title,
        videoCount: _header.videoCount,
        thumbnailUrl: _header.thumbnailUrl ?? _videos.firstOrNull?.thumbUrl,
        channelId: _header.channelId,
        author: _header.author,
      ),
    );
    if (!mounted) return;
    setState(() => _saved = saved);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          saved ? 'Saved to your library' : 'Removed from your library',
        ),
      ),
    );
  }

  void _showMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.library_add_outlined),
              title: const Text('Copy to a local playlist'),
              subtitle: Text(
                'Saves the ${_videos.length} videos loaded so far on this device',
              ),
              enabled: _videos.isNotEmpty,
              onTap: () {
                Navigator.pop(sheetContext);
                _saveAll();
              },
            ),
            if (_header.channelId != null)
              ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: const Text('Go to channel'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  ChannelPage.open(
                    context,
                    _header.channelId!,
                    title: _header.author,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  String get _meta {
    final count = _header.videoCount ?? (_videos.isEmpty ? null : _videos.length);
    return [
      'Playlist',
      if (count != null) count == 1 ? '1 video' : '$count videos',
      ?_header.viewCountLabel,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final header = PlaylistHeader(
      title: _header.title,
      coverUrl: _header.thumbnailUrl ?? _videos.firstOrNull?.thumbUrl,
      owner: _header.author,
      onOwner: _header.channelId == null
          ? null
          : () => ChannelPage.open(
              context,
              _header.channelId!,
              title: _header.author,
            ),
      meta: _meta,
      description: _header.description,
      actions: [
        PlaylistAction(
          icon: _saved ? Icons.bookmark_added : Icons.bookmark_add_outlined,
          tooltip: _saved ? 'Remove from library' : 'Save playlist',
          onPressed: _toggleSaved,
        ),
        PlaylistAction(
          icon: Icons.share_outlined,
          tooltip: 'Share playlist',
          onPressed: () => SharePlus.instance.share(
            ShareParams(uri: Uri.parse(widget.playlist.shareUrl)),
          ),
        ),
        PlaylistAction(
          icon: Icons.more_vert,
          tooltip: 'More',
          onPressed: _showMenu,
        ),
      ],
      onPlayAll: _videos.isEmpty
          ? null
          : () => WatchPage.openQueue(context, _videos),
      onShuffle: _videos.isEmpty
          ? null
          : () => WatchPage.openQueue(context, _videos.toList()..shuffle()),
    );

    return Scaffold(
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverAppBar(
            pinned: true,
            title: AnimatedOpacity(
              opacity: _collapsed ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: Text(
                _header.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          SliverToBoxAdapter(child: header),
          if (_loading)
            const SliverToBoxAdapter(
              child: SizedBox(height: 400, child: FeedSkeleton(count: 3)),
            )
          else if (_videos.isEmpty)
            SliverToBoxAdapter(
              child: EmptyState(
                icon: Icons.playlist_remove,
                title: 'Nothing to play',
                message: _error ?? 'This playlist is empty or unavailable.',
              ),
            )
          else
            SliverList.builder(
              itemCount: _videos.length + 1,
              itemBuilder: (context, i) {
                if (i == _videos.length) {
                  return _continuation == null
                      ? const SizedBox(height: 32)
                      : const Padding(
                          padding: EdgeInsets.all(20),
                          child: Center(child: CircularProgressIndicator()),
                        );
                }
                _maybeMore(i);
                final video = _videos[i];
                return VideoRow(
                  video: video,
                  onTap: () => WatchPage.openQueue(context, _videos, startAt: i),
                  onMenu: () => showVideoMenu(context, video),
                );
              },
            ),
        ],
      ),
    );
  }

  Future<void> _saveAll() async {
    final db = context.read<AppDatabase>();
    final messenger = ScaffoldMessenger.of(context);
    final name = await showNewPlaylistDialog(context, initial: _header.title);
    if (name == null) return;
    final id = await db.createPlaylist(name);
    for (final video in _videos) {
      await db.addToPlaylist(id, video);
    }
    messenger.showSnackBar(
      SnackBar(content: Text('Saved ${_videos.length} videos to "$name"')),
    );
  }
}
