import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:provider/provider.dart';

import 'dart:async';

import 'src/core/app_navigator.dart';
import 'src/core/incoming_links.dart';
import 'src/core/theme.dart';
import 'src/data/attestation/attestation_service.dart';
import 'src/data/battery_service.dart';
import 'src/data/data_usage_service.dart';
import 'src/data/db.dart';
import 'src/data/download_manager.dart';
import 'src/data/kids_guard.dart';
import 'src/data/interests.dart';
import 'src/data/network_service.dart';
import 'src/data/ranker_trainer.dart';
import 'src/data/settings.dart';
import 'src/data/storage_service.dart';
import 'src/data/yt_repository.dart';
import 'src/player/playback_controller.dart';
import 'src/data/models.dart';
import 'src/ui/app_lock_page.dart';
import 'src/ui/playlist_page.dart';
import 'src/ui/root_shell.dart';
import 'src/ui/update_prompt.dart';
import 'src/ui/watch_page.dart';
import 'src/ui/widgets/now_playing_overlay.dart';

// The navigator key and route observer live in src/core/app_navigator.dart:
// the now-playing bar needs them too, and it is built outside the Navigator.
final _navigatorKey = appNavigatorKey;
final _routeStack = appRouteStack;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The single largest difference in perceived smoothness against YouTube on
  // the phones this app is used on: a 90/120Hz panel runs a Flutter app at
  // 60Hz unless the app asks for more, and OEM skins (Xiaomi above all) never
  // volunteer it. Not awaited — the first frame must not wait on a display
  // mode negotiation — and any failure is logged, since some skins refuse.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    unawaited(
      FlutterDisplayMode.setHighRefreshRate().catchError((Object e) {
        debugPrint('AI BIT: high refresh rate not available - $e');
      }),
    );
  }
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // Both are needed before the first frame: the feed reads history to
  // personalise itself, and the theme comes from settings.
  final database = await AppDatabase.open();
  final settings = await SettingsService.load();

  runApp(AiBitApp(database: database, settings: settings));

  // History retention, once per launch and deliberately off the first frame.
  // It is one indexed DELETE, but nothing on screen waits for it, so it has no
  // business inside the cold start ahead of the feed.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _pruneHistory(database, settings);
    // Links tapped or shared from other apps: the one that launched us, and
    // any that arrive while we are running.
    IncomingLinks.initial().then((link) {
      if (link != null) _openIncomingLink(link);
    });
    IncomingLinks.listen(_openIncomingLink);
    // The HD-unlock token takes a bot check to mint; done now, behind the
    // feed, so the first video does not pay for it. A few seconds late so it
    // does not compete with the feed for the first paint.
    Timer(const Duration(seconds: 4), () {
      _navigatorKey.currentContext?.read<YtRepository>().warmUpHd();
    });
    // Newer build? Told once per build, or blocked if below the manifest's
    // minimum. After the feed's first paint, like everything else here.
    Timer(const Duration(seconds: 2), () {
      if (_navigatorKey.currentContext == null) return;
      UpdatePrompt.checkOnLaunch(() => _navigatorKey.currentContext!);
    });
  });
}

/// Opens whatever a tapped or shared YouTube link points at.
///
/// Playlists are checked first, as the search box does: a `watch?v=…&list=…`
/// link names both and the list is the more specific intent. Text that is
/// neither is logged and dropped — the SEND filter accepts any plain text,
/// so a note shared by mistake must not do anything surprising.
Future<void> _openIncomingLink(String text) async {
  final context = _navigatorKey.currentContext;
  if (context == null) return;
  final reference = youtubeReferenceIn(text) ?? text.trim();
  final repo = context.read<YtRepository>();

  final playlistId = YtRepository.parsePlaylistId(reference);
  if (playlistId != null) {
    await PlaylistPage.openById(context, playlistId);
    return;
  }
  final videoId = YtRepository.parseVideoId(reference);
  if (videoId != null) {
    try {
      final details = await repo.videoDetails(videoId);
      // Re-read after the await rather than reused: the lookup took a network
      // round trip and the Navigator may have been rebuilt meanwhile.
      final ctx = _navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      await WatchPage.open(ctx, VideoBrief.fromYt(details));
    } catch (e) {
      debugPrint('AI BIT: could not open shared video $videoId — $e');
      final ctx = _navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(const SnackBar(
        content: Text('That link could not be opened. It may be private or removed.'),
      ));
    }
    return;
  }
  debugPrint('AI BIT: shared text is not a YouTube link: $text');
}

/// Applies `Settings -> History retention`.
///
/// Fire-and-forget: a failure here must not stop the app, because the failure
/// mode is "old rows stay", which costs nothing.
Future<void> _pruneHistory(
  AppDatabase database,
  SettingsService settings,
) async {
  final days = settings.historyRetentionDays;
  // 0 means keep forever. deleteHistoryOlderThan agrees, but returning early
  // keeps the log below honest about what actually ran.
  if (days <= 0) return;
  try {
    final removed = await database.deleteHistoryOlderThan(days);
    debugPrint(
      'AI BIT: history retention removed $removed rows older than $days days',
    );
  } catch (e) {
    // Logged, never silent: a retention setting that quietly never runs is
    // exactly the dead feature a bare catch has hidden in this codebase before.
    debugPrint('AI BIT: history retention failed - $e');
  }
}

/// Constrains the browser preview to an iPhone-sized viewport inside a device
/// bezel, and lies to [MediaQuery] about the screen size and safe-area insets
/// so every layout decision matches what an actual phone would produce.
Widget _phoneFrame(BuildContext context, Widget? child) {
  // iPhone 14/15 logical size, notch inset and home-indicator inset.
  const screen = Size(390, 844);
  const safeTop = 47.0;
  const safeBottom = 34.0;

  return ColoredBox(
    color: const Color(0xFF0B0C0F),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: FittedBox(
          // Scales the whole phone down when the browser window is short,
          // keeping the aspect ratio honest.
          fit: BoxFit.contain,
          child: Container(
            width: screen.width,
            height: screen.height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(46),
              border: Border.all(color: const Color(0xFF2A2C31), width: 8),
              boxShadow: const [
                BoxShadow(color: Colors.black87, blurRadius: 40, spreadRadius: 4),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(38),
              child: Stack(
                children: [
                  MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      size: screen,
                      devicePixelRatio: 3,
                      padding: const EdgeInsets.only(
                        top: safeTop,
                        bottom: safeBottom,
                      ),
                      viewPadding: const EdgeInsets.only(
                        top: safeTop,
                        bottom: safeBottom,
                      ),
                      viewInsets: EdgeInsets.zero,
                      textScaler: TextScaler.noScaling,
                    ),
                    child: child ?? const SizedBox.shrink(),
                  ),
                  // Dynamic Island, purely so the safe-area gap reads as a
                  // phone rather than dead space.
                  Positioned(
                    top: 11,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        width: 118,
                        height: 30,
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class AiBitApp extends StatelessWidget {
  const AiBitApp({super.key, required this.database, required this.settings});

  final AppDatabase database;
  final SettingsService settings;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppDatabase>.value(value: database),
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        // Declared before the repository so it can be handed in. A
        // ChangeNotifier because Settings shows its live status — the last
        // thing this project needs is another feature that is silently off.
        ChangeNotifierProvider<WebAttestation>(
          create: (_) => WebAttestation(),
        ),
        Provider<YtRepository>(
          create: (context) =>
              YtRepository(attestation: context.read<WebAttestation>()),
          dispose: (_, repo) => repo.dispose(),
        ),
        // Keeps every YouTube endpoint pointed at the language and region the
        // user chose. A ProxyProvider so it re-runs when settings change,
        // rather than only at startup: switching region has to take effect on
        // the next pull-to-refresh, not the next launch.
        ProxyProvider2<YtRepository, SettingsService, _LocaleBinding>(
          update: (context, repo, settings, _) => _LocaleBinding(
            repo,
            language: settings.contentLanguage,
            region: settings.contentRegion,
            deviceLocale: View.of(context).platformDispatcher.locale,
            hdUnlock: settings.hdUnlock,
          ),
          lazy: false,
        ),
        // NetworkService and BatteryService are not lazy on purpose. Their
        // whole job is to *observe* the device, and a provider built on first
        // read only starts watching once some screen happens to ask — so the
        // first quality decision of the session would see the safe defaults
        // (Wi-Fi, full battery) rather than the truth. Both cancel their
        // subscriptions through ChangeNotifierProvider's dispose.
        ChangeNotifierProvider<NetworkService>(
          lazy: false,
          create: (_) => NetworkService()..start(),
        ),
        ChangeNotifierProvider<BatteryService>(
          lazy: false,
          create: (_) => BatteryService()..start(),
        ),
        // Same reasoning: load() is what fills in how much of today's Kids
        // allowance is already spent, and the Home countdown reads it on the
        // first frame.
        ChangeNotifierProvider<KidsGuard>(
          lazy: false,
          create: (context) => KidsGuard(
            database: context.read<AppDatabase>(),
            settings: context.read<SettingsService>(),
          )..load(),
        ),
        // Plain Provider for the same reason as DataUsageService below: the
        // trainer holds one cached object and has nothing to notify about.
        // Not lazy, because the first feed load of the session asks it for
        // weights and a provider built on first read would hand back the
        // untrained defaults for that load.
        Provider<RankerTrainer>(
          lazy: false,
          create: (context) => RankerTrainer(
            database: context.read<AppDatabase>(),
            settings: context.read<SettingsService>(),
          ),
        ),
        // Plain Provider: DataUsageService is a stateless facade over the
        // database, with nothing to notify about and nothing to dispose.
        Provider<DataUsageService>(
          create: (context) => DataUsageService(
            database: context.read<AppDatabase>(),
            settings: context.read<SettingsService>(),
          ),
        ),
        // Declared after the four above so context.read finds them: a provider
        // can only read providers listed before it in the same MultiProvider.
        ChangeNotifierProvider<PlaybackController>(
          create: (context) => PlaybackController(
            repository: context.read<YtRepository>(),
            database: context.read<AppDatabase>(),
            settings: context.read<SettingsService>(),
            kidsGuard: context.read<KidsGuard>(),
            batteryService: context.read<BatteryService>(),
            networkService: context.read<NetworkService>(),
            dataUsage: context.read<DataUsageService>(),
          ),
        ),
        ChangeNotifierProvider<DownloadManager>(
          create: (context) => DownloadManager(
            repository: context.read<YtRepository>(),
            database: context.read<AppDatabase>(),
            // Without this the manager's _usage stays null and every finished
            // transfer skips recordDownload, so the usage screen showed an
            // estimated streaming figure next to a permanent zero for
            // downloads - the one half of that screen that is measured rather
            // than guessed.
            dataUsage: context.read<DataUsageService>(),
          )..restore(),
        ),
        Provider<StorageService>(
          create: (context) => StorageService(
            context.read<AppDatabase>(),
            context.read<DownloadManager>(),
          ),
        ),
      ],
      child: Consumer<SettingsService>(
        builder: (context, settings, _) => MaterialApp(
          title: 'AI BIT',
          debugShowCheckedModeBanner: false,
          navigatorKey: _navigatorKey,
          navigatorObservers: [_routeStack],
          themeMode: settings.themeMode,
          theme: buildTheme(
            Brightness.light,
            accent: Color(settings.accentColor),
          ),
          darkTheme: buildTheme(
            Brightness.dark,
            accent: Color(settings.accentColor),
            amoled: settings.amoledBlack,
          ),
          builder: (context, child) {
            // The now-playing bar goes on first, so it is inside the lock
            // shield: a bar showing what is playing — with artwork and a title
            // — must not be visible over a locked app.
            final withBar = NowPlayingOverlay(
              routes: _routeStack,
              child: child ?? const SizedBox.shrink(),
            );
            // The gate wraps the Navigator, so the shield hides whatever route
            // is on top rather than only the feed underneath it.
            final gated = _AppLockGate(child: withBar);
            // In a browser the app would otherwise stretch across a desktop
            // window, which is nothing like how it looks on a phone. The frame
            // stays outermost so the shield appears inside the bezel.
            return kIsWeb ? _phoneFrame(context, gated) : gated;
          },
          home: const RootShell(),
        ),
      ),
    );
  }
}

/// Applies the chosen content language and region to the repository.
///
/// A value rather than a widget so it can sit in the provider list and re-run
/// whenever [SettingsService] notifies. Both settings store an empty string
/// for "match my device", resolved here against the platform locale rather
/// than at write time — so changing the phone's language changes the feed,
/// instead of pinning whatever it happened to be on the day of install.
class _LocaleBinding {
  _LocaleBinding(
    YtRepository repository, {
    required String language,
    required String region,
    required Locale deviceLocale,
    required bool hdUnlock,
  }) {
    // Rides along for the same reason: a setting the repository reads has to
    // reach it when it changes, not at the next launch.
    repository.hdUnlockEnabled = hdUnlock;
    repository.setLocale(
      // en and US as the last resort, which is what every endpoint was
      // hardcoded to before any of this existed.
      language: resolveCode(language, deviceLocale.languageCode, 'en'),
      region: resolveCode(region, deviceLocale.countryCode ?? '', 'US'),
    );
  }
}

/// Holds the app behind [AppLockPage] whenever the lock is armed.
///
/// Two things have to be true for this to be worth anything. It has to run at
/// cold start, and it has to run again when the app comes back from the
/// background — a lock that only fires on a fresh launch protects nothing,
/// because the copy that matters is the one already sitting in the task
/// switcher.
///
/// Nothing here is a security boundary; `AppLockService` spells out why a hash
/// in a preferences file cannot be one.
class _AppLockGate extends StatefulWidget {
  const _AppLockGate({required this.child});

  final Widget child;

  @override
  State<_AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<_AppLockGate>
    with WidgetsBindingObserver {
  /// True while the shield is up. Kept separate from whether the PIN route is
  /// on screen, so a gate that was dismissed without being answered still
  /// hides the app.
  bool _locked = false;

  /// Guards against pushing a second PIN route over the first. It happens for
  /// real: some Android skins background the app to show the fingerprint
  /// sheet, which delivers a `resumed` while the first prompt is still open.
  bool _prompting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_armed) {
      _locked = true;
      // The Navigator has not been built yet, so the route cannot be pushed
      // from initState.
      WidgetsBinding.instance.addPostFrameCallback((_) => _prompt());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Read live rather than cached: switching the lock on in Settings has to
  /// arm the very next background, and switching it off must not leave a stale
  /// gate behind.
  bool get _armed {
    final settings = context.read<SettingsService>();
    // An armed lock with no PIN stored would be unpassable — AppLockService
    // .verify refuses an empty hash on purpose — so it counts as unarmed here,
    // matching the same rule inside AppLockPage.unlock.
    return settings.appLockEnabled && settings.appLockPinHash.isNotEmpty;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
        // `paused`, never `inactive`. inactive fires for a notification
        // banner, the app switcher and Android Picture-in-Picture, and
        // re-locking for a banner would make the app unusable.
        //
        // The shield goes up on the way *out* rather than on the way back in
        // because the recents thumbnail is captured around here: a lock that
        // still lets the task switcher show your watch history is theatre.
        if (_armed && !_locked) setState(() => _locked = true);
      case AppLifecycleState.resumed:
        // Prompting waits for this rather than happening at `paused` so the
        // biometric sheet is raised with the app actually on screen. Asked for
        // while backgrounded it comes back as a failure the user never caused,
        // and AppLockService turns every biometric failure into the PIN pad.
        if (_locked) _prompt();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _prompt() async {
    if (_prompting || !mounted) return;
    final navigatorContext = _navigatorKey.currentContext;
    if (navigatorContext == null) {
      // Before the first frame there is no navigator to push onto. The shield
      // stays up with its own Unlock button, so this is recoverable rather
      // than a dead end — and it is logged rather than swallowed.
      debugPrint('AI BIT: app lock could not reach the navigator yet');
      return;
    }

    // A state change, not just a flag: the shield is drawn above the
    // Navigator, so it has to come down for the PIN pad — pushed onto that
    // Navigator — to be seen and tapped. Before this the pad opened
    // invisibly under the shield, Unlock then did nothing because a prompt
    // was "already open", and the owner was locked out of the app. Found on
    // an emulator. The pad route is opaque and has no transition, so nothing
    // behind it shows while the shield is down.
    setState(() => _prompting = true);
    bool unlocked;
    try {
      unlocked = await AppLockPage.unlock(navigatorContext);
    } finally {
      if (mounted) {
        setState(() => _prompting = false);
      } else {
        _prompting = false;
      }
    }
    if (!mounted) return;
    // unlock() only resolves false when the route was popped programmatically
    // — it refuses a system back. Leaving the shield up is the safe reading of
    // that, and the user comes back through the button rather than having the
    // pad shoved at them by a loop.
    if (unlocked) setState(() => _locked = false);
  }

  /// The window-security state last sent to Android, so it is sent on change
  /// only.
  bool? _secureSent;
  static const _window = MethodChannel('ai.bit/window');

  /// Keeps the task-switcher thumbnail blank while the lock is armed. The
  /// shield below goes up at `paused`, which is after Android has already
  /// taken the thumbnail — seen on an emulator showing Settings in recents
  /// with the lock on — so the window itself has to be marked secure.
  void _syncWindowSecurity(bool armed) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (_secureSent == armed) return;
    _secureSent = armed;
    _window.invokeMethod<void>('setSecure', armed).catchError((Object e) {
      _secureSent = null;
      debugPrint('AI BIT: window security not applied - $e');
    });
  }

  @override
  Widget build(BuildContext context) {
    final armed = context.select<SettingsService, bool>(
      (s) => s.appLockEnabled && s.appLockPinHash.isNotEmpty,
    );
    _syncWindowSecurity(armed);
    return Stack(
      children: [
        widget.child,
        if (_locked && !_prompting)
          Positioned.fill(
            child: GestureDetector(
              // Opaque, so the hit test stops at the shield. Without it a tap
              // or a fling would still reach the live feed behind it.
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: _LockShield(onUnlock: _prompt),
            ),
          ),
      ],
    );
  }
}

/// What the app looks like while locked, and therefore also the frame the
/// recents thumbnail captures.
class _LockShield extends StatelessWidget {
  const _LockShield({required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('AI BIT is locked', style: theme.textTheme.titleMedium),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onUnlock,
              icon: const Icon(Icons.lock_open),
              label: const Text('Unlock'),
            ),
          ],
        ),
      ),
    );
  }
}
