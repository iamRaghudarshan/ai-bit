import 'package:flutter/material.dart';

/// YouTube-ish palette. Kept in one place so the player, shell and cards all
/// pull from the same tokens.
///
/// The text and chip tokens are YouTube Android's own neutrals. They exist
/// because `ColorScheme.fromSeed` tints every neutral towards the seed, so a
/// red accent made `onSurface` a faintly pink off-white — visible beside the
/// real app, and the reason card titles never looked quite right.
abstract final class AppColors {
  static const brand = Color(0xFFFF0033);
  static const darkBg = Color(0xFF0F0F0F);
  static const darkSurface = Color(0xFF1C1C1C);
  static const darkElevated = Color(0xFF272727);
  static const lightBg = Color(0xFFFFFFFF);
  static const lightSurface = Color(0xFFF2F2F2);

  // Text.
  static const darkText = Color(0xFFF1F1F1);
  static const darkTextSecondary = Color(0xFFAAAAAA);
  static const lightText = Color(0xFF0F0F0F);
  static const lightTextSecondary = Color(0xFF606060);

  // Chips: unselected fill, selected fill. Selected text is the background.
  static const darkChip = Color(0xFF272727);
  static const darkChipSelected = Color(0xFFF1F1F1);
  static const lightChip = Color(0xFFF2F2F2);
  static const lightChipSelected = Color(0xFF0F0F0F);

  /// The Shorts tab's bottom bar, black in either theme as on YouTube.
  static const shortsBar = Color(0xFF0F0F0F);

  static bool _dark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  /// Primary text: titles, labels.
  static Color text(BuildContext context) =>
      _dark(context) ? darkText : lightText;

  /// Secondary text: channel, views, age. A solid colour rather than an alpha
  /// blend, so it reads the same over a thumbnail placeholder as over the page.
  static Color textSecondary(BuildContext context) =>
      _dark(context) ? darkTextSecondary : lightTextSecondary;

  static Color chip(BuildContext context) =>
      _dark(context) ? darkChip : lightChip;

  static Color chipSelected(BuildContext context) =>
      _dark(context) ? darkChipSelected : lightChipSelected;

  /// Text on a selected chip — the page background, which is what YouTube
  /// does (dark text on the light pill in dark mode, and the reverse).
  static Color chipSelectedText(BuildContext context) =>
      _dark(context) ? darkBg : lightBg;

  /// Press highlight on cards and rows: a flat wash, no ripple.
  static Color pressHighlight(BuildContext context) => _dark(context)
      ? Colors.white.withValues(alpha: 0.10)
      : Colors.black.withValues(alpha: 0.06);
}

ThemeData buildTheme(
  Brightness brightness, {
  Color accent = AppColors.brand,
  bool amoled = false,
}) {
  final isDark = brightness == Brightness.dark;
  // AMOLED swaps the dark background to true black so OLED pixels switch off.
  final darkBg = amoled ? const Color(0xFF000000) : AppColors.darkBg;
  final bg = isDark ? darkBg : AppColors.lightBg;
  final text = isDark ? AppColors.darkText : AppColors.lightText;
  final secondary =
      isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;
  final elevated = isDark
      ? (amoled ? const Color(0xFF1A1A1A) : AppColors.darkElevated)
      : AppColors.lightSurface;
  final highlight = isDark
      ? Colors.white.withValues(alpha: 0.10)
      : Colors.black.withValues(alpha: 0.06);

  // The accent stays the accent (progress bars, LIVE, switches); every
  // neutral is pinned to YouTube's rather than the seed-tinted ones.
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: brightness,
    primary: accent,
    surface: bg,
  ).copyWith(
    onSurface: text,
    onSurfaceVariant: secondary,
    surfaceContainerLowest: bg,
    surfaceContainerLow: isDark ? const Color(0xFF181818) : const Color(0xFFF9F9F9),
    surfaceContainer: isDark ? AppColors.darkSurface : AppColors.lightSurface,
    surfaceContainerHigh: elevated,
    surfaceContainerHighest:
        isDark ? const Color(0xFF3F3F3F) : const Color(0xFFE5E5E5),
    outline: isDark ? const Color(0xFF717171) : const Color(0xFF909090),
    outlineVariant: isDark ? const Color(0xFF3F3F3F) : const Color(0xFFE5E5E5),
  );

  final base = ThemeData(useMaterial3: true, brightness: brightness);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
    // A flat wash on press, no sparkle: YouTube's cards highlight, they do not
    // ripple outward, and InkSparkle's shader was also the costliest splash.
    splashFactory: InkRipple.splashFactory,
    highlightColor: highlight,
    splashColor: highlight,
    iconTheme: IconThemeData(color: text),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      iconTheme: IconThemeData(color: text, size: 24),
      actionsIconTheme: IconThemeData(color: text, size: 24),
      titleTextStyle: TextStyle(
        color: text,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.5,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: bg,
      indicatorColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 56,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      // Pinned rather than taken from the scheme, both selected and
      // unselected, so the bar reads as YouTube's in either theme.
      iconTheme: WidgetStatePropertyAll(IconThemeData(size: 24, color: text)),
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 10, color: text, fontWeight: FontWeight.w500),
      ),
    ),
    // In-page tabs (channel page, history): plain text, short underline under
    // the selected tab, no full-width divider — YouTube's.
    tabBarTheme: TabBarThemeData(
      labelColor: text,
      unselectedLabelColor: secondary,
      indicatorColor: text,
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
      showDragHandle: true,
      dragHandleColor: isDark ? const Color(0xFF717171) : const Color(0xFFCCCCCC),
      dragHandleSize: const Size(40, 4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: isDark ? const Color(0xFF3F3F3F) : const Color(0xFFE5E5E5),
      space: 1,
      thickness: 1,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: isDark ? AppColors.darkChip : AppColors.lightChip,
      selectedColor:
          isDark ? AppColors.darkChipSelected : AppColors.lightChipSelected,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      labelStyle: TextStyle(fontSize: 14, color: text),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      iconColor: text,
      textColor: text,
      subtitleTextStyle: TextStyle(fontSize: 12, color: secondary),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: accent,
      // Pull-to-refresh is neutral on YouTube; the spinner colour itself is
      // set where a RefreshIndicator is built, since this theme's `color` is
      // the accent the resume bars and download spinners keep.
      refreshBackgroundColor: elevated,
    ),
  );
}
