import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static const Color _accent = Color(0xFF6E8CFF);
  static const Color _accentSecondary = Color(0xFF56C7D8);
  static const Color _bgDark = Color(0xFF070D1C);
  static const Color _bgLight = Color(0xFFF2F6FF);
  static const Color _surfaceDark = Color(0xFF141C31);
  static const Color _surfaceLight = Color(0xFFE8EEF9);
  static const Color _cardDark = Color(0xFF1A253F);
  static const Color _cardLight = Color(0xFFFAFCFF);

  static ThemeData light() {
    const cs = ColorScheme.light(
      primary: _accent,
      secondary: _accentSecondary,
      surface: _surfaceLight,
      onSurface: Color(0xFF10172A),
      outline: Color(0xFFBBC7DF),
      outlineVariant: Color(0xFFD5DDF0),
      error: Color(0xFFE54D5C),
      shadow: Color(0xFF041022),
    );
    return _base(cs, isDark: false);
  }

  static ThemeData dark() {
    const cs = ColorScheme.dark(
      primary: _accent,
      secondary: _accentSecondary,
      surface: _surfaceDark,
      onSurface: Color(0xFFF2F6FF),
      outline: Color(0xFF3B4C74),
      outlineVariant: Color(0xFF28385E),
      error: Color(0xFFFF6D7B),
      shadow: Colors.black,
    );
    return _base(cs, isDark: true);
  }

  static ThemeData _base(ColorScheme cs, {required bool isDark}) {
    final panel = isDark ? _cardDark : _cardLight;
    final panelSoft = isDark ? _surfaceDark : _surfaceLight;
    final scaffold = isDark ? _bgDark : _bgLight;

    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      brightness: isDark ? Brightness.dark : Brightness.light,
      scaffoldBackgroundColor: scaffold,
      canvasColor: panelSoft,
      dividerColor: cs.outlineVariant.withValues(alpha: 0.85),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: cs.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 48,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: cs.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
        iconTheme: IconThemeData(color: cs.onSurface.withValues(alpha: 0.9)),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: panelSoft,
        shape: const RoundedRectangleBorder(),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.65)),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: panel,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      chipTheme: ChipThemeData(
        selectedColor: cs.primary.withValues(alpha: 0.24),
        backgroundColor: panelSoft,
        labelStyle: TextStyle(fontSize: 13, color: cs.onSurface),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.9)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panelSoft.withValues(alpha: isDark ? 0.88 : 0.92),
        hintStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.52)),
        labelStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.78)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.outline.withValues(alpha: 0.88)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.92),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.error, width: 1.6),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(46),
          backgroundColor: cs.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: cs.primary,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          foregroundColor: cs.onSurface,
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.9)),
          backgroundColor: panelSoft.withValues(alpha: isDark ? 0.4 : 0.72),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.65)),
        ),
        color: panel,
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 0),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: cs.primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 0,
      ),
    );
  }
}
