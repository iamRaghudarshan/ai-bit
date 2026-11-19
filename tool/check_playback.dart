// Does playback actually resolve — for MANY videos, on BOTH platforms?
//
//   dart run tool/check_playback.dart [videoId ...]
//
// check_streams.dart asks "do any clients work for this one video". check_dash
// asks "is the manifest we generate valid". Neither answers the question that
// matters after a release: *what fraction of ordinary videos will play, and on
// which platform*. That gap is why "no videos are playing properly" could be
// reported on a build whose two existing probes were both green.
//
// It mirrors YtRepository.resolve()'s decision order exactly:
//
//   1. the player endpoint's hlsManifestUrl           -> plays everywhere
//   2. a DASH manifest built from adaptiveFormats     -> ANDROID ONLY
//   3. the progressive muxed stream (360p)            -> plays everywhere
//   4. the youtube_explode client chain's combined    -> plays everywhere
//   5. audio only                                     -> video unavailable
//   6. nothing                                        -> the red error screen
//
// The platform split is the point. `canUseDash` is Android-only because
// AVPlayer cannot play DASH, so on iOS step 2 does not exist — and a video
// with no HLS and no muxed stream, which resolves perfectly on Android, is the
// red error screen on iOS. Reporting a single pass rate would hide that
// completely.
import 'dart:io';

import 'package:ai_bit/src/data/dash_manifest.dart';
import 'package:ai_bit/src/data/player_client.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

/// The same chain, in the same order, as YtRepository._clientChain.
final _clientChain = <yt.YoutubeApiClient>[
  yt.YoutubeApiClient.androidVr,
  yt.YoutubeApiClient.androidSdkless,
  // ignore: deprecated_member_use
  yt.YoutubeApiClient.android,
  yt.YoutubeApiClient.ios,
  yt.YoutubeApiClient.tv,
];

/// A spread rather than a favourites list: old and new, big and small, music
/// and talk. A probe that only ever checks one famous video measures how well
/// YouTube serves that video.
const _defaultIds = [
  '08xvwdsVUaQ', // the one reported failing: 5y old course video
  'dQw4w9WgXcQ', // ancient, enormous
  'aqz-KE-bpKQ', // Big Buck Bunny, 4K, old
  'jNQXAC9IVRw', // oldest video on YouTube
  'kJQP7kiw5Fk', // music, huge
  '9bZkp7q19f0', // music, old and huge
];

enum Outcome { hls, dash, muxed, chain, audioOnly, failed }

void main(List<String> args) async {
  // --region=IN / --lang=hi. These are NOT cosmetic: `gl` decides what is
  // available, not merely what language the text comes back in, and the app
  // defaults both to the device locale. A probe pinned to the US can therefore
  // pass while the same video is unplayable for the person reporting it.
  var region = 'US';
  var lang = 'en';
  final ids = <String>[];
  for (final a in args) {
    if (a.startsWith('--region=')) {
      region = a.substring(9);
    } else if (a.startsWith('--lang=')) {
      lang = a.substring(7);
    } else {
      ids.add(a);
    }
  }
  if (ids.isEmpty) ids.addAll(_defaultIds);
  stdout.writeln('locale: hl=$lang gl=$region');

  final player = YoutubePlayerClient()..setLocale(language: lang, region: region);
  final explode = yt.YoutubeExplode();

  final android = <String, Outcome>{};
  final ios = <String, Outcome>{};

  for (final id in ids) {
    stdout.writeln('\n===== $id');

    // ---- stage 1-3: the app's own player endpoint
    var hls = false;
    var dashable = false;
    var muxed = false;
    try {
      final streams = await player.fetch(id);
      if (streams != null) {
        hls = streams.hlsUrl != null;
        muxed = streams.muxedUrl != null;
        dashable = buildDashManifest(streams.adaptiveFormats) != null;
        stdout.writeln(
          '  player endpoint: hls=$hls  dash-able=$dashable  muxed=$muxed  '
          '(${streams.adaptiveFormats.length} adaptive)',
        );
      } else {
        stdout.writeln('  player endpoint: returned nothing');
      }
    } catch (e) {
      stdout.writeln('  player endpoint: ERROR ${_short(e)}');
    }

    // ---- stage 4-5: the youtube_explode fallback chain
    var chainCombined = false;
    var chainAudio = false;
    if (!hls && !muxed) {
      for (final client in _clientChain) {
        try {
          final m = await explode.videos.streamsClient
              .getManifest(id, ytClients: [client]);
          if (m.muxed.isNotEmpty) {
            chainCombined = true;
            stdout.writeln('  chain: ${_name(client)} has a combined stream');
            break;
          }
          if (m.audioOnly.isNotEmpty) chainAudio = true;
        } catch (_) {
          // Each client failing is ordinary; only all of them failing matters.
        }
      }
      if (!chainCombined) {
        stdout.writeln(
          '  chain: no combined stream'
          '${chainAudio ? ' (audio only available)' : ''}',
        );
      }
    }

    android[id] = _decide(
      hls: hls,
      dash: dashable,
      canDash: true,
      muxed: muxed,
      chain: chainCombined,
      audio: chainAudio,
    );
    ios[id] = _decide(
      hls: hls,
      dash: dashable,
      canDash: false, // AVPlayer cannot play DASH. This is the whole point.
      muxed: muxed,
      chain: chainCombined,
      audio: chainAudio,
    );
    stdout.writeln(
      '  -> ANDROID: ${android[id]!.name.toUpperCase()}'
      '   iOS: ${ios[id]!.name.toUpperCase()}',
    );
  }

  player.close();
  explode.close();

  stdout.writeln('\n================ SUMMARY ================');
  _report('ANDROID', android);
  _report('iOS    ', ios);

  final iosBroken =
      ios.values.where((o) => o == Outcome.failed || o == Outcome.audioOnly).length;
  final androidBroken = android.values
      .where((o) => o == Outcome.failed || o == Outcome.audioOnly)
      .length;

  stdout.writeln('');
  if (androidBroken > 0) {
    stdout.writeln('FAIL: $androidBroken/${ids.length} videos do not play on Android.');
  }
  if (iosBroken > 0) {
    stdout.writeln('FAIL: $iosBroken/${ids.length} videos do not play on iOS.');
    stdout.writeln('      iOS has no DASH, so every video whose only video');
    stdout.writeln('      source is adaptive tracks is a red error screen.');
  }
  if (androidBroken == 0 && iosBroken == 0) {
    stdout.writeln('OK: every video resolves to real video on both platforms.');
  }
  exit(androidBroken > 0 || iosBroken > 0 ? 1 : 0);
}

Outcome _decide({
  required bool hls,
  required bool dash,
  required bool canDash,
  required bool muxed,
  required bool chain,
  required bool audio,
}) {
  if (hls) return Outcome.hls;
  if (canDash && dash) return Outcome.dash;
  if (muxed) return Outcome.muxed;
  if (chain) return Outcome.chain;
  if (audio) return Outcome.audioOnly;
  return Outcome.failed;
}

void _report(String label, Map<String, Outcome> results) {
  final counts = <Outcome, int>{};
  for (final o in results.values) {
    counts.update(o, (n) => n + 1, ifAbsent: () => 1);
  }
  final playable = results.values
      .where((o) => o != Outcome.failed && o != Outcome.audioOnly)
      .length;
  stdout.writeln(
    '$label  plays with video: $playable/${results.length}   '
    '${counts.entries.map((e) => '${e.key.name}=${e.value}').join('  ')}',
  );
  for (final e in results.entries) {
    if (e.value == Outcome.failed || e.value == Outcome.audioOnly) {
      stdout.writeln('   ${e.value == Outcome.failed ? 'BROKEN ' : 'audio  '} ${e.key}');
    }
  }
}

String _name(yt.YoutubeApiClient c) => c.payload['context']?['client']
        ?['clientName']
        ?.toString() ??
    'client';

String _short(Object e) {
  final s = e.toString().replaceAll('\n', ' ');
  return s.length > 90 ? '${s.substring(0, 90)}…' : s;
}
