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
///
/// Weight is a thing to spend, not a default. Light carries body copy, labels
/// and list rows; regular and medium mark the one item in a group that is
/// selected or otherwise standing out; semibold is for titles that head a page
/// or a dialog, and for the wordmark. A screen where several things are heavy
/// is a screen where nothing is.
///
/// Nothing has to opt into light: [buildKandooTheme] shifts the whole text
/// theme down a step, so a `TextStyle` that says nothing about weight comes out
/// light, and only a style that asks for weight gets it.
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

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: KandooColors.background,
    dividerColor: KandooColors.divider,
    // Inter carries everything by default; headings opt into Instrument Sans.
    fontFamily: KandooFonts.body,
  );

  // Material's text theme is built around regular. Shifting it down a step
  // makes light the weight everything inherits, so only text that explicitly
  // asks for weight carries any.
  return base.copyWith(
    textTheme: _aStepLighter(base.textTheme),
    primaryTextTheme: _aStepLighter(base.primaryTextTheme),
  );
}

/// Every style in [theme], one weight lighter.
TextTheme _aStepLighter(TextTheme theme) {
  TextStyle? lighter(TextStyle? style) {
    if (style == null) return null;
    // A style that never said what weight it wanted was going to be drawn
    // regular, so a step down from there is what it gets.
    final weight = style.fontWeight ?? FontWeight.w400;
    return style.copyWith(
      fontWeight:
          FontWeight.values[(FontWeight.values.indexOf(weight) - 1).clamp(
            0,
            FontWeight.values.length - 1,
          )],
    );
  }

  return TextTheme(
    displayLarge: lighter(theme.displayLarge),
    displayMedium: lighter(theme.displayMedium),
    displaySmall: lighter(theme.displaySmall),
    headlineLarge: lighter(theme.headlineLarge),
    headlineMedium: lighter(theme.headlineMedium),
    headlineSmall: lighter(theme.headlineSmall),
    titleLarge: lighter(theme.titleLarge),
    titleMedium: lighter(theme.titleMedium),
    titleSmall: lighter(theme.titleSmall),
    bodyLarge: lighter(theme.bodyLarge),
    bodyMedium: lighter(theme.bodyMedium),
    bodySmall: lighter(theme.bodySmall),
    labelLarge: lighter(theme.labelLarge),
    labelMedium: lighter(theme.labelMedium),
    labelSmall: lighter(theme.labelSmall),
  );
}
