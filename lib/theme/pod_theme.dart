import 'package:flutter/material.dart';

enum ShellThemeType {
  spaceGray,
  classicWhite,
  stealthBlack,
  metallicSilver,
}

class PodTheme {
  final ShellThemeType shellType;

  final String name;
  final Color chassisPrimary;
  final Color chassisSecondary;
  final Color chassisBezel;
  final Color wheelBody;
  final Color wheelRim;
  final Color wheelText;
  final Color centerButton;

  // LCD screen colors
  final Color lcdBackground;
  final Color lcdHeaderStart;
  final Color lcdHeaderEnd;
  final Color lcdHeaderText;
  final Color lcdHeaderBorder;
  final Color lcdText;
  final Color lcdSubtext;
  final Color lcdHighlightStart;
  final Color lcdHighlightEnd;
  final Color lcdHighlightText;
  final Color lcdDivider;
  final Color lcdBatteryFill;
  final Color lcdBatteryBorder;

  const PodTheme({
    required this.shellType,
    required this.name,
    required this.chassisPrimary,
    required this.chassisSecondary,
    required this.chassisBezel,
    required this.wheelBody,
    required this.wheelRim,
    required this.wheelText,
    required this.centerButton,
    required this.lcdBackground,
    required this.lcdHeaderStart,
    required this.lcdHeaderEnd,
    required this.lcdHeaderText,
    required this.lcdHeaderBorder,
    required this.lcdText,
    required this.lcdSubtext,
    required this.lcdHighlightStart,
    required this.lcdHighlightEnd,
    required this.lcdHighlightText,
    required this.lcdDivider,
    required this.lcdBatteryFill,
    required this.lcdBatteryBorder,
  });

  /// The screen palette stays the same; only the shell varies.
  static PodTheme getTheme(ShellThemeType shell) {
    // Shell properties
    Color chassis1;
    Color chassis2;
    Color bezel;
    Color wheel;
    Color wheelRim;
    Color wheelTxt;
    Color centerBtn;
    String themeName = '';

    switch (shell) {
      case ShellThemeType.spaceGray:
        themeName = 'Space Gray';
        chassis1 = const Color(0xFF33353B); // 深灰色机身 (Dark Grey)
        chassis2 = const Color(0xFF222327);
        bezel = const Color(0xFF484A52);
        wheel = const Color(0xFF000000);    // 纯黑色圆环 (Pure Black)
        wheelRim = const Color(0xFF141416);
        wheelTxt = const Color(0xFFFFFFFF); // 纯白高对比度文字
        centerBtn = const Color(0xFF2E3035); // 深灰色圆点 (Dark Grey matching chassis)
        break;

      case ShellThemeType.classicWhite:
        themeName = 'Classic White';
        chassis1 = const Color(0xFFFFFFFF);
        chassis2 = const Color(0xFFEDEDF2);
        bezel = const Color(0xFFB8BAC2);
        wheel = const Color(0xFFF0F1F5);
        wheelRim = const Color(0xFFDFE0E6);
        wheelTxt = const Color(0xFF868892);
        centerBtn = const Color(0xFFFFFFFF);
        break;

      case ShellThemeType.stealthBlack:
        themeName = 'Stealth Black';
        chassis1 = const Color(0xFF2A2A2E);
        chassis2 = const Color(0xFF1B1B1D);
        bezel = const Color(0xFF38383E);
        wheel = const Color(0xFF232326);
        wheelRim = const Color(0xFF18181A);
        wheelTxt = const Color(0xFF9E9EA4);
        centerBtn = const Color(0xFF2C2C30);
        break;

      case ShellThemeType.metallicSilver:
        themeName = 'Metallic Silver';
        chassis1 = const Color(0xFFE3E4E8);
        chassis2 = const Color(0xFFB8BAC2);
        bezel = const Color(0xFFA5A7B0);
        wheel = const Color(0xFFD6D7DC);
        wheelRim = const Color(0xFFC0C2C8);
        wheelTxt = const Color(0xFF5A5C64);
        centerBtn = const Color(0xFFE8E9ED);
        break;
    }

    return PodTheme(
      shellType: shell,
      name: themeName,
      chassisPrimary: chassis1,
      chassisSecondary: chassis2,
      chassisBezel: bezel,
      wheelBody: wheel,
      wheelRim: wheelRim,
      wheelText: wheelTxt,
      centerButton: centerBtn,
      lcdBackground: const Color(0xFFFFFFFF),
      lcdHeaderStart: const Color(0xFFEDEDF0),
      lcdHeaderEnd: const Color(0xFFCBCBD0),
      lcdHeaderText: const Color(0xFF111111),
      lcdHeaderBorder: const Color(0xFF9898A0),
      // List body is 90% black. Subtitles stay the existing gray.
      lcdText: const Color(0xFF1A1A1A),
      lcdSubtext: const Color(0xFF7A7A7A),
      lcdHighlightStart: const Color(0xFF1A86D0),
      lcdHighlightEnd: const Color(0xFF1874C2),
      lcdHighlightText: const Color(0xFFFFFFFF),
      lcdDivider: const Color(0xFFE2E2E6),
      lcdBatteryFill: const Color(0xFF4CD964),
      lcdBatteryBorder: const Color(0xFF666666),
    );
  }
}
