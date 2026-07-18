import 'package:flutter/material.dart';

/// Single source of truth for the Erebrus Drop visual language.
///
/// Dark + signal-orange identity, local-first. Accent is the only colour the
/// user should ever see "themed" — keep it as a single constant so a future
/// theme switch stays trivial.
class DropTheme {
  DropTheme._();

  // --- Brand marks ---------------------------------------------------------
  /// Flat orange squircle, white glyph. Inline/system mark for < 28px or busy
  /// rows (status chips, dense headers).
  static const String logoFlat = 'assets/images/erebrus-drop-logo.png';

  /// Monochrome glyph for light surfaces / favicons only. Never on dark.
  static const String logoGlyph = 'assets/images/erebrus-glyph.png';

  /// Transparent-background marks for desktop system tray icons.
  static const String trayIcon = 'assets/images/erebrus-tray-64.png';
  static const String trayIconTemplate =
      'assets/images/erebrus-tray-template-64.png';

  /// Back-compat alias; defaults to the primary (glossy) mark.
  static const String logoAsset = logoFlat;

  // --- Type families -------------------------------------------------------
  static const String displayFont = 'Bricolage Grotesque';
  static const String bodyFont = 'Manrope';
  static const String monoFont = 'JetBrains Mono';

  // --- Colour tokens -------------------------------------------------------
  static const Color black = Color(0xFF050505); // App background
  static const Color surface = Color(0xFF111113); // Cards, sheets
  static const Color surfaceHigh = Color(0xFF1B1B1E); // Inputs, inner tiles
  static const Color line = Color(0x16FFFFFF); // Hairline borders (~0.085)
  static const Color lineStrong = Color(
    0xFF2A2A2E,
  ); // Dividers, inactive meters
  static const Color white = Color(0xFFFFFFFF); // Primary text
  static const Color muted = Color(0x94FFFFFF); // Secondary text (~0.58)
  static const Color faint = Color(
    0x66FFFFFF,
  ); // Tertiary text / disabled (~0.40)
  static const Color orange = Color(0xFFFF6A2A); // Accent, CTAs
  static const Color orangeDeep = Color(0xFFC93E16); // Gradient end
  static const Color amber = Color(0xFFFFB14A); // Warnings, password state
  static const Color success = Color(0xFF3FD475); // Live / ready / connected
  static const Color danger = Color(0xFFF05252); // Destructive, errors

  /// Near-black foreground for text/icons on the orange accent (warmer than
  /// pure black).
  static const Color onAccent = Color(0xFF1A0A04);

  /// Accent gradient for primary buttons and the logo tile
  /// (CSS `linear-gradient(160deg, #FF6A2A -> #C93E16)`).
  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment(-0.6, -1),
    end: Alignment(0.6, 1),
    colors: [orange, orangeDeep],
  );

  /// Tinted "feature" surface: `color-mix(accent 14-16%, surface)`.
  static Color tinted(Color accent, {double amount = 0.15}) =>
      Color.lerp(surface, accent, amount)!;

  /// Border for tinted surfaces: `color-mix(accent 30-34%)`.
  static Color tintBorder(Color accent, {double alpha = 0.32}) =>
      accent.withValues(alpha: alpha);

  /// Glow used for the single hero card / CTA per screen.
  static List<BoxShadow> heroGlow(Color accent) => [
    BoxShadow(
      color: accent.withValues(alpha: 0.36),
      blurRadius: 50,
      spreadRadius: -24,
      offset: const Offset(0, 18),
    ),
  ];

  static const double radiusCard = 18;
  static const double radiusTile = 12;
  static const double radiusInput = 14;
  static const double radiusButton = 14;
  static const double radiusIconButton = 13;

  static const TextTheme _textTheme = TextTheme(
    // Marketing caption (38-42 / 700, -0.03em, line 1.04)
    displayLarge: TextStyle(
      fontFamily: displayFont,
      fontSize: 40,
      height: 1.04,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.2,
      color: white,
    ),
    displayMedium: TextStyle(
      fontFamily: displayFont,
      fontSize: 34,
      height: 1.05,
      fontWeight: FontWeight.w700,
      letterSpacing: -1,
      color: white,
    ),
    displaySmall: TextStyle(
      fontFamily: displayFont,
      fontSize: 29,
      height: 1.06,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.7,
      color: white,
    ),
    // Screen title "Head" (25 / 700, -0.02em)
    headlineMedium: TextStyle(
      fontFamily: displayFont,
      fontSize: 25,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
      color: white,
    ),
    headlineSmall: TextStyle(
      fontFamily: displayFont,
      fontSize: 25,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
      color: white,
    ),
    // Room names / big numbers (display)
    titleLarge: TextStyle(
      fontFamily: displayFont,
      fontSize: 20,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
      color: white,
    ),
    // Card title (16-16.5 / 800)
    titleMedium: TextStyle(
      fontFamily: bodyFont,
      fontSize: 16,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.1,
      color: white,
    ),
    // List item title (14-14.5 / 800)
    titleSmall: TextStyle(
      fontFamily: bodyFont,
      fontSize: 14.5,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.1,
      color: white,
    ),
    bodyLarge: TextStyle(
      fontFamily: bodyFont,
      fontSize: 14.5,
      height: 1.4,
      fontWeight: FontWeight.w600,
      color: white,
    ),
    // Body / supporting (12.5-14 / 500-600, muted)
    bodyMedium: TextStyle(
      fontFamily: bodyFont,
      fontSize: 13.5,
      height: 1.4,
      fontWeight: FontWeight.w500,
      color: muted,
    ),
    bodySmall: TextStyle(
      fontFamily: bodyFont,
      fontSize: 12.5,
      height: 1.35,
      fontWeight: FontWeight.w500,
      color: muted,
    ),
    // Button text
    labelLarge: TextStyle(
      fontFamily: bodyFont,
      fontSize: 14,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.1,
      color: white,
    ),
    // Pill / chip (12-12.5 / 700)
    labelMedium: TextStyle(
      fontFamily: bodyFont,
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: muted,
    ),
    // Label / eyebrow (11-12.5 / 700-800, uppercase handled per-widget)
    labelSmall: TextStyle(
      fontFamily: bodyFont,
      fontSize: 11,
      fontWeight: FontWeight.w800,
      letterSpacing: 1.1,
      color: faint,
    ),
  );

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: orange,
      brightness: Brightness.dark,
      primary: orange,
      onPrimary: onAccent,
      secondary: orange,
      onSecondary: onAccent,
      surface: surface,
      onSurface: white,
      surfaceContainerHighest: surfaceHigh,
      outline: lineStrong,
      outlineVariant: line,
      error: danger,
      onError: white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: black,
      fontFamily: bodyFont,
      textTheme: _textTheme,
      splashFactory: InkSparkle.splashFactory,
      dividerTheme: const DividerThemeData(color: line, thickness: 1, space: 1),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusCard),
          side: const BorderSide(color: line),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceHigh,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        hintStyle: const TextStyle(color: faint, fontWeight: FontWeight.w500),
        labelStyle: const TextStyle(color: muted, fontWeight: FontWeight.w600),
        helperStyle: const TextStyle(color: faint, fontSize: 11.5),
        floatingLabelStyle: const TextStyle(
          color: orange,
          fontWeight: FontWeight.w700,
        ),
        prefixIconColor: faint,
        suffixIconColor: faint,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusInput),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusInput),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusInput),
          borderSide: const BorderSide(color: orange, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusInput),
          borderSide: const BorderSide(color: danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusInput),
          borderSide: const BorderSide(color: danger, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          foregroundColor: onAccent,
          backgroundColor: orange,
          disabledBackgroundColor: surfaceHigh,
          disabledForegroundColor: faint,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          textStyle: const TextStyle(
            fontFamily: bodyFont,
            fontWeight: FontWeight.w800,
            fontSize: 14,
            letterSpacing: 0.1,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusButton),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: orange,
          textStyle: const TextStyle(
            fontFamily: bodyFont,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: muted,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusIconButton),
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return onAccent;
          return faint;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return orange;
          return surfaceHigh;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.transparent;
          return line;
        }),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 64,
        indicatorColor: orange.withValues(alpha: 0.20),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(size: 24, color: selected ? orange : faint);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontFamily: bodyFont,
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            color: selected ? white : faint,
          );
        }),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: orange,
        linearTrackColor: lineStrong,
        circularTrackColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusCard),
          side: const BorderSide(color: line),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radiusCard)),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: black,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: displayFont,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
          color: white,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surfaceHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusInput),
          side: const BorderSide(color: line),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: surfaceHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: line),
        ),
        textStyle: const TextStyle(color: white, fontSize: 12),
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: orange,
        selectionColor: Color(0x40FF6A2A),
        selectionHandleColor: orange,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceHigh,
        contentTextStyle: const TextStyle(
          color: white,
          fontFamily: bodyFont,
          fontWeight: FontWeight.w600,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusInput),
          side: const BorderSide(color: line),
        ),
      ),
    );
  }
}
