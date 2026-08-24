import 'package:flutter/material.dart';

/// YouTube-ish palette. Kept in one place so the player, shell and cards all
/// pull from the same tokens.
abstract final class AppColors {
  static const brand = Color(0xFFFF0033);
  static const darkBg = Color(0xFF0F0F0F);
  static const darkSurface = Color(0xFF1C1C1C);
  static const darkElevated = Color(0xFF272727);
  static const lightBg = Color(0xFFFFFFFF);
  static const lightSurface = Color(0xFFF2F2F2);
}

ThemeData buildTheme(
  Brightness brightness, {
  Color accent = AppColors.brand,
  bool amoled = false,
}) {
  final isDark = brightness == Brightness.dark;
  // AMOLED swaps the dark background to true black so OLED pixels switch off.
  final darkBg = amoled ? const Color(0xFF000000) : AppColors.darkBg;
  // Bottom-nav foreground: crisp white on dark, near-black on light, matching
  // YouTube rather than the seeded scheme's tinted off-white.
  final navFg = isDark ? Colors.white : const Color(0xFF0F0F0F);
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: brightness,
    primary: accent,
    surface: isDark ? darkBg : AppColors.lightBg,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.5,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: isDark ? darkBg : AppColors.lightBg,
      indicatorColor: Colors.transparent,
      elevation: 0,
      height: 62,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      // The seeded ColorScheme tints its neutrals toward the red seed, so
      // scheme.onSurface is an off-white in dark mode rather than the crisp
      // white YouTube's bar uses. Pin the icons and labels to pure white on
      // dark and near-black on light, both selected and unselected, so the bar
      // reads the same as the real app in either theme.
      iconTheme: WidgetStatePropertyAll(
        IconThemeData(size: 26, color: navFg),
      ),
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 10, color: navFg, fontWeight: FontWeight.w500),
      ),
    ),
    // In-page tabs (channel page, history) carried no theme, so they inherited
    // the seeded scheme's tinted label colour and Material's full-width divider
    // — unlike YouTube's, which is plain white/near-black text with a short
    // underline under the selected tab and no divider line. Match that.
    tabBarTheme: TabBarThemeData(
      labelColor: navFg,
      unselectedLabelColor: isDark ? Colors.white60 : Colors.black54,
      indicatorColor: navFg,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: Colors.transparent,
      labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      unselectedLabelStyle:
          const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: isDark
          ? (amoled ? const Color(0xFF0A0A0A) : AppColors.darkSurface)
          : AppColors.lightBg,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.onSurface.withValues(alpha: 0.08),
      space: 1,
      thickness: 1,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: isDark ? AppColors.darkElevated : AppColors.lightSurface,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      labelStyle: TextStyle(fontSize: 13, color: scheme.onSurface),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: accent,
    ),
  );
}
