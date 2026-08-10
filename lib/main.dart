import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'src/core/theme.dart';
import 'src/data/db.dart';
import 'src/data/download_manager.dart';
import 'src/data/settings.dart';
import 'src/data/yt_repository.dart';
import 'src/player/playback_controller.dart';
import 'src/ui/root_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
        Provider<YtRepository>(
          create: (_) => YtRepository(),
          dispose: (_, repo) => repo.dispose(),
        ),
        ChangeNotifierProvider<PlaybackController>(
          create: (context) => PlaybackController(
            repository: context.read<YtRepository>(),
            database: context.read<AppDatabase>(),
            settings: context.read<SettingsService>(),
          ),
        ),
        ChangeNotifierProvider<DownloadManager>(
          create: (context) => DownloadManager(
            repository: context.read<YtRepository>(),
            database: context.read<AppDatabase>(),
          )..restore(),
        ),
      ],
      child: Consumer<SettingsService>(
        builder: (context, settings, _) => MaterialApp(
          title: 'AI BIT',
          debugShowCheckedModeBanner: false,
          themeMode: settings.themeMode,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          // In a browser the app would otherwise stretch across a desktop
          // window, which is nothing like how it looks on a phone.
          builder: kIsWeb ? _phoneFrame : null,
          home: const RootShell(),
        ),
      ),
    );
  }
}
