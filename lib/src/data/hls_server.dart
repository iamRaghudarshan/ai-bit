/// Serves generated HLS playlists to the native player over loopback.
///
/// The Android side of this problem needs no server: ExoPlayer is handed a
/// `file://` URL and reads the generated DASH manifest off disk. AVPlayer is
/// not so obliging — loading an HLS playlist from the file system is at best
/// inconsistent across iOS versions, and the approach every app that does this
/// settles on is to serve the playlist over HTTP from inside the app. So that
/// is what this is: an `HttpServer` on 127.0.0.1 that hands out playlists and
/// nothing else.
///
/// **No media passes through here.** The playlists name googlevideo URLs
/// directly, so AVPlayer fetches every byte of video itself, at full speed,
/// exactly as it would from a YouTube-issued manifest. This server answers a
/// few kilobytes per video and is then idle — which also means it is not in
/// the path of background playback: a VOD playlist is read once when the item
/// is opened, not continuously.
///
/// Loopback-bound, so nothing outside the device can reach it. Other apps on
/// the same device could in principle connect to the port, so each session
/// gets a random path prefix — not a security boundary, and it does not need
/// to be, since the contents are public YouTube URLs that expire in hours.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'hls_manifest.dart';

class GeneratedHlsServer {
  GeneratedHlsServer({Random? random})
      : _token = _makeToken(random ?? Random.secure());

  final String _token;
  HttpServer? _server;
  Future<HttpServer?>? _starting;

  /// Playlists by video id. One entry per video currently resolvable; replaced
  /// on re-resolve so a stale set cannot be served.
  final _published = <String, GeneratedHls>{};

  static String _makeToken(Random random) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(12, (_) => alphabet[random.nextInt(alphabet.length)])
        .join();
  }

  /// Publishes [hls] for [videoId] and returns the URL of its master playlist,
  /// or null when the server cannot be started.
  ///
  /// Null rather than throwing, because the caller's next step is the
  /// progressive stream — the same contract `_writeDashManifest` has.
  Future<String?> publish(String videoId, GeneratedHls hls) async {
    final server = await _ensureStarted();
    if (server == null) return null;
    _published[videoId] = hls;
    return 'http://${server.address.address}:${server.port}'
        '/$_token/$videoId/master.m3u8';
  }

  Future<HttpServer?> _ensureStarted() {
    final running = _server;
    if (running != null) return Future.value(running);
    return _starting ??= _start();
  }

  Future<HttpServer?> _start() async {
    try {
      // Port 0 lets the OS pick a free one; a fixed port would collide with
      // whatever else the device is running.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(_handle, onError: (Object e) {
        debugPrint('AI BIT: HLS server error — $e');
      });
      _server = server;
      return server;
    } catch (e) {
      debugPrint('AI BIT: could not start the HLS server — $e');
      return null;
    } finally {
      _starting = null;
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      // /<token>/<videoId>/<name>
      if (segments.length != 3 || segments[0] != _token) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final hls = _published[segments[1]];
      final name = segments[2];
      final body = hls == null
          ? null
          : name == masterPlaylistName
              ? hls.master
              : hls.media[name];
      if (body == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      response.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl')
        // The playlists describe URLs that expire, so nothing downstream
        // should hold on to them.
        ..set(HttpHeaders.cacheControlHeader, 'no-store');
      response.write(body);
      await response.close();
    } catch (e) {
      debugPrint('AI BIT: HLS server could not answer ${request.uri} — $e');
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {
        // The connection is already gone; nothing to report.
      }
    }
  }

  Future<void> dispose() async {
    _published.clear();
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }
}

/// The name of the multivariant playlist inside a published set.
const masterPlaylistName = 'master.m3u8';
