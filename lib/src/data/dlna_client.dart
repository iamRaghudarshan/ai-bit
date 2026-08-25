import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// A DLNA/UPnP MediaRenderer found on the local network — a TV, an AV receiver
/// or a set-top box that can be handed a URL and told to play it.
@immutable
class DlnaDevice {
  const DlnaDevice({
    required this.name,
    required this.controlUrl,
    required this.location,
  });

  /// `friendlyName` from the device description, e.g. "Living Room TV".
  final String name;

  /// Absolute URL of the AVTransport:1 service's control endpoint, already
  /// resolved against [location].
  final String controlUrl;

  /// The device description URL that came back in the SSDP LOCATION header.
  final String location;

  /// Two scans of the same network must yield equal devices, or a re-scan would
  /// drop the user's current selection out of the list.
  @override
  bool operator ==(Object other) =>
      other is DlnaDevice && other.controlUrl == controlUrl;

  @override
  int get hashCode => controlUrl.hashCode;

  @override
  String toString() => 'DlnaDevice($name, $controlUrl)';
}

/// A renderer refused a command, or could not be reached.
///
/// Discovery stays silent (see [DlnaClient.discover]), but a failed *command*
/// is something the user explicitly asked for and must be able to see.
class DlnaException implements Exception {
  const DlnaException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Casting over DLNA/UPnP, in pure Dart — no SDK, no account, no receiver id.
///
/// This is the replacement for Chromecast, which was ruled out because it needs
/// the Google Cast SDK and a registered receiver application id. DLNA asks
/// nothing of us: discovery is an SSDP M-SEARCH datagram and control is a
/// handful of SOAP posts. Nearly every smart TV of the last decade answers it.
///
/// What gets cast is the resolved stream URL, so the same constraint as the
/// in-app player applies — the renderer takes exactly one URL and plays it
/// itself, which means a combined video+audio stream.
///
/// **iOS 14 and later gate SSDP behind an entitlement.** Sending to
/// 239.255.255.250 requires `com.apple.developer.networking.multicast`, which
/// Apple grants only on request. Without it iOS silently drops the datagram and
/// [discover] returns nothing — that is the platform, not a bug in this file.
/// Android has no equivalent gate; the multicast lock some UPnP stacks take is
/// unnecessary here because M-SEARCH replies arrive as ordinary unicast to the
/// port we bound.
class DlnaClient {
  DlnaClient([http.Client? client]) : _http = client ?? http.Client();

  final http.Client _http;

  /// The one service we drive. A renderer that does not expose it cannot be
  /// told to play anything, so devices without it are dropped from discovery.
  static const avTransport = 'urn:schemas-upnp-org:service:AVTransport:1';

  static const _ssdpAddress = '239.255.255.250';
  static const _ssdpPort = 1900;

  /// Every MediaRenderer on the LAN that exposes AVTransport:1.
  ///
  /// Returns an EMPTY LIST — never throws — when the socket cannot be opened or
  /// the datagram cannot be sent. Multicast is blocked outright on plenty of
  /// real networks (guest and corporate Wi-Fi, most VPNs) and on iOS without the
  /// entitlement described above; "no devices found" is the honest answer there,
  /// while an exception would surface as a crash on a screen the user opened out
  /// of curiosity.
  Future<List<DlnaDevice>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    // RawDatagramSocket does not exist in the browser, and web is only a layout
    // preview target here anyway.
    if (kIsWeb) return const [];

    final locations = <String>{};
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)
          .timeout(const Duration(seconds: 5));
      final bound = socket;
      bound.broadcastEnabled = true;

      bound.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = bound.receive();
        if (datagram == null) return;
        // Renderers are not reliable about sending valid UTF-8 in every header,
        // and a decode failure would otherwise kill the whole scan for the sake
        // of one badly behaved device.
        final text = utf8.decode(datagram.data, allowMalformed: true);
        final location = _headerValue(text, 'location');
        if (location != null) locations.add(location);
      }, onError: (Object _) {
        // A single bad datagram must not end the scan: whatever was collected
        // before it is still worth returning.
      });

      final search = utf8.encode('M-SEARCH * HTTP/1.1\r\n'
          'HOST: $_ssdpAddress:$_ssdpPort\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: $avTransport\r\n'
          '\r\n');
      final target = InternetAddress(_ssdpAddress);

      // Sent three times: SSDP is UDP with no retransmission, and a lone
      // M-SEARCH is routinely dropped by consumer access points — which shows up
      // as "the TV is only found every other scan".
      final deadline = DateTime.now().add(timeout);
      for (var attempt = 0; attempt < 3; attempt++) {
        bound.send(search, target, _ssdpPort);
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      // MX: 2 tells devices they may wait up to two seconds before replying, so
      // the socket has to stay open for the rest of the caller's window.
      final remaining = deadline.difference(DateTime.now());
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
    } catch (e) {
      // An empty list is the honest answer - the sheet's empty state already
      // explains the ordinary causes (wrong Wi-Fi, guest network, client
      // isolation). But binding a UDP socket also fails for reasons that are
      // NOT "no TV here": a missing multicast entitlement, or a platform with
      // no datagram socket at all. Logged so those are distinguishable in a
      // logcat instead of looking identical to an empty room.
      debugPrint('AI BIT: SSDP discovery could not run - $e');
      return const [];
    } finally {
      socket?.close();
    }

    // Each LOCATION points at a device description document. Fetched in
    // parallel so one slow or dead device does not add its timeout to all the
    // others.
    final described = await Future.wait(locations.map(_describe));
    return described.whereType<DlnaDevice>().toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// Hands [url] to [device] and starts playback.
  ///
  /// [title] rides along as DIDL-Lite metadata; without it most TVs show the raw
  /// googlevideo URL — or nothing at all — as the now-playing label.
  ///
  /// Throws [DlnaException] if the renderer refuses or cannot be reached.
  Future<void> play(DlnaDevice device, String url, {String title = ''}) async {
    await _soap(device, 'SetAVTransportURI', {
      'InstanceID': '0',
      'CurrentURI': url,
      'CurrentURIMetaData': _didl(url, title),
    });
    await _soap(device, 'Play', {'InstanceID': '0', 'Speed': '1'});
  }

  Future<void> pause(DlnaDevice device) =>
      _soap(device, 'Pause', {'InstanceID': '0'});

  Future<void> stop(DlnaDevice device) =>
      _soap(device, 'Stop', {'InstanceID': '0'});

  /// A complete SOAP request body for an AVTransport [action].
  ///
  /// Pure and static, so it can be tested without a renderer on the network.
  ///
  /// Argument values are XML-escaped, and that is not cosmetic: a stream URL is
  /// full of `&` separators, and one unescaped ampersand makes the envelope
  /// invalid XML. Renderers do not report that — they accept the post, answer
  /// 200, and then sit on a black screen, which reads as "casting is broken"
  /// rather than "the request was malformed".
  static String buildSoapEnvelope(String action, Map<String, String> args) {
    final out = StringBuffer()
      ..write('<?xml version="1.0" encoding="utf-8"?>')
      ..write('<s:Envelope '
          'xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
          's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">')
      ..write('<s:Body>')
      ..write('<u:$action xmlns:u="$avTransport">');
    args.forEach((name, value) {
      out.write('<$name>${escapeXml(value)}</$name>');
    });
    out
      ..write('</u:$action>')
      ..write('</s:Body>')
      ..write('</s:Envelope>');
    return out.toString();
  }

  /// XML text escaping. `&` has to be replaced first, or the ampersands
  /// introduced by the later replacements would themselves be escaped again.
  static String escapeXml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  void close() => _http.close();

  /// The now-playing metadata literal.
  ///
  /// It is escaped once here, for the DIDL document itself, and a second time by
  /// [buildSoapEnvelope], because DIDL travels as *text* inside a SOAP argument.
  /// That double escaping is correct, not a mistake to "fix".
  static String _didl(String url, String title) {
    final name = escapeXml(title.isEmpty ? 'Video' : title);
    return '<DIDL-Lite '
        'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="-1" restricted="1">'
        '<dc:title>$name</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '<res protocolInfo="http-get:*:video/mp4:*">${escapeXml(url)}</res>'
        '</item>'
        '</DIDL-Lite>';
  }

  Future<void> _soap(
    DlnaDevice device,
    String action,
    Map<String, String> args,
  ) async {
    final http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse(device.controlUrl),
            headers: {
              'Content-Type': 'text/xml; charset="utf-8"',
              'SOAPACTION': '"$avTransport#$action"',
            },
            body: utf8.encode(buildSoapEnvelope(action, args)),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Turned into a message rather than swallowed: unlike discovery this is a
      // command the user issued, so silence would look like the tap did nothing.
      throw DlnaException('${device.name} did not respond.');
    }
    if (response.statusCode != 200) {
      // UPnP faults carry the real reason in errorDescription; the status code
      // alone is always 500 and says nothing.
      final fault = _tag(
        utf8.decode(response.bodyBytes, allowMalformed: true),
        'errorDescription',
      );
      throw DlnaException(fault == null
          ? '${device.name} refused $action (HTTP ${response.statusCode}).'
          : '${device.name} refused $action: $fault.');
    }
  }

  /// Fetches and parses one device description, or null if it is unreachable or
  /// is not a renderer this client can drive.
  Future<DlnaDevice?> _describe(String location) async {
    try {
      final response =
          await _http.get(Uri.parse(location)).timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return null;
      final xml = utf8.decode(response.bodyBytes, allowMalformed: true);

      final controlPath = _avTransportControlPath(xml);
      // No AVTransport means no way to tell it to play — printers, routers and
      // media *servers* all answer SSDP and would otherwise clutter the list.
      if (controlPath == null) return null;

      // The classic DLNA bug: controlURL is almost always relative
      // ("/upnp/control/AVTransport1", sometimes with no leading slash), and
      // treating it as absolute produces a request to a host that does not
      // exist. It resolves against URLBase when the description supplies one,
      // and against the LOCATION URL otherwise.
      final base = _tag(xml, 'URLBase') ?? location;
      final controlUrl = Uri.parse(base).resolve(controlPath).toString();

      final name = _unescapeXml(_tag(xml, 'friendlyName') ?? '').trim();
      return DlnaDevice(
        // Falling back to the host keeps an unnamed device selectable instead of
        // showing a blank row.
        name: name.isEmpty ? Uri.parse(location).host : name,
        controlUrl: controlUrl,
        location: location,
      );
    } catch (_) {
      // One unreachable or malformed device must not empty the whole scan.
      return null;
    }
  }

  /// The `controlURL` of the AVTransport:1 service, exactly as written in the
  /// document — usually a relative path, which the caller resolves.
  static String? _avTransportControlPath(String xml) {
    final services = RegExp(
      r'<service\b[^>]*>(.*?)</service>',
      dotAll: true,
      caseSensitive: false,
    );
    for (final match in services.allMatches(xml)) {
      final block = match.group(1)!;
      final type = _tag(block, 'serviceType') ?? '';
      // Prefix match rather than equality: a few renderers advertise the service
      // type with a vendor suffix appended.
      if (!type.startsWith(avTransport)) continue;
      final control = _tag(block, 'controlURL');
      if (control != null && control.isNotEmpty) return _unescapeXml(control);
    }
    return null;
  }

  /// Reads one element's text. A regex rather than a parser because `xml` is
  /// only a transitive dependency here, and a device description is a flat,
  /// shallow document — not worth a direct dependency for four tag lookups.
  static String? _tag(String xml, String name) {
    final match = RegExp(
      '<(?:[\\w-]+:)?$name(?:\\s[^>]*)?>(.*?)</(?:[\\w-]+:)?$name>',
      dotAll: true,
      caseSensitive: false,
    ).firstMatch(xml);
    return match?.group(1)?.trim();
  }

  /// Value of a header in a raw SSDP/HTTP response, matched case-insensitively
  /// because devices spell them every possible way ("LOCATION", "Location").
  static String? _headerValue(String response, String name) {
    final wanted = name.toLowerCase();
    for (final line in const LineSplitter().convert(response)) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      if (line.substring(0, colon).trim().toLowerCase() != wanted) continue;
      final value = line.substring(colon + 1).trim();
      return value.isEmpty ? null : value;
    }
    return null;
  }

  static String _unescapeXml(String value) => value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      // Last, mirroring escapeXml's order, so an escaped "&amp;lt;" survives as
      // the literal "&lt;" instead of collapsing to "<".
      .replaceAll('&amp;', '&');
}
