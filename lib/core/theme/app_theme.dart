import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'leica_colors.dart';

abstract final class AppTheme {
  static ThemeData get dark => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: LeicaColors.black,
        colorScheme: const ColorScheme.dark(
          primary: LeicaColors.red,
          secondary: LeicaColors.offWhite,
          surface: LeicaColors.surface,
          onPrimary: LeicaColors.offWhite,
          onSurface: LeicaColors.textPrimary,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          systemOverlayStyle: SystemUiOverlayStyle.light,
          titleTextStyle: TextStyle(
            color: LeicaColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w500,
            letterSpacing: 2,
          ),
        ),
        iconTheme: const IconThemeData(color: LeicaColors.textPrimary),
        textTheme: const TextTheme(
          displayLarge: TextStyle(
            color: LeicaColors.textPrimary,
            fontSize: 32,
            fontWeight: FontWeight.w300,
            letterSpacing: 4,
          ),
          bodyLarge: TextStyle(
            color: LeicaColors.textPrimary,
            fontSize: 14,
            letterSpacing: 0.5,
          ),
          bodyMedium: TextStyle(
            color: LeicaColors.textSecondary,
            fontSize: 12,
            letterSpacing: 0.5,
          ),
          labelSmall: TextStyle(
            color: LeicaColors.textSecondary,
            fontSize: 10,
            letterSpacing: 1.5,
          ),
        ),
        useMaterial3: true,
      );
}
