import 'package:flutter/material.dart';

abstract final class LeicaColors {
  // Brand
  static const red = Color(0xFFE2001A);
  static const black = Color(0xFF0A0A0A);
  static const offWhite = Color(0xFFF5F0EB);
  static const warmGray = Color(0xFF2A2825);
  static const midGray = Color(0xFF3D3A36);
  static const lightGray = Color(0xFF6B6560);

  // Surfaces
  static const surface = Color(0xFF111110);
  static const surfaceElevated = Color(0xFF1C1B19);
  static const overlay = Color(0xCC000000);

  // Text
  static const textPrimary = Color(0xFFF0EDE8);
  static const textSecondary = Color(0xFFAEA89F);
  static const textDisabled = Color(0xFF5A5650);

  // Controls
  static const controlActive = red;
  static const controlInactive = lightGray;
  static const dialTrack = midGray;

  // Looks selector accent per look
  static const lookClassic = Color(0xFFD4C5A9);
  static const lookContemporary = Color(0xFFA8C5C0);
  static const lookBW = Color(0xFFCCCCCC);
  static const lookVivid = Color(0xFFE8A87C);
  static const lookArtist = Color(0xFFB5A4D4);
}
