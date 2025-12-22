import 'package:flutter/material.dart';
import '../core/theme/app_theme.dart';

/// macOS-style button widget
class MacOSButton extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool isPrimary;
  final bool isDestructive;
  final bool isDark;
  final IconData? icon;

  const MacOSButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.isPrimary,
    this.isDestructive = false,
    required this.isDark,
    this.icon,
  });

  @override
  State<MacOSButton> createState() => _MacOSButtonState();
}

class _MacOSButtonState extends State<MacOSButton> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    if (widget.onPressed == null) {
      return _buildDisabled();
    }

    Color backgroundColor;
    Color textColor;

    if (widget.isPrimary) {
      if (widget.isDestructive) {
        backgroundColor = _isPressed
            ? Colors.red.shade700
            : _isHovered
            ? Colors.red.shade600
            : Colors.red.shade500;
        textColor = Colors.white;
      } else {
        backgroundColor = _isPressed
            ? AppColors.primary.withValues(alpha: 0.9)
            : _isHovered
            ? AppColors.primary.withValues(alpha: 0.95)
            : AppColors.primary;
        textColor = Colors.white;
      }
    } else {
      backgroundColor = _isPressed
          ? (widget.isDark
                ? Colors.white.withValues(alpha: 0.15)
                : Colors.black.withValues(alpha: 0.08))
          : _isHovered
          ? (widget.isDark
                ? Colors.white.withValues(alpha: 0.1)
                : Colors.black.withValues(alpha: 0.05))
          : (widget.isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.03));
      textColor = widget.isDark
          ? AppColors.textPrimary
          : AppColorsLight.textPrimary;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(5),
            border: widget.isPrimary
                ? null
                : Border.all(
                    color: widget.isDark
                        ? Colors.white.withValues(alpha: 0.15)
                        : Colors.black.withValues(alpha: 0.12),
                  ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(
                  widget.icon,
                  size: 14,
                  color: textColor.withValues(
                    alpha: widget.isPrimary ? 0.9 : 0.7,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                widget.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: textColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDisabled() {
    final textColor =
        (widget.isDark ? AppColors.textPrimary : AppColorsLight.textPrimary)
            .withValues(alpha: 0.3);
    final backgroundColor =
        (widget.isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.03))
            .withValues(alpha: 0.5);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color:
              (widget.isDark
                      ? Colors.white.withValues(alpha: 0.15)
                      : Colors.black.withValues(alpha: 0.12))
                  .withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.icon != null) ...[
            Icon(widget.icon, size: 14, color: textColor),
            const SizedBox(width: 6),
          ],
          Text(
            widget.label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: textColor,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
