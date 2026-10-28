// Project design system (app style.txt) as Flutter tokens.
import 'package:flutter/material.dart';

class C {
  static const bg = Color(0xFF071C13);
  static const card = Color(0xFF0D2D20);
  static const raised = Color(0xFF123828);
  static const white = Color(0xFFFFFFFF);
  static const gray = Color(0xFF9EAEB8);
  static const green = Color(0xFF00FF66);
  static const mint = Color(0xFF8EFFC1);
  static const red = Color(0xFFFF3B30);
  static const border = Color(0x14FFFFFF); // rgba(255,255,255,0.08)
}

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: C.bg,
    colorScheme: base.colorScheme.copyWith(primary: C.green, onPrimary: Colors.black, surface: C.card, error: C.red, secondary: C.mint),
    textTheme: base.textTheme.apply(bodyColor: C.gray, displayColor: C.white, fontFamily: 'Inter'),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: C.bg,
      hintStyle: const TextStyle(color: Color(0x809EAEB8)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: C.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: C.green)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: C.green,
        foregroundColor: Colors.black,
        minimumSize: const Size(0, 48),
        textStyle: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600, fontSize: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: C.white,
        minimumSize: const Size(0, 48),
        side: const BorderSide(color: C.border),
        textStyle: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600, fontSize: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(backgroundColor: C.raised, contentTextStyle: TextStyle(color: C.white)),
  );
}
