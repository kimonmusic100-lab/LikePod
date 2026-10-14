import 'package:flutter/material.dart';

enum ShellThemeType {
  spaceGray,
  classicWhite,
  stealthBlack,
  metallicSilver,
  u2Special,
  sepiaGold,
}

enum ScreenThemeType {
  colorLcd,
  sepiaRetro,
  monochromeGreen,
  darkOled,
}

class PodTheme {
  final ShellThemeType shellType;
  final ScreenThemeType screenType;

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
    required this.screenType,
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

  static PodTheme getTheme(ShellThemeType shell, ScreenThemeType screen) {
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

      case ShellThemeType.u2Special:
        themeName = 'U2 Special Edition';
        chassis1 = const Color(0xFF1A1A1C);
        chassis2 = const Color(0xFF0F0F10);
        bezel = const Color(0xFF333338);
        wheel = const Color(0xFFD02824); // Bold red click wheel
        wheelRim = const Color(0xFFA31A17);
        wheelTxt = const Color(0xFFFFFFFF);
        centerBtn = const Color(0xFF161618);
        break;

      case ShellThemeType.sepiaGold:
        themeName = 'Sepia Nostalgia';
        chassis1 = const Color(0xFFEADBCA);
        chassis2 = const Color(0xFFCDBBA5);
        bezel = const Color(0xFFB5A18B);
        wheel = const Color(0xFFDFD0BE);
        wheelRim = const Color(0xFFC5B49F);
        wheelTxt = const Color(0xFF755B44);
        centerBtn = const Color(0xFFEAE0D3);
        break;
    }

    // Screen properties
    Color bg;
    Color hStart;
    Color hEnd;
    Color hTxt;
    Color hBorder;
    Color txt;
    Color subTxt;
    Color hlStart;
    Color hlEnd;
    Color hlTxt;
    Color div;
    Color batFill;
    Color batBorder;

    switch (screen) {
      case ScreenThemeType.colorLcd:
        bg = const Color(0xFFFFFFFF);
        hStart = const Color(0xFFEDEDF0);
        hEnd = const Color(0xFFCBCBD0);
        hTxt = const Color(0xFF111111);
        hBorder = const Color(0xFF9898A0);
        txt = const Color(0xFF1A1A1A);
        subTxt = const Color(0xFF7A7A7A);
        hlStart = const Color(0xFF3C7FE8); // Classic blue gradient highlight
        hlEnd = const Color(0xFF1B55B8);
        hlTxt = const Color(0xFFFFFFFF);
        div = const Color(0xFFE2E2E6);
        batFill = const Color(0xFF4CD964);
        batBorder = const Color(0xFF666666);
        break;

      case ScreenThemeType.sepiaRetro:
        bg = const Color(0xFFF5EFE4);
        hStart = const Color(0xFFE8DDCA);
        hEnd = const Color(0xFFD8C7AD);
        hTxt = const Color(0xFF4A3828);
        hBorder = const Color(0xFFB8A48A);
        txt = const Color(0xFF463524);
        subTxt = const Color(0xFF8B7762);
        hlStart = const Color(0xFFB37B42);
        hlEnd = const Color(0xFF865422);
        hlTxt = const Color(0xFFFFF7ED);
        div = const Color(0xFFDFD1BE);
        batFill = const Color(0xFF8F9456);
        batBorder = const Color(0xFF6B5843);
        break;

      case ScreenThemeType.monochromeGreen:
        bg = const Color(0xFFBDC7A7); // Backlit green LCD
        hStart = const Color(0xFFAFB99A);
        hEnd = const Color(0xFF9BA785);
        hTxt = const Color(0xFF28341E);
        hBorder = const Color(0xFF7E8A69);
        txt = const Color(0xFF25301B);
        subTxt = const Color(0xFF566548);
        hlStart = const Color(0xFF38472B);
        hlEnd = const Color(0xFF25321B);
        hlTxt = const Color(0xFFD4E0BE);
        div = const Color(0xFFA3AF8C);
        batFill = const Color(0xFF38472B);
        batBorder = const Color(0xFF38472B);
        break;

      case ScreenThemeType.darkOled:
        bg = const Color(0xFF121214);
        hStart = const Color(0xFF242428);
        hEnd = const Color(0xFF18181A);
        hTxt = const Color(0xFFE2E2E8);
        hBorder = const Color(0xFF333338);
        txt = const Color(0xFFE8E8EE);
        subTxt = const Color(0xFF868690);
        hlStart = const Color(0xFF2D62B5);
        hlEnd = const Color(0xFF193F7D);
        hlTxt = const Color(0xFFFFFFFF);
        div = const Color(0xFF25252A);
        batFill = const Color(0xFF34C759);
        batBorder = const Color(0xFF888890);
        break;
    }

    return PodTheme(
      shellType: shell,
      screenType: screen,
      name: themeName,
      chassisPrimary: chassis1,
      chassisSecondary: chassis2,
      chassisBezel: bezel,
      wheelBody: wheel,
      wheelRim: wheelRim,
      wheelText: wheelTxt,
      centerButton: centerBtn,
      lcdBackground: bg,
      lcdHeaderStart: hStart,
      lcdHeaderEnd: hEnd,
      lcdHeaderText: hTxt,
      lcdHeaderBorder: hBorder,
      lcdText: txt,
      lcdSubtext: subTxt,
      lcdHighlightStart: hlStart,
      lcdHighlightEnd: hlEnd,
      lcdHighlightText: hlTxt,
      lcdDivider: div,
      lcdBatteryFill: batFill,
      lcdBatteryBorder: batBorder,
    );
  }
}
