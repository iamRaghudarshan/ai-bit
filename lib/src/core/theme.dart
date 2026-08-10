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

ThemeData buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.brand,
    brightness: brightness,
    primary: AppColors.brand,
    surface: isDark ? AppColors.darkBg : AppColors.lightBg,
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
      backgroundColor: isDark ? AppColors.darkBg : AppColors.lightBg,
      indicatorColor: Colors.transparent,
      elevation: 0,
      height: 62,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 10, color: scheme.onSurface),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightBg,
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
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.brand,
    ),
  );
}
