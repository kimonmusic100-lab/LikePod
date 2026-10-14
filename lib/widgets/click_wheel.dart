import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/pod_theme.dart';

class ClickWheel extends StatefulWidget {
  final PodTheme theme;
  final ValueChanged<int> onRotate;
  final VoidCallback onSelect;
  final VoidCallback onMenu;
  final VoidCallback onPlayPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  const ClickWheel({
    super.key,
    required this.theme,
    required this.onRotate,
    required this.onSelect,
    required this.onMenu,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
  });

  @override
  State<ClickWheel> createState() => _ClickWheelState();
}

class _ClickWheelState extends State<ClickWheel> {
  double? _lastAngle;
  double _accumulatedAngle = 0.0;
  static const double _stepThreshold = 0.28; // ~16 degrees per tick

  bool _isCenterPressed = false;
  bool _isMenuPressed = false;
  bool _isPlayPressed = false;
  bool _isPrevPressed = false;
  bool _isNextPressed = false;

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
        final centerRadius = (diameter * 0.28) / 2;

        return Center(
          child: SizedBox(
            width: diameter,
            height: diameter,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (details) {
                final dist = _getDistance(details.localPosition, Size(diameter, diameter));
                // Only track rotation on the outer ring
                if (dist >= centerRadius && dist <= wheelRadius) {
                  _lastAngle = _getAngle(details.localPosition, Size(diameter, diameter));
                  _accumulatedAngle = 0.0;
                } else {
                  _lastAngle = null;
                }
              },
              onPanUpdate: (details) {
                if (_lastAngle == null) return;
                final dist = _getDistance(details.localPosition, Size(diameter, diameter));
                if (dist < centerRadius * 0.7 || dist > wheelRadius * 1.2) {
                  _lastAngle = null;
                  return;
                }

                final currentAngle = _getAngle(details.localPosition, Size(diameter, diameter));
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
                  // 1. Outer Wheel Ring
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

                  // 2. Button Labels around the ring
                  // MENU (Top)
                  Positioned(
                    top: diameter * 0.075,
                    child: _buildWheelButton(
                      label: 'MENU',
                      isPressed: _isMenuPressed,
                      onTap: widget.onMenu,
                      fontSize: diameter * 0.064,
                      isBold: true,
                    ),
                  ),

                  // PREVIOUS / REWIND (Left)
                  Positioned(
                    left: diameter * 0.075,
                    child: _buildWheelIconButton(
                      icon: Icons.fast_rewind_rounded,
                      isPressed: _isPrevPressed,
                      onTap: widget.onPrevious,
                      size: diameter * 0.098,
                    ),
                  ),

                  // NEXT / FAST FORWARD (Right)
                  Positioned(
                    right: diameter * 0.075,
                    child: _buildWheelIconButton(
                      icon: Icons.fast_forward_rounded,
                      isPressed: _isNextPressed,
                      onTap: widget.onNext,
                      size: diameter * 0.098,
                    ),
                  ),

                  // PLAY / PAUSE (Bottom)
                  Positioned(
                    bottom: diameter * 0.075,
                    child: _buildWheelIconButton(
                      icon: Icons.play_arrow_rounded,
                      secondaryIcon: Icons.pause_rounded,
                      isPressed: _isPlayPressed,
                      onTap: widget.onPlayPause,
                      size: diameter * 0.095,
                    ),
                  ),

                  // 3. Center Select Button (Refined authentic proportion)
                  GestureDetector(
                    onTapDown: (_) => setState(() => _isCenterPressed = true),
                    onTapUp: (_) {
                      setState(() => _isCenterPressed = false);
                      widget.onSelect();
                    },
                    onTapCancel: () => setState(() => _isCenterPressed = false),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 80),
                      width: diameter * 0.28,
                      height: diameter * 0.28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isCenterPressed
                            ? widget.theme.centerButton.withValues(alpha: 0.85)
                            : widget.theme.centerButton,
                        border: Border.all(
                          color: widget.theme.wheelRim.withValues(alpha: 0.6),
                          width: 1.0,
                        ),
                        boxShadow: _isCenterPressed
                            ? [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.2),
                                  blurRadius: 2,
                                  offset: const Offset(0, 1),
                                )
                              ]
                            : [
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
                            widget.theme.centerButton.withValues(alpha: 0.9),
                          ],
                        ),
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
            color: widget.theme.wheelText.withValues(alpha: _isMenuPressed ? 0.6 : 1.0),
          ),
        ),
      ),
    );
  }

  Widget _buildWheelIconButton({
    required IconData icon,
    IconData? secondaryIcon,
    required bool isPressed,
    required VoidCallback onTap,
    required double size,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) {
        if (icon == Icons.fast_rewind_rounded) setState(() => _isPrevPressed = true);
        if (icon == Icons.fast_forward_rounded) setState(() => _isNextPressed = true);
        if (icon == Icons.play_arrow_rounded) setState(() => _isPlayPressed = true);
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
            Icon(
              icon,
              size: size,
              color: widget.theme.wheelText.withValues(alpha: isPressed ? 0.6 : 1.0),
            ),
            if (secondaryIcon != null) ...[
              const SizedBox(width: 2),
              Icon(
                secondaryIcon,
                size: size * 0.82,
                color: widget.theme.wheelText.withValues(alpha: isPressed ? 0.6 : 1.0),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
