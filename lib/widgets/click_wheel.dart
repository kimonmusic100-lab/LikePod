import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/pod_theme.dart';

class ClickWheel extends StatefulWidget {
  final PodTheme theme;
  final ValueChanged<int> onRotate;
  final VoidCallback onSelect;
  final VoidCallback? onCenterLongPress;
  final VoidCallback onMenu;
  final VoidCallback onPlayPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  const ClickWheel({
    super.key,
    required this.theme,
    required this.onRotate,
    required this.onSelect,
    this.onCenterLongPress,
    required this.onMenu,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
  });

  @override
  State<ClickWheel> createState() => _ClickWheelState();
}

class _ClickWheelState extends State<ClickWheel>
    with SingleTickerProviderStateMixin {
  double? _lastAngle;
  double _accumulatedAngle = 0.0;
  static const double _stepThreshold =
      0.52; // ~30 degrees per tick; less twitchy

  /// Classic center button, a little larger than the previous 28% dot.
  static const double _centerFraction = 0.32;

  bool _isMenuPressed = false;
  bool _isPlayPressed = false;
  bool _isPrevPressed = false;
  bool _isNextPressed = false;

  late final AnimationController _centerPress;

  @override
  void initState() {
    super.initState();
    _centerPress = AnimationController(
      vsync: this,
      lowerBound: -0.5,
      upperBound: 1.2,
      value: 0,
      duration: const Duration(milliseconds: 110),
    );
  }

  @override
  void dispose() {
    _centerPress.dispose();
    super.dispose();
  }

  void _depressCenter() {
    _centerPress.animateTo(
      1,
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
    );
  }

  void _releaseCenter() {
    _centerPress.animateTo(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutBack,
    );
  }

  double _getAngle(Offset localPos, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    return atan2(localPos.dy - center.dy, localPos.dx - center.dx);
  }

  double _getDistance(Offset localPos, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    return (localPos - center).distance;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final diameter = min(constraints.maxWidth, constraints.maxHeight);
        final wheelRadius = diameter / 2;
        final centerRadius = (diameter * _centerFraction) / 2;

        return Center(
          child: SizedBox(
            width: diameter,
            height: diameter,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (details) {
                final dist = _getDistance(
                  details.localPosition,
                  Size(diameter, diameter),
                );
                // Only track rotation on the outer ring
                if (dist >= centerRadius && dist <= wheelRadius) {
                  _lastAngle = _getAngle(
                    details.localPosition,
                    Size(diameter, diameter),
                  );
                  _accumulatedAngle = 0.0;
                } else {
                  _lastAngle = null;
                }
              },
              onPanUpdate: (details) {
                if (_lastAngle == null) return;
                final dist = _getDistance(
                  details.localPosition,
                  Size(diameter, diameter),
                );
                if (dist < centerRadius * 0.7 || dist > wheelRadius * 1.2) {
                  _lastAngle = null;
                  return;
                }

                final currentAngle = _getAngle(
                  details.localPosition,
                  Size(diameter, diameter),
                );
                var delta = currentAngle - _lastAngle!;

                // Wrap-around handling across -pi and +pi boundary
                if (delta > pi) {
                  delta -= 2 * pi;
                } else if (delta < -pi) {
                  delta += 2 * pi;
                }

                _accumulatedAngle += delta;
                _lastAngle = currentAngle;

                if (_accumulatedAngle >= _stepThreshold) {
                  final steps = (_accumulatedAngle / _stepThreshold).floor();
                  widget.onRotate(steps);
                  _accumulatedAngle -= steps * _stepThreshold;
                } else if (_accumulatedAngle <= -_stepThreshold) {
                  final steps = (-_accumulatedAngle / _stepThreshold).floor();
                  widget.onRotate(-steps);
                  _accumulatedAngle += steps * _stepThreshold;
                }
              },
              onPanEnd: (_) {
                _lastAngle = null;
                _accumulatedAngle = 0.0;
              },
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: diameter,
                    height: diameter,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.theme.wheelBody,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                        BoxShadow(
                          color: Colors.white.withValues(alpha: 0.35),
                          blurRadius: 4,
                          offset: const Offset(0, -2),
                        ),
                      ],
                      border: Border.all(
                        color: widget.theme.wheelRim,
                        width: 1.5,
                      ),
                      gradient: RadialGradient(
                        colors: [
                          widget.theme.wheelBody,
                          widget.theme.wheelBody.withValues(alpha: 0.95),
                          widget.theme.wheelRim.withValues(alpha: 0.8),
                        ],
                        stops: const [0.75, 0.95, 1.0],
                      ),
                    ),
                  ),

                  Positioned(
                    top: diameter * 0.075,
                    child: _buildWheelButton(
                      label: 'MENU',
                      isPressed: _isMenuPressed,
                      onTap: widget.onMenu,
                      fontSize: diameter * 0.064 - 0.5,
                      isBold: true,
                    ),
                  ),

                  Positioned(
                    left: diameter * 0.06,
                    child: _buildWheelIconButton(
                      side: _WheelSide.previous,
                      mark: _ClassicSkipMark(
                        forward: false,
                        size: diameter * 0.072,
                        color: widget.theme.wheelText.withValues(
                          alpha: _isPrevPressed ? 0.6 : 1.0,
                        ),
                      ),
                      isPressed: _isPrevPressed,
                      onTap: widget.onPrevious,
                      size: diameter * 0.072,
                    ),
                  ),

                  Positioned(
                    right: diameter * 0.06,
                    child: _buildWheelIconButton(
                      side: _WheelSide.next,
                      mark: _ClassicSkipMark(
                        forward: true,
                        size: diameter * 0.072,
                        color: widget.theme.wheelText.withValues(
                          alpha: _isNextPressed ? 0.6 : 1.0,
                        ),
                      ),
                      isPressed: _isNextPressed,
                      onTap: widget.onNext,
                      size: diameter * 0.072,
                    ),
                  ),

                  Positioned(
                    bottom: diameter * 0.075,
                    child: _buildWheelIconButton(
                      side: _WheelSide.play,
                      icon: Icons.play_arrow_rounded,
                      secondaryIcon: Icons.pause_rounded,
                      isPressed: _isPlayPressed,
                      onTap: widget.onPlayPause,
                      size: diameter * 0.095,
                    ),
                  ),

                  Listener(
                    onPointerDown: (_) => _depressCenter(),
                    onPointerUp: (_) => _releaseCenter(),
                    onPointerCancel: (_) => _releaseCenter(),
                    child: GestureDetector(
                      key: const Key('click_wheel_center'),
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onSelect,
                      onLongPress: widget.onCenterLongPress,
                      child: AnimatedBuilder(
                        animation: _centerPress,
                        builder: (context, _) {
                          final t = _centerPress.value;
                          return Transform(
                            key: const Key('click_wheel_center_face'),
                            alignment: Alignment.center,
                            transform: Matrix4.identity()
                              ..translateByDouble(0, 1.6 * t, 0, 1)
                              ..scaleByDouble(
                                1 - 0.035 * t,
                                1 - 0.035 * t,
                                1,
                                1,
                              ),
                            child: Container(
                              width: diameter * _centerFraction,
                              height: diameter * _centerFraction,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: widget.theme.centerButton,
                                border: Border.all(
                                  color: widget.theme.wheelRim.withValues(
                                    alpha: 0.6,
                                  ),
                                  width: 1.0,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.08),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                  BoxShadow(
                                    color: Colors.white.withValues(alpha: 0.5),
                                    blurRadius: 2,
                                    offset: const Offset(0, -1),
                                  ),
                                ],
                                gradient: RadialGradient(
                                  colors: [
                                    widget.theme.centerButton,
                                    widget.theme.centerButton.withValues(
                                      alpha: 0.9,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildWheelButton({
    required String label,
    required bool isPressed,
    required VoidCallback onTap,
    required double fontSize,
    bool isBold = false,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _isMenuPressed = true),
      onTapUp: (_) {
        setState(() => _isMenuPressed = false);
        onTap();
      },
      onTapCancel: () => setState(() => _isMenuPressed = false),
      child: Padding(
        padding: const EdgeInsets.all(4.0),
        child: Text(
          label,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: isBold ? FontWeight.w900 : FontWeight.w700,
            letterSpacing: 1.6,
            color: widget.theme.wheelText.withValues(
              alpha: _isMenuPressed ? 0.6 : 1.0,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWheelIconButton({
    required _WheelSide side,
    IconData? icon,
    Widget? mark,
    IconData? secondaryIcon,
    required bool isPressed,
    required VoidCallback onTap,
    required double size,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) {
        setState(() {
          if (side == _WheelSide.previous) _isPrevPressed = true;
          if (side == _WheelSide.next) _isNextPressed = true;
          if (side == _WheelSide.play) _isPlayPressed = true;
        });
      },
      onTapUp: (_) {
        setState(() {
          _isPrevPressed = false;
          _isNextPressed = false;
          _isPlayPressed = false;
        });
        onTap();
      },
      onTapCancel: () {
        setState(() {
          _isPrevPressed = false;
          _isNextPressed = false;
          _isPlayPressed = false;
        });
      },
      child: Padding(
        padding: const EdgeInsets.all(4.0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (mark != null)
              mark
            else
              Icon(
                icon!,
                size: size,
                color: widget.theme.wheelText.withValues(
                  alpha: isPressed ? 0.6 : 1.0,
                ),
              ),
            if (secondaryIcon != null) ...[
              const SizedBox(width: 2),
              Icon(
                secondaryIcon,
                size: size * 0.82,
                color: widget.theme.wheelText.withValues(
                  alpha: isPressed ? 0.6 : 1.0,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum _WheelSide { previous, next, play }

/// Classic click-wheel skip mark: two triangles and one end bar.
/// Previous is |◀◀, next is ▶▶|.
class _ClassicSkipMark extends StatelessWidget {
  final bool forward;
  final double size;
  final Color color;

  const _ClassicSkipMark({
    required this.forward,
    required this.size,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final triW = size * 0.52;
    final width = triW * 1.62 + size * 0.14 + size * 0.13;
    return CustomPaint(
      size: Size(width, size),
      painter: _ClassicSkipPainter(forward: forward, color: color),
    );
  }
}

class _ClassicSkipPainter extends CustomPainter {
  final bool forward;
  final Color color;

  const _ClassicSkipPainter({required this.forward, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final triW = h * 0.52;
    final step = triW * 0.62;
    final gap = h * 0.14;
    final barW = h * 0.13;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    Path triangle(double left, bool pointRight) {
      final top = h * 0.08;
      final bottom = h * 0.92;
      final midY = h * 0.5;
      if (pointRight) {
        return Path()
          ..moveTo(left, top)
          ..lineTo(left + triW, midY)
          ..lineTo(left, bottom)
          ..close();
      }
      return Path()
        ..moveTo(left + triW, top)
        ..lineTo(left, midY)
        ..lineTo(left + triW, bottom)
        ..close();
    }

    void bar(double left) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, h * 0.08, barW, h * 0.84),
          Radius.circular(barW / 2),
        ),
        paint,
      );
    }

    if (forward) {
      canvas.drawPath(triangle(0, true), paint);
      canvas.drawPath(triangle(step, true), paint);
      bar(step + triW + gap);
    } else {
      bar(0);
      final start = barW + gap;
      canvas.drawPath(triangle(start, false), paint);
      canvas.drawPath(triangle(start + step, false), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ClassicSkipPainter oldDelegate) {
    return oldDelegate.forward != forward || oldDelegate.color != color;
  }
}
