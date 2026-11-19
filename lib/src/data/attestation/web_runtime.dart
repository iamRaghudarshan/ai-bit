import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'runtime_page.dart';

/// A hidden WebView used purely as a JavaScript runtime.
///
/// It is never put on screen. `webview_flutter` creates the native view in
/// the controller's constructor, so a page loads and runs without a widget —
/// which is how NewPipe does the same thing on Android. Both platforms keep
/// executing script in an off-screen page; what they do not do is paint it,
/// and nothing here needs painting.
///
/// See `runtime_page.dart` for what runs inside. The contract is one
/// dispatcher: every call is `aibit.<name>(...args)`, every answer comes back
/// on the `AiBit` channel as `{id, ok, value|error}`, matched to its
/// [Completer] by id. The page is loaded lazily on the first call and
/// reloaded after any failure, since a page half-way through a broken
/// BotGuard run is not worth keeping.
class HiddenWebRuntime {
  HiddenWebRuntime();

  /// Whether this platform has a WebView to run in.
  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  WebViewController? _controller;
  Future<void>? _ready;
  final _pending = <int, Completer<Object?>>{};
  var _nextId = 0;

  /// Scripts injected after every (re)load, in order — the challenge solver
  /// library has to be there whenever the page is.
  final _persistentScripts = <String>[];

  Future<void> _ensureReady() => _ready ??= _start();

  Future<void> _start() async {
    final controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.addJavaScriptChannel(
      'AiBit',
      onMessageReceived: _onMessage,
    );
    final loaded = Completer<void>();
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (_) {
          if (!loaded.isCompleted) loaded.complete();
        },
        onWebResourceError: (error) {
          // Sub-resource failures (a script that would not load) surface as
          // the call's own error; only a failed main document is fatal here.
          if (error.isForMainFrame == true && !loaded.isCompleted) {
            loaded.completeError(StateError(
              'runtime page failed to load: ${error.description}',
            ));
          }
        },
      ),
    );
    await controller.loadHtmlString(
      runtimePageHtml,
      baseUrl: 'https://www.youtube.com',
    );
    await loaded.future.timeout(const Duration(seconds: 20));
    _controller = controller;
    for (final script in _persistentScripts) {
      await controller.runJavaScript(script);
    }
  }

  void _onMessage(JavaScriptMessage message) {
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(message.message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = payload['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null) return;
    if (payload['ok'] == true) {
      completer.complete(payload['value']);
    } else {
      completer.completeError(
        RuntimeException(payload['error']?.toString() ?? 'unknown error'),
      );
    }
  }

  /// Runs `aibit.[name](...[args])` in the page and returns its result.
  Future<Object?> call(
    String name,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    try {
      await _ensureReady();
    } catch (e) {
      _reset();
      rethrow;
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    try {
      await _controller!.runJavaScript(
        '__aibitCall($id, ${jsonEncode(name)}, ${jsonEncode(args)})',
      );
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      _reset();
      rethrow;
    } on RuntimeException {
      // The page answered; it is still a working runtime.
      rethrow;
    } catch (e) {
      _pending.remove(id);
      _reset();
      rethrow;
    }
  }

  /// Injects [script] now and again after every reload.
  Future<void> injectPersistent(String script) async {
    _persistentScripts.add(script);
    if (_controller != null) await _controller!.runJavaScript(script);
  }

  void _reset() {
    _controller = null;
    _ready = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('runtime was reset'));
      }
    }
    _pending.clear();
  }

  void dispose() => _reset();
}

/// An error thrown by the JavaScript side of a call, with its message.
class RuntimeException implements Exception {
  RuntimeException(this.message);
  final String message;

  @override
  String toString() => message;
}
