import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/pod_state.dart';
import 'click_wheel.dart';
import 'lcd_screen.dart';

/// Outer shell radius.
///
/// [systemCorners] is [MediaQueryData.displayCornerRadii]: Flutter converts
/// `WindowInsets.getRoundedCorner` (API 31+, each corner in physical pixels)
/// into a logical [BorderRadius]. Null (older Android, desktop, tests) or an
/// all-zero radius means the platform did not report a corner. Phones stay
/// square. Wide layouts keep the fixed 36 radius.
BorderRadius? chassisOuterRadius({
  required bool isDesktopWide,
  BorderRadius? systemCorners,
}) {
  if (_hasPositiveCorner(systemCorners)) return systemCorners;
  if (isDesktopWide) return BorderRadius.circular(36);
  return null;
}

bool _hasPositiveCorner(BorderRadius? radii) {
  if (radii == null) return false;
  bool live(Radius radius) => radius.x > 0 || radius.y > 0;
  return live(radii.topLeft) ||
      live(radii.topRight) ||
      live(radii.bottomRight) ||
      live(radii.bottomLeft);
}

/// Play window uses a 3:4 frame, then keeps that width and uses 5/6 of the height.
class _LcdSize {
  final double width;
  final double height;
  const _LcdSize(this.width, this.height);
}

_LcdSize _lcdWindow(double maxWidth, double maxHeight) {
  if (maxWidth <= 0 || maxHeight <= 0) return const _LcdSize(0, 0);
  // Fit a 3:4 window in the space above the click wheel.
  final available = max(1.0, min(maxHeight * 0.70, maxHeight - 80));
  var width = maxWidth;
  var height = width * 4 / 3;
  if (height > available) {
    height = available;
    width = height * 3 / 4;
    if (width > maxWidth) {
      width = maxWidth;
      height = min(width * 4 / 3, available);
    }
  }
  // Shorten that height by one sixth; the width stays.
  return _LcdSize(width, height * 5 / 6);
}

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
        final BorderRadius? outerRadius = chassisOuterRadius(
          isDesktopWide: isDesktopWide,
          systemCorners: MediaQuery.maybeDisplayCornerRadiiOf(context),
        );

        return Center(
          child: Container(
            key: const Key('pod_chassis_shell'),
            width: effectiveWidth,
            height: totalHeight,
            clipBehavior: outerRadius == null ? Clip.none : Clip.antiAlias,
            decoration: BoxDecoration(
              // Shell face: theme color with a subtle bevel
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
              borderRadius: outerRadius,
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
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                child: LayoutBuilder(
                  builder: (context, inner) {
                    final lcd = _lcdWindow(inner.maxWidth, inner.maxHeight);
                    final wheelRoom = max(
                      0.0,
                      inner.maxHeight - lcd.height - 8,
                    );
                    var wheelDiameter = min(
                      inner.maxWidth * 0.70,
                      min(wheelRoom * 0.86, 280.0),
                    );
                    if (wheelRoom >= 200 && wheelDiameter < 200) {
                      wheelDiameter = min(200.0, wheelRoom);
                    }
                    if (wheelDiameter > wheelRoom) wheelDiameter = wheelRoom;
                    return Column(
                      children: [
                        SizedBox(
                          height: lcd.height,
                          width: double.infinity,
                          child: Center(
                            child: SizedBox(
                              width: lcd.width,
                              height: lcd.height,
                              child: LcdScreen(theme: theme),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Align(
                            alignment: const Alignment(0, 0.22),
                            child: SizedBox(
                              width: wheelDiameter,
                              height: wheelDiameter,
                              child: ClickWheel(
                                theme: theme,
                                onRotate: pod.onRotate,
                                onSelect: pod.onSelect,
                                onCenterLongPress: pod.onCenterLongPress,
                                onMenu: pod.onMenu,
                                onPlayPause: pod.onPlayPause,
                                onPrevious: pod.onPrevious,
                                onNext: pod.onNext,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
