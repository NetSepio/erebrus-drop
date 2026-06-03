import 'package:flutter/material.dart';

class DropTheme {
  static const Color navy = Color(0xFF07111F);
  static const Color slate = Color(0xFF111D2D);
  static const Color cyan = Color(0xFF25D7FF);
  static const Color blue = Color(0xFF4C7DFF);
  static const Color amber = Color(0xFFF5B94B);
  static const Color danger = Color(0xFFF05252);

  static ThemeData dark() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: cyan,
        brightness: Brightness.dark,
        primary: cyan,
        surface: slate,
        error: danger,
      ),
      scaffoldBackgroundColor: navy,
      cardTheme: const CardThemeData(
        color: slate,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF0B1727),
        indicatorColor: cyan.withValues(alpha: 0.16),
      ),
    );
  }
}
