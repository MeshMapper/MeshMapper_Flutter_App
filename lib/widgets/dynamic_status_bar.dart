import 'package:flutter/material.dart';

import '../services/status_message_service.dart';

/// Dynamic status bar showing real-time status messages
/// Reference: dynamicStatus element in index.html (wardrive.js)
///
/// Features:
/// - Displays current status message with color
/// - Updates via stream from StatusMessageService
/// - Minimum visibility enforcement (500ms)
/// - Countdown timer support
class DynamicStatusBar extends StatelessWidget {
  final StatusMessageService statusService;

  const DynamicStatusBar({
    super.key,
    required this.statusService,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<StatusMessage?>(
      stream: statusService.stream,
      initialData: statusService.currentMessage,
      builder: (context, snapshot) {
        final message = snapshot.data;

        if (message == null) {
          return _buildEmpty();
        }

        return _buildMessage(context, message);
      },
    );
  }

  Widget _buildEmpty() {
    return const SizedBox(
      height: 32,
      child: Center(
        child: Text(
          'Ready',
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey,
          ),
        ),
      ),
    );
  }

  Widget _buildMessage(BuildContext context, StatusMessage message) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Text(
          message.text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: _getColor(context, message.color),
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// Get Flutter color from StatusColor enum
  Color _getColor(BuildContext context, StatusColor statusColor) {
    switch (statusColor) {
      case StatusColor.idle:
        return Colors.grey.shade400;
      case StatusColor.info:
        return Colors.blue.shade300;
      case StatusColor.success:
        return Colors.green.shade300;
      case StatusColor.warning:
        return Colors.amber.shade300;
      case StatusColor.error:
        return Colors.red.shade300;
    }
  }
}
