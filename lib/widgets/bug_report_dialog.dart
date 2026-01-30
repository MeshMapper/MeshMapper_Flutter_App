import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../providers/app_state_provider.dart';
import '../services/debug_submit_service.dart';
import '../utils/constants.dart';
import '../utils/debug_logger_io.dart';

/// Bottom sheet for submitting bug reports with optional debug log uploads
class BugReportSheet extends StatefulWidget {
  final AppStateProvider appState;
  final ScrollController scrollController;

  const BugReportSheet({
    super.key,
    required this.appState,
    required this.scrollController,
  });

  @override
  State<BugReportSheet> createState() => _BugReportSheetState();
}

class _BugReportSheetState extends State<BugReportSheet> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();

  String _platform = 'app'; // app, map, other
  String _ticketType = 'bug'; // bug, enhancement
  bool _uploadLogs = false;
  final Set<String> _selectedLogFiles = {};
  bool _isSubmitting = false;
  String? _errorMessage;

  // Progress tracking
  double _progress = 0.0;
  String _progressStatus = '';
  int? _currentFile;
  int? _totalFiles;

  // Uploadable log files (excludes currently active log)
  List<File> _availableLogFiles = [];
  bool _isLoadingFiles = true;

  @override
  void initState() {
    super.initState();
    _loadUploadableFiles();
  }

  Future<void> _loadUploadableFiles() async {
    try {
      // Rotate log and get uploadable files (excludes new current file)
      final files = await widget.appState.prepareDebugLogsForUpload();
      if (mounted) {
        setState(() {
          _availableLogFiles = files;
          _isLoadingFiles = false;
        });
      }
    } catch (e) {
      debugError('[BUG REPORT] Failed to load uploadable files: $e');
      if (mounted) {
        setState(() {
          _availableLogFiles = [];
          _isLoadingFiles = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _toggleFile(String path) {
    setState(() {
      if (_selectedLogFiles.contains(path)) {
        _selectedLogFiles.remove(path);
      } else {
        _selectedLogFiles.add(path);
      }
    });
  }

  void _onProgressUpdate(BugReportProgress progress) {
    if (mounted) {
      setState(() {
        _progress = progress.progress;
        _progressStatus = progress.status;
        _currentFile = progress.currentFile;
        _totalFiles = progress.totalFiles;
      });
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
      _progress = 0.0;
      _progressStatus = 'Starting...';
      _currentFile = null;
      _totalFiles = null;
    });

    try {
      final service = DebugSubmitService();

      // Get selected files
      List<File>? filesToUpload;
      if (_uploadLogs && _selectedLogFiles.isNotEmpty) {
        filesToUpload = _availableLogFiles
            .where((f) => _selectedLogFiles.contains(f.path))
            .toList();
      }

      // Use current connection values if connected, otherwise use last connected values
      final publicKey = widget.appState.devicePublicKey ??
          widget.appState.lastConnectedPublicKey ??
          'not-connected';

      // Use last connected device name (companion name without MeshCore- prefix)
      final deviceName = widget.appState.lastConnectedDeviceName ?? 'not-connected';

      final result = await service.submitBugReport(
        title: _titleController.text.trim(),
        body: _descriptionController.text.trim(),
        platform: _platform,
        ticketType: _ticketType,
        deviceId: deviceName,
        publicKey: publicKey,
        appVersion: AppConstants.appVersion,
        devicePlatform: DebugSubmitService.getDevicePlatform(),
        debugFiles: filesToUpload,
        userNotes: _descriptionController.text.trim(),
        onProgress: _onProgressUpdate,
      );

      service.dispose();

      if (!mounted) return;

      if (result.success) {
        debugLog('[BUG REPORT] Report submitted successfully: ${result.issueUrl}');
        Navigator.of(context).pop(result);
      } else {
        setState(() {
          _errorMessage = result.errorMessage ?? 'Failed to submit report';
          _isSubmitting = false;
          _progress = 0.0;
          _progressStatus = '';
        });
      }
    } catch (e) {
      debugError('[BUG REPORT] Submit error: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Error: $e';
          _isSubmitting = false;
          _progress = 0.0;
          _progressStatus = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Show progress view when submitting
    if (_isSubmitting) {
      return _buildProgressView(theme);
    }

    return Column(
      children: [
        // Drag handle
        Center(
          child: Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),

        // Header with icon
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.feedback_outlined, color: theme.colorScheme.primary, size: 28),
              const SizedBox(width: 12),
              Text('Submit Feedback', style: theme.textTheme.titleLarge),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
                tooltip: 'Close',
              ),
            ],
          ),
        ),

        const Divider(height: 1),

        // Scrollable content
        Expanded(
          child: GestureDetector(
            onTap: () => FocusScope.of(context).unfocus(),
            behavior: HitTestBehavior.opaque,
            child: Form(
              key: _formKey,
              child: ListView(
                controller: widget.scrollController,
                padding: const EdgeInsets.all(20),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                // Ticket type selector - SegmentedButton
                _buildSectionLabel(theme, Icons.category, 'Report Type'),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'bug',
                      label: Text('Bug'),
                      icon: Icon(Icons.bug_report, size: 18),
                    ),
                    ButtonSegment(
                      value: 'enhancement',
                      label: Text('Feature'),
                      icon: Icon(Icons.lightbulb_outline, size: 18),
                    ),
                  ],
                  selected: {_ticketType},
                  onSelectionChanged: _isSubmitting
                      ? null
                      : (selected) => setState(() => _ticketType = selected.first),
                  showSelectedIcon: false,
                ),
                const SizedBox(height: 24),

                // Title field
                _buildSectionLabel(theme, Icons.title, 'Title'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _titleController,
                  decoration: _buildInputDecoration(
                    theme,
                    hintText: 'Brief summary of the issue',
                  ),
                  maxLength: 100,
                  enabled: !_isSubmitting,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Title is required';
                    }
                    if (value.trim().length < 5) {
                      return 'Title must be at least 5 characters';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Description field
                _buildSectionLabel(theme, Icons.description, 'Description'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _descriptionController,
                  decoration: _buildInputDecoration(
                    theme,
                    hintText: 'Describe the issue or feature request...',
                    alignLabelWithHint: true,
                  ),
                  maxLines: 5,
                  maxLength: 2000,
                  enabled: !_isSubmitting,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Description is required';
                    }
                    if (value.trim().length < 20) {
                      return 'Please provide more detail (at least 20 characters)';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Platform selector
                _buildSectionLabel(theme, Icons.devices, 'Platform'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    _buildPlatformChip(theme, 'App', 'app', Icons.phone_android),
                    _buildPlatformChip(theme, 'Map', 'map', Icons.map),
                    _buildPlatformChip(theme, 'Other', 'other', Icons.more_horiz),
                  ],
                ),

                // Debug logs section (mobile only)
                if (!kIsWeb && _isLoadingFiles) ...[
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: theme.colorScheme.outline.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Preparing log files...',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                // Debug logs section - always visible when files available
                if (!kIsWeb && !_isLoadingFiles && _availableLogFiles.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  _buildSectionLabel(theme, Icons.description, 'Debug Logs'),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: theme.colorScheme.outline.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      children: [
                        // Header with attach toggle
                        SwitchListTile(
                          title: const Text('Include with feedback'),
                          subtitle: Text(
                            'Select logs to attach to this report',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          value: _uploadLogs,
                          onChanged: _isSubmitting
                              ? null
                              : (value) {
                                  setState(() {
                                    _uploadLogs = value;
                                    if (!_uploadLogs) {
                                      _selectedLogFiles.clear();
                                    }
                                  });
                                },
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        ),
                        Divider(
                          height: 1,
                          color: theme.colorScheme.outline.withValues(alpha: 0.3),
                        ),
                        // Log file list - only shown when toggle is on
                        if (_uploadLogs)
                          ...List.generate(_availableLogFiles.length, (index) {
                            final file = _availableLogFiles[index];
                            final filename = file.path.split('/').last;
                            final sizeKb = (file.lengthSync() / 1024).toStringAsFixed(1);
                            final isSelected = _selectedLogFiles.contains(file.path);

                            return ListTile(
                              dense: true,
                              leading: Checkbox(
                                value: isSelected,
                                onChanged: _isSubmitting
                                    ? null
                                    : (_) => _toggleFile(file.path),
                              ),
                              title: Text(
                                filename,
                                style: const TextStyle(fontSize: 13),
                              ),
                              trailing: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '$sizeKb KB',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              onTap: _isSubmitting ? null : () => _toggleFile(file.path),
                            );
                          }),
                      ],
                    ),
                  ),
                ],

                // Error message
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: theme.colorScheme.error.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 20,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Bottom padding for safe area
                SizedBox(height: MediaQuery.of(context).padding.bottom + 80),
              ],
            ),
          ),
        ),
        ),

        // Sticky bottom action bar
        Container(
          padding: EdgeInsets.fromLTRB(
            20,
            12,
            20,
            MediaQuery.of(context).padding.bottom + 12,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              top: BorderSide(
                color: theme.colorScheme.outline.withValues(alpha: 0.3),
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: _isSubmitting ? null : _submit,
                  icon: _isSubmitting
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.onPrimary,
                          ),
                        )
                      : const Icon(Icons.send, size: 18),
                  label: Text(_isSubmitting ? 'Submitting...' : 'Submit'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProgressView(ThemeData theme) {
    return Column(
      children: [
        // Drag handle
        Center(
          child: Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),

        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.feedback_outlined, color: theme.colorScheme.primary, size: 28),
              const SizedBox(width: 12),
              Text('Submitting...', style: theme.textTheme.titleLarge),
            ],
          ),
        ),

        const Divider(height: 1),

        // Progress content
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Animated icon
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Status text
                  Text(
                    _progressStatus.isNotEmpty ? _progressStatus : 'Please wait...',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),

                  // File counter
                  if (_totalFiles != null && _currentFile != null)
                    Text(
                      'File $_currentFile of $_totalFiles',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(height: 24),

                  // Progress bar
                  SizedBox(
                    width: 250,
                    child: Column(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: _progress,
                            backgroundColor: theme.colorScheme.surfaceContainerHighest,
                            color: theme.colorScheme.primary,
                            minHeight: 8,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${(_progress * 100).toInt()}%',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Bottom hint
        Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            12,
            20,
            MediaQuery.of(context).padding.bottom + 12,
          ),
          child: Text(
            'Please don\'t close this screen',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionLabel(ThemeData theme, IconData icon, String label) {
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          label,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  InputDecoration _buildInputDecoration(
    ThemeData theme, {
    String? hintText,
    bool alignLabelWithHint = false,
  }) {
    return InputDecoration(
      hintText: hintText,
      alignLabelWithHint: alignLabelWithHint,
      filled: true,
      fillColor: theme.colorScheme.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: theme.colorScheme.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: theme.colorScheme.outline.withValues(alpha: 0.5),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: theme.colorScheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: theme.colorScheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: theme.colorScheme.error, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );
  }

  Widget _buildPlatformChip(
    ThemeData theme,
    String label,
    String value,
    IconData icon,
  ) {
    final isSelected = _platform == value;
    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: isSelected
                ? theme.colorScheme.onSecondaryContainer
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
      selected: isSelected,
      onSelected: _isSubmitting
          ? null
          : (selected) {
              if (selected) {
                setState(() => _platform = value);
              }
            },
      showCheckmark: false,
    );
  }
}

/// Show the bug report dialog and return the result
Future<BugReportResult?> showBugReportDialog(
  BuildContext context,
  AppStateProvider appState,
) async {
  return showModalBottomSheet<BugReportResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => BugReportSheet(
        appState: appState,
        scrollController: scrollController,
      ),
    ),
  );
}
