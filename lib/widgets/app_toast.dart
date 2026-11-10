import 'package:flutter/material.dart';

/// Toast type for styling
enum ToastType { success, error, warning, info }

/// Modern styled toast notifications for the app
class AppToast {
  /// Show a styled toast notification
  static void show(
    BuildContext context, {
    required String message,
    ToastType type = ToastType.info,
    Duration duration = const Duration(seconds: 3),
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final (icon, iconColor, borderColor) = _getTypeStyles(type);

    // Dark theme background matching app style
    const backgroundColor = Color(0xFF1E293B); // slate-800

    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    color: Colors.grey.shade200,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          backgroundColor: backgroundColor,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: borderColor.withValues(alpha: 0.4)),
          ),
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          duration: duration,
          action: actionLabel != null && onAction != null
              ? SnackBarAction(
                  label: actionLabel,
                  textColor: iconColor,
                  onPressed: onAction,
                )
              : null,
        ),
      );
  }

  /// Show a success toast
  static void success(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 3),
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    show(
      context,
      message: message,
      type: ToastType.success,
      duration: duration,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }

  /// Show an error toast
  static void error(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 4),
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    show(
      context,
      message: message,
      type: ToastType.error,
      duration: duration,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }

  /// Show a warning toast
  static void warning(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 3),
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    show(
      context,
      message: message,
      type: ToastType.warning,
      duration: duration,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }

  /// Show an info toast
  static void info(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 3),
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    show(
      context,
      message: message,
      type: ToastType.info,
      duration: duration,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }

  /// Show a simple toast (no icon, minimal style)
  static void simple(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    // Dark theme background matching app style
    const backgroundColor = Color(0xFF1E293B); // slate-800

    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: TextStyle(
              color: Colors.grey.shade200,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
          ),
          backgroundColor: backgroundColor,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: Colors.grey.shade700),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          duration: duration,
        ),
      );
  }

  /// Get styling based on toast type
  /// Returns (icon, iconColor, borderColor)
  static (IconData, Color, Color) _getTypeStyles(ToastType type) {
    switch (type) {
      case ToastType.success:
        return (
          Icons.check_circle_outline,
          Colors.green.shade400,
          Colors.green.shade600,
        );
      case ToastType.error:
        return (
          Icons.error_outline,
          Colors.red.shade400,
          Colors.red.shade600,
        );
      case ToastType.warning:
        return (
          Icons.warning_amber_outlined,
          Colors.orange.shade400,
          Colors.orange.shade600,
        );
      case ToastType.info:
        return (
          Icons.info_outline,
          Colors.blue.shade400,
          Colors.blue.shade600,
        );
    }
  }
}
