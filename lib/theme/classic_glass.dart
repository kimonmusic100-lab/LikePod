import 'package:flutter/material.dart';

/// Glass fills for the Classic menu highlight, progress meter, and battery.
class ClassicGlass {
  static const LinearGradient fill = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFFB4E2F7),
      Color(0xFF7AC4F0),
      Color(0xFF3C9FE3),
      Color(0xFF1E7CC8),
    ],
    stops: [0.0, 0.34, 0.66, 1.0],
  );

  /// Body blue of [progressFill] (the 0.52 stop). 1-bit marks use this
  /// so they match the Now Playing meter without sampling the gradient.
  static const Color progressBlue = Color(0xFF2A9FCE);

  /// Electric blue glass for the progress bar and status play mark.
  static const LinearGradient progressFill = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFFD7F4FF),
      Color(0xFF5EBEF0),
      Color(0xFF2A9FCE),
      Color(0xFF1576AE),
    ],
    stops: [0.0, 0.18, 0.52, 1.0],
  );

  /// Battery glass: lime top, grass-green bottom.
  static const LinearGradient batteryFill = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFFF3FFE4),
      Color(0xFFC1F7A1),
      Color(0xFF6FBE58),
      Color(0xFF348245),
    ],
    stops: [0.0, 0.22, 0.55, 1.0],
  );

  static const Color selectedText = Color(0xFFFFFFFF);
}
