import 'package:flutter/material.dart';

class DropTheme {
  static const String logoAsset = 'assets/images/erebrus_drop_logo.png';

  static const Color black = Color(0xFF050505);
  static const Color surface = Color(0xFF111111);
  static const Color surfaceHigh = Color(0xFF1B1B1B);
  static const Color white = Color(0xFFFFFFFF);
  static const Color orange = Color(0xFFFF6A2A);
  static const Color orangeDeep = Color(0xFFC93E16);
  static const Color amber = Color(0xFFFFB14A);
  static const Color success = Color(0xFF3FD475);
  static const Color danger = Color(0xFFF05252);

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: orange,
      brightness: Brightness.dark,
      primary: orange,
      onPrimary: black,
      secondary: white,
      onSecondary: black,
      surface: surface,
      onSurface: white,
      error: danger,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: black,
      textTheme: Typography.whiteMountainView,
      cardTheme: const CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          side: BorderSide(color: Color(0xFF252525)),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: surfaceHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          foregroundColor: black,
          backgroundColor: orange,
          disabledBackgroundColor: const Color(0xFF2A2A2A),
          disabledForegroundColor: const Color(0xFF777777),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: black,
        indicatorColor: orange.withValues(alpha: 0.18),
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: orange),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: surfaceHigh,
        contentTextStyle: TextStyle(color: white),
      ),
    );
  }
}
