import 'package:flutter/material.dart';

import '../../features/translation/domain/models/translation_config.dart';
import '../../shared/platform/platform_utils.dart';

/// Compact monochrome workbench, with semantic colors reserved for status.
class AppTheme {
  static const Color _ink = Color(0xFF303038);
  static const Color _inkLight = Color(0xFFE7E7EB);

  static ThemeData light(UiLanguage language) {
    final ColorScheme scheme =
        ColorScheme.fromSeed(
          seedColor: _ink,
          brightness: Brightness.light,
          primary: _ink,
          secondary: const Color(0xFF31734C),
          tertiary: const Color(0xFF946200),
          surface: Colors.white,
          error: const Color(0xFFDC2626),
        ).copyWith(
          onPrimary: Colors.white,
          primaryContainer: const Color(0xFFE7E7EB),
          onPrimaryContainer: const Color(0xFF27272D),
          secondaryContainer: const Color(0xFFF7F7F8),
          onSecondaryContainer: const Color(0xFF27272D),
          tertiaryContainer: const Color(0xFFFFF5DE),
          onTertiaryContainer: const Color(0xFF775000),
          surfaceContainerHighest: const Color(0xFFFFFFFF),
          surfaceContainerHigh: const Color(0xFFF7F7F8),
          surfaceContainer: const Color(0xFFF7F7F8),
          onSurface: const Color(0xFF27272D),
          onSurfaceVariant: const Color(0xFF666670),
          outline: const Color(0xFFB9B9C2),
          outlineVariant: const Color(0xFFE7E7EB),
          shadow: Colors.transparent,
          surfaceTint: Colors.transparent,
        );
    return _baseTheme(scheme, language);
  }

  static ThemeData dark(UiLanguage language) {
    final ColorScheme scheme =
        ColorScheme.fromSeed(
          seedColor: _inkLight,
          brightness: Brightness.dark,
          primary: _inkLight,
          secondary: const Color(0xFF92C5A1),
          tertiary: const Color(0xFFE6BD68),
          surface: const Color(0xFF151517),
          error: const Color(0xFFF87171),
        ).copyWith(
          onPrimary: const Color(0xFF202024),
          primaryContainer: const Color(0xFF34343B),
          onPrimaryContainer: const Color(0xFFEEEEF0),
          secondaryContainer: const Color(0xFF232328),
          onSecondaryContainer: const Color(0xFFEEEEF0),
          tertiaryContainer: const Color(0xFF342B18),
          onTertiaryContainer: const Color(0xFFE6BD68),
          surfaceContainerHighest: const Color(0xFF232328),
          surfaceContainerHigh: const Color(0xFF1B1B1F),
          surfaceContainer: const Color(0xFF1B1B1F),
          onSurface: const Color(0xFFEEEEF0),
          onSurfaceVariant: const Color(0xFFAAAAB4),
          outline: const Color(0xFF666670),
          outlineVariant: const Color(0xFF34343B),
          shadow: Colors.transparent,
          surfaceTint: Colors.transparent,
        );
    return _baseTheme(scheme, language);
  }

  static ThemeData _baseTheme(ColorScheme scheme, UiLanguage language) {
    final bool isWindows = PlatformUtils.isWindows;
    final bool useChineseUiFont = language == UiLanguage.chinese;
    final String? appFontFamily = isWindows
        ? (useChineseUiFont ? 'Microsoft YaHei UI' : 'Segoe UI')
        : null;
    final List<String>? fallbackFonts = isWindows
        ? (useChineseUiFont
              ? const <String>['Microsoft YaHei', 'Segoe UI', 'sans-serif']
              : const <String>['Segoe UI', 'Microsoft YaHei UI', 'sans-serif'])
        : null;
    final TextTheme textTheme = _buildTextTheme(
      scheme: scheme,
      brightness: scheme.brightness,
      fontFamily: appFontFamily,
      fallbackFonts: fallbackFonts,
      useChineseUiFont: useChineseUiFont,
    );
    final bool isDark = scheme.brightness == Brightness.dark;

    final BorderRadius buttonRadius = BorderRadius.circular(8);
    final BorderRadius fieldRadius = BorderRadius.circular(8);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: appFontFamily,
      fontFamilyFallback: fallbackFonts,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: isDark ? 0.22 : 0.14),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        selectedIconTheme: IconThemeData(color: scheme.primary, size: 22),
        unselectedIconTheme: IconThemeData(
          color: scheme.onSurfaceVariant,
          size: 22,
        ),
        selectedLabelTextStyle: textTheme.labelLarge?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
        unselectedLabelTextStyle: textTheme.labelLarge?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
          fontSize: 13,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.92)
            : scheme.surfaceContainerHighest,
        indicatorColor: scheme.primary.withValues(alpha: 0.16),
        elevation: 0,
        height: 68,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final bool selected = states.contains(WidgetState.selected);
          return textTheme.labelMedium!.copyWith(
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            fontSize: 12,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final bool selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
            size: 22,
          );
        }),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHighest,
        margin: EdgeInsets.zero,
        shadowColor: scheme.shadow.withValues(alpha: isDark ? 0.4 : 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: isDark ? 0.6 : 0.85),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? scheme.surfaceContainer.withValues(alpha: 0.8)
            : scheme.surfaceContainer,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.7),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        labelStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          side: WidgetStatePropertyAll<BorderSide>(
            BorderSide(color: scheme.outlineVariant),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return scheme.primary.withValues(alpha: isDark ? 0.24 : 0.12);
            }
            return Colors.transparent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return scheme.primary;
            }
            return scheme.onSurfaceVariant;
          }),
          textStyle: WidgetStatePropertyAll<TextStyle?>(textTheme.labelLarge),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: buttonRadius),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: scheme.outline.withValues(alpha: 0.55)),
          shape: RoundedRectangleBorder(borderRadius: buttonRadius),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          shape: RoundedRectangleBorder(borderRadius: buttonRadius),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainer,
        selectedColor: scheme.primary.withValues(alpha: 0.16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        labelStyle: textTheme.labelMedium?.copyWith(
          color: scheme.onSurface,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.outlineVariant,
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: 0.12),
        trackHeight: 4,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return scheme.onPrimary;
          }
          return scheme.onSurfaceVariant;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return scheme.primary;
          }
          return scheme.outlineVariant;
        }),
        trackOutlineColor: WidgetStatePropertyAll(
          scheme.outline.withValues(alpha: 0.3),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.outlineVariant.withValues(alpha: 0.55),
        linearMinHeight: 8,
      ),
      expansionTileTheme: ExpansionTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 4, bottom: 8),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.65),
        thickness: 1,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        iconColor: scheme.onSurfaceVariant,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark
              ? scheme.surfaceContainerHighest
              : scheme.inverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  static TextTheme _buildTextTheme({
    required ColorScheme scheme,
    required Brightness brightness,
    required String? fontFamily,
    required List<String>? fallbackFonts,
    required bool useChineseUiFont,
  }) {
    final TextTheme base = ThemeData(brightness: brightness).textTheme.apply(
      fontFamily: fontFamily,
      fontFamilyFallback: fallbackFonts,
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );

    final double bodyHeight = useChineseUiFont ? 1.55 : 1.45;
    final double compactHeight = useChineseUiFont ? 1.35 : 1.28;

    return base.copyWith(
      headlineSmall: base.headlineSmall?.copyWith(
        fontSize: useChineseUiFont ? 22 : 24,
        fontWeight: FontWeight.w700,
        height: useChineseUiFont ? 1.28 : 1.2,
        letterSpacing: -0.3,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontSize: useChineseUiFont ? 17 : 18,
        fontWeight: FontWeight.w700,
        height: compactHeight,
        letterSpacing: -0.2,
      ),
      titleMedium: base.titleMedium?.copyWith(
        fontSize: useChineseUiFont ? 15 : 16,
        fontWeight: FontWeight.w600,
        height: compactHeight,
        letterSpacing: -0.1,
      ),
      titleSmall: base.titleSmall?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: compactHeight,
      ),
      bodyLarge: base.bodyLarge?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: bodyHeight,
      ),
      bodyMedium: base.bodyMedium?.copyWith(
        fontSize: 13.5,
        fontWeight: FontWeight.w400,
        height: bodyHeight,
      ),
      bodySmall: base.bodySmall?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: useChineseUiFont ? 1.45 : 1.35,
      ),
      labelLarge: base.labelLarge?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        height: compactHeight,
      ),
      labelMedium: base.labelMedium?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        height: useChineseUiFont ? 1.25 : 1.15,
      ),
    );
  }
}
