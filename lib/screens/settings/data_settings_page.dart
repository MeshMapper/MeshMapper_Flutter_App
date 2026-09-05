import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

// Conditional import for web file helpers
import '../../utils/web_file_helpers_stub.dart'
    if (dart.library.html) '../../utils/web_file_helpers.dart';

import '../../providers/app_state_provider.dart';
import '../../services/offline_session_service.dart';
import 'settings_section_card.dart';

/// Settings folder: Data.
class DataSettingsPage extends StatelessWidget {
  const DataSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: const Text('Data', style: TextStyle(fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          SettingsSectionCard(children: [
            ListTile(
              leading: const Icon(Icons.cloud_queue),
              title: const Text('Queued Pings'),
              subtitle: Text('${appState.queueSize} items waiting'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.cloud_upload),
                    onPressed: appState.queueSize > 0
                        ? () => appState.forceUploadQueue()
                        : null,
                    tooltip: 'Force upload',
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: appState.queueSize > 0
                        ? () => _confirmClearQueue(context, appState)
                        : null,
                    tooltip: 'Clear queue',
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.delete_sweep),
              title: const Text('Clear Map Markers'),
              subtitle: const Text('Remove all TX/RX markers from map'),
              onTap: () => _confirmClearPings(context, appState),
            ),
          ]),

          // Offline Sessions
          SettingsSectionCard(title: 'Offline Sessions', children: [
            if (appState.offlineSessions.isEmpty)
              ListTile(
                leading: Icon(Icons.cloud_off, color: Colors.grey.shade400),
                title: Text(
                  'No offline sessions stored',
                  style: TextStyle(color: Colors.grey.shade500),
                ),
                subtitle: Text(
                  'Sessions recorded in offline mode will appear here',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                ),
              )
            else
              ...appState.offlineSessions.map((session) => _OfflineSessionTile(
                    session: session,
                    uploadEnabled: !appState.isUploadingOfflineSession,
                    onUpload: () => _uploadOfflineSession(
                        context, appState, session.filename),
                    onDelete: () => _confirmDeleteOfflineSession(
                        context, appState, session.filename),
                    onDownload: () => _downloadOfflineSession(
                        context, appState, session.filename),
                  )),
          ]),
        ],
      ),
    );
  }

  void _confirmClearQueue(BuildContext context, AppStateProvider appState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Queue?'),
        content: Text(
          'This will permanently delete ${appState.queueSize} queued pings that haven\'t been uploaded yet.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              appState.clearQueue();
              Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  void _confirmClearPings(BuildContext context, AppStateProvider appState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Map Markers?'),
        content: const Text(
          'This will remove all markers from the map. This won\'t affect uploaded data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              appState.clearPings();
              Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  Future<void> _uploadOfflineSession(
      BuildContext context, AppStateProvider appState, String filename) async {
    // Progress text notifier for updating dialog without rebuilding screen
    final progressNotifier = ValueNotifier<String>('Authenticating...');

    // Show non-dismissible progress dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              const Text(
                'Uploading session...',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              Text(
                filename,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<String>(
                valueListenable: progressNotifier,
                builder: (_, status, __) => Text(
                  status,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final result = await appState.uploadOfflineSessionWithAuth(
      filename,
      onProgress: (status) => progressNotifier.value = status,
    );

    // Close progress dialog
    if (context.mounted) {
      Navigator.of(context).pop();
    }

    progressNotifier.dispose();

    if (context.mounted) {
      // Show result via SnackBar
      String message;
      Color backgroundColor;

      switch (result) {
        case OfflineUploadResult.success:
          message = 'Upload Success';
          backgroundColor = Colors.green;
          break;
        case OfflineUploadResult.notFound:
          message = 'Session not found: $filename';
          backgroundColor = Colors.red;
          break;
        case OfflineUploadResult.invalidSession:
          message = 'Invalid session data or missing device credentials';
          backgroundColor = Colors.red;
          break;
        case OfflineUploadResult.authFailed:
          message = 'Authentication failed - Advert your device on the mesh';
          backgroundColor = Colors.red;
          break;
        case OfflineUploadResult.networkError:
          message = 'Network error - tap again to retry';
          backgroundColor = Colors.orange;
          break;
        case OfflineUploadResult.gpsRequired:
          message = 'GPS required - enable location services to upload';
          backgroundColor = Colors.red;
          break;
        case OfflineUploadResult.partialFailure:
          message = 'Partial upload - tap again to retry remaining pings';
          backgroundColor = Colors.orange;
          break;
        case OfflineUploadResult.uploadInProgress:
          message = 'Another upload is already in progress';
          backgroundColor = Colors.orange;
          break;
        case OfflineUploadResult.zoneDisabled:
          message = 'Upload failed - wardriving is disabled in this zone';
          backgroundColor = Colors.red;
          break;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
          backgroundColor: backgroundColor,
        ),
      );
    }
  }

  void _confirmDeleteOfflineSession(
      BuildContext context, AppStateProvider appState, String filename) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Offline Session?'),
        content: Text(
          'This will permanently delete the offline session "$filename" without uploading.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              appState.deleteOfflineSession(filename);
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadOfflineSession(
      BuildContext context, AppStateProvider appState, String filename) async {
    try {
      final sessionData =
          appState.offlineSessionService.getSessionData(filename);
      if (sessionData == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to load session data'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // Convert to pretty JSON
      final jsonString =
          const JsonEncoder.withIndent('  ').convert(sessionData);

      if (kIsWeb && isWebFileHelpersAvailable) {
        // Web: Create a blob and trigger download
        downloadFileWeb(
          content: jsonString,
          filename: filename,
          mimeType: 'application/json',
        );

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Downloaded: $filename'),
              duration: const Duration(seconds: 2),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        // Mobile: write the JSON to a temp file and open the native share
        // sheet (Save to Files, Drive, email, …) — mirrors the debug-log share.
        await appState.shareOfflineSession(filename);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error downloading: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

/// Widget for displaying an offline session in the list
class _OfflineSessionTile extends StatelessWidget {
  final OfflineSession session;
  final bool uploadEnabled;
  final VoidCallback onUpload;
  final VoidCallback onDelete;
  final VoidCallback onDownload;

  const _OfflineSessionTile({
    required this.session,
    this.uploadEnabled = true,
    required this.onUpload,
    required this.onDelete,
    required this.onDownload,
  });

  bool get _hasSummary =>
      (session.placementCounts?.isNotEmpty ?? false) ||
      ((session.tooFarRegion ?? 0) > 0);

  /// e.g. "DSA 88 · EMA 157 · too far 3"
  String _placementSummary() {
    final parts = <String>[];
    final pc = session.placementCounts;
    if (pc != null && pc.isNotEmpty) {
      final entries = pc.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      parts.addAll(entries.map((e) => '${e.key} ${e.value}'));
    }
    final tf = session.tooFarRegion ?? 0;
    if (tf > 0) parts.add('too far $tf');
    return parts.join(' · ');
  }

  void _showSummaryDialog(BuildContext context) {
    final pc = session.placementCounts ?? <String, int>{};
    final tf = session.tooFarRegion ?? 0;
    final entries = pc.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Upload Summary'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(session.filename,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            if (entries.isEmpty)
              const Text('No regional placement recorded.')
            else
              ...entries.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(e.key,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        Text('${e.value} pings'),
                      ],
                    ),
                  )),
            if (tf > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '$tf ping(s) dropped — more than 50 km outside every region',
                  style: TextStyle(color: Colors.orange.shade800, fontSize: 12),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isUploaded = session.uploaded;

    return ListTile(
      onTap: (isUploaded && _hasSummary)
          ? () => _showSummaryDialog(context)
          : null,
      leading: Icon(
        isUploaded ? Icons.cloud_done : Icons.cloud_off,
        color: isUploaded ? Colors.green : Colors.orange,
      ),
      title: Text(session.filename),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${session.pingCount} pings • ${session.displayDate}'),
          if (isUploaded)
            Text(
              _hasSummary ? 'Uploaded · ${_placementSummary()}' : 'Uploaded',
              style: const TextStyle(
                  color: Colors.green,
                  fontSize: 12,
                  fontWeight: FontWeight.w500),
            ),
          if (session.deviceName != null)
            Text(
              'Device: ${session.deviceName}',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
            ),
        ],
      ),
      isThreeLine: session.deviceName != null || isUploaded,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Download button - always available
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: onDownload,
            tooltip: 'Download JSON',
            color: Colors.blue,
          ),
          // Upload button - only when not uploaded
          if (!isUploaded)
            IconButton(
              icon: const Icon(Icons.cloud_upload),
              onPressed: uploadEnabled ? onUpload : null,
              tooltip: 'Upload session',
              color: uploadEnabled ? Colors.green : Colors.grey,
            ),
          // Delete button - always available
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
            tooltip: 'Delete session',
            color: Colors.red,
          ),
        ],
      ),
    );
  }
}
