import 'package:flutter/material.dart';

import '../../features/translation/domain/models/translation_config.dart';
import '../../shared/platform/platform_utils.dart';

class AppTheme {
  static ThemeData light(UiLanguage language) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1D4ED8),
      brightness: Brightness.light,
    );
    return _baseTheme(scheme, language);
  }

  static ThemeData dark(UiLanguage language) {
    const ColorScheme scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: Color(0xFF60A5FA),
      onPrimary: Color(0xFF0F172A),
      secondary: Color(0xFF34D399),
      onSecondary: Color(0xFF06281F),
      error: Color(0xFFF87171),
      onError: Color(0xFF2F1214),
      surface: Color(0xFF0F172A),
      onSurface: Color(0xFFE2E8F0),
      primaryContainer: Color(0xFF1E3A8A),
      onPrimaryContainer: Color(0xFFDBEAFE),
      secondaryContainer: Color(0xFF064E3B),
      onSecondaryContainer: Color(0xFFD1FAE5),
      tertiary: Color(0xFFF59E0B),
      onTertiary: Color(0xFF3B2500),
      tertiaryContainer: Color(0xFF78350F),
      onTertiaryContainer: Color(0xFFFEF3C7),
      surfaceContainerHighest: Color(0xFF1E293B),
      onSurfaceVariant: Color(0xFF94A3B8),
      outline: Color(0xFF334155),
      outlineVariant: Color(0xFF1E293B),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: Color(0xFFF8FAFC),
      onInverseSurface: Color(0xFF0F172A),
      inversePrimary: Color(0xFF1D4ED8),
      surfaceTint: Color(0xFF60A5FA),
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

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: appFontFamily,
      fontFamilyFallback: fallbackFonts,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      scaffoldBackgroundColor: scheme.surface,
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: scheme.primary),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHighest,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.primary),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
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
    final double compactHeight = useChineseUiFont ? 1.35 : 1.25;
    final FontWeight bodyWeight = useChineseUiFont
        ? FontWeight.w400
        : FontWeight.w400;
    final FontWeight titleWeight = useChineseUiFont
        ? FontWeight.w600
        : FontWeight.w600;
    final FontWeight headlineWeight = useChineseUiFont
        ? FontWeight.w700
        : FontWeight.w700;

    return base.copyWith(
      headlineSmall: base.headlineSmall?.copyWith(
        fontSize: useChineseUiFont ? 19 : 20,
        fontWeight: headlineWeight,
        height: useChineseUiFont ? 1.3 : 1.2,
        letterSpacing: 0,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontSize: useChineseUiFont ? 17 : 18,
        fontWeight: headlineWeight,
        height: compactHeight,
        letterSpacing: 0,
      ),
      titleMedium: base.titleMedium?.copyWith(
        fontSize: useChineseUiFont ? 15 : 16,
        fontWeight: titleWeight,
        height: compactHeight,
        letterSpacing: 0,
      ),
      titleSmall: base.titleSmall?.copyWith(
        fontSize: useChineseUiFont ? 14 : 14,
        fontWeight: titleWeight,
        height: compactHeight,
        letterSpacing: 0,
      ),
      bodyLarge: base.bodyLarge?.copyWith(
        fontSize: useChineseUiFont ? 14.5 : 14.5,
        fontWeight: bodyWeight,
        height: bodyHeight,
        letterSpacing: 0,
      ),
      bodyMedium: base.bodyMedium?.copyWith(
        fontSize: useChineseUiFont ? 13.5 : 13.5,
        fontWeight: bodyWeight,
        height: bodyHeight,
        letterSpacing: 0,
      ),
      bodySmall: base.bodySmall?.copyWith(
        fontSize: useChineseUiFont ? 12 : 12,
        fontWeight: FontWeight.w400,
        height: useChineseUiFont ? 1.45 : 1.35,
        letterSpacing: 0,
      ),
      labelLarge: base.labelLarge?.copyWith(
        fontSize: useChineseUiFont ? 13 : 13,
        fontWeight: FontWeight.w600,
        height: compactHeight,
        letterSpacing: 0,
      ),
      labelMedium: base.labelMedium?.copyWith(
        fontSize: useChineseUiFont ? 12 : 12,
        fontWeight: FontWeight.w500,
        height: useChineseUiFont ? 1.25 : 1.15,
        letterSpacing: 0,
      ),
    );
  }
}
