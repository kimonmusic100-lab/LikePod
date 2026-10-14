import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/pod_state.dart';
import 'click_wheel.dart';
import 'lcd_screen.dart';

class PodChassis extends StatelessWidget {
  const PodChassis({super.key});

  @override
  Widget build(BuildContext context) {
    final pod = context.watch<PodState>();
    final theme = pod.currentTheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalHeight = constraints.maxHeight;
        final totalWidth = constraints.maxWidth;

        // When running on ultra-wide desktop monitors, constrain width
        // On mobile phones (e.g. OPPO Find X9s Pro 19.5:9), fill 100% full screen edge-to-edge!
        final bool isDesktopWide = totalWidth > 540;
        final double effectiveWidth = isDesktopWide ? 460.0 : totalWidth;

        // Vertical space distribution tailored for modern 19.5:9 / 20:9 phone displays
        // LCD Screen takes ~42% of available height
        final double screenAreaHeight = (totalHeight * 0.42).clamp(240.0, 380.0);
        // Click Wheel diameter scales comfortably to the user's thumb zone
        final double wheelDiameter = min(effectiveWidth * 0.72, totalHeight * 0.44).clamp(210.0, 275.0);

        return Center(
          child: Container(
            width: effectiveWidth,
            height: totalHeight,
            decoration: BoxDecoration(
              // Authentic iPod Classic shell: polished white face with subtle bevel
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  theme.chassisPrimary,
                  theme.chassisPrimary.withValues(alpha: 0.98),
                  theme.chassisSecondary,
                ],
                stops: const [0.0, 0.4, 1.0],
              ),
              border: isDesktopWide
                  ? Border.all(color: theme.chassisBezel, width: 2.0)
                  : null,
              borderRadius: isDesktopWide ? BorderRadius.circular(36) : null,
              boxShadow: isDesktopWide
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 32,
                        offset: const Offset(0, 12),
                      ),
                    ]
                  : null,
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Column(
                  children: [
                    // 1. LCD Screen Display (Top half of phone)
                    SizedBox(
                      height: screenAreaHeight,
                      width: double.infinity,
                      child: LcdScreen(theme: theme),
                    ),

                    // 2. Click Wheel Section (Bottom half of phone, thumb-friendly)
                    Expanded(
                      child: Center(
                        child: SizedBox(
                          width: wheelDiameter,
                          height: wheelDiameter,
                          child: ClickWheel(
                            theme: theme,
                            onRotate: pod.onRotate,
                            onSelect: pod.onSelect,
                            onMenu: pod.onMenu,
                            onPlayPause: pod.onPlayPause,
                            onPrevious: pod.onPrevious,
                            onNext: pod.onNext,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
