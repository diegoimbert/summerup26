import 'package:flutter/material.dart';

/// Kandoo's palette.
abstract final class KandooColors {
  /// Background of the content area.
  static const Color background = Color(0xFFFCFBF9);

  /// Background of the left side menu, a touch warmer than the content.
  static const Color sidebar = Color(0xFFF6F4F2);

  static const Color accent = Color(0xFFF86523);

  /// Darker burnt orange for accent-coloured *text*, which is unreadable at the
  /// bright brand orange on a near-white background. Matches how getkandoo.app
  /// separates its brand fill from its accent text.
  static const Color accentDeep = Color(0xFFA14A18);

  static const Color textPrimary = Color(0xFF1F1D1B);
  static const Color textSecondary = Color(0xFF6B6560);
  static const Color textMuted = Color(0xFF918C82);

  /// Cards and inputs sitting on top of the page background.
  static const Color surface = Color(0xFFFFFFFF);

  static const Color divider = Color(0xFFE9E5E1);

  /// Borders that need to read on hover or against white cards.
  static const Color lineStrong = Color(0xFFD8D2CA);

  /// Fill behind the selected side menu item.
  static const Color selectedFill = Color(0x1AF86523);

  /// Fill behind a hovered, unselected side menu item.
  static const Color hoverFill = Color(0x0D1F1D1B);
}

/// Type families, matching how getkandoo.app splits its `--k-font-*` roles.
abstract final class KandooFonts {
  /// Headings and the wordmark.
  static const String heading = 'Instrument Sans';

  /// Body copy and UI labels; the app's default family.
  static const String body = 'Inter';

  /// Numerals, counts and metadata.
  static const String mono = 'JetBrains Mono';
}

ThemeData buildKandooTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: KandooColors.accent,
        brightness: Brightness.light,
      ).copyWith(
        primary: KandooColors.accent,
        surface: KandooColors.background,
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: KandooColors.background,
    dividerColor: KandooColors.divider,
    // Inter carries everything by default; headings opt into Instrument Sans.
    fontFamily: KandooFonts.body,
  );
}
