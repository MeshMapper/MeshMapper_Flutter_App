import 'dart:io';

import 'package:flutter/material.dart';

import '../providers/app_state_provider.dart';
import '../services/debug_file_logger.dart';
import '../services/debug_submit_service.dart';
import '../utils/constants.dart';
import '../utils/debug_logger_io.dart';

/// Result of a log upload operation
class UploadLogsResult {
  final bool success;
  final int uploadedCount;
  final int failedCount;
  final String? errorMessage;

  const UploadLogsResult({
    required this.success,
    this.uploadedCount = 0,
    this.failedCount = 0,
    this.errorMessage,
  });
}

/// Bottom sheet for uploading debug logs with a mandatory description
class UploadLogsSheet extends StatefulWidget {
  final AppStateProvider appState;
  final ScrollController scrollController;

  const UploadLogsSheet({
    super.key,
    required this.appState,
    required this.scrollController,
  });

  @override
  State<UploadLogsSheet> createState() => _UploadLogsSheetState();
}

class _UploadLogsSheetState extends State<UploadLogsSheet> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();

  final Set<String> _selectedLogFiles = {};
  bool _isSubmitting = false;
  String? _errorMessage;

  // Progress tracking
  double _progress = 0.0;
  String _progressStatus = '';
  int? _currentFile;
  int? _totalFiles;

  // Uploadable log files
  List<File> _availableLogFiles = [];
  bool _isLoadingFiles = true;

  @override
  void initState() {
    super.initState();
    _loadUploadableFiles();
  }

  Future<void> _loadUploadableFiles() async {
    try {
      final files = await DebugFileLogger.listUploadableLogFiles();
      if (mounted) {
        setState(() {
          _availableLogFiles = files;
          _isLoadingFiles = false;
          // Select all by default
          _selectedLogFiles.addAll(files.map((f) => f.path));
        });
      }
    } catch (e) {
      debugError('[DEBUG] Failed to load uploadable files: $e');
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

    if (_selectedLogFiles.isEmpty) {
      setState(() {
        _errorMessage = 'Please select at least one log file to upload';
      });
      return;
    }

    // Warn user about GPS data in debug logs
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Location Data Warning'),
        content: const Text(
          'Debug logs may contain your approximate GPS coordinates '
          'from your wardriving session. This location history will '
          'be included in the uploaded files.\n\n'
          'Do you want to continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
      _progress = 0.0;
      _progressStatus = 'Preparing logs...';
      _currentFile = null;
      _totalFiles = null;
    });

    try {
      // Rotate the current log file now that the user has committed to uploading
      final freshFiles = await widget.appState.prepareDebugLogsForUpload();

      // Build the upload list using the user's selection applied to the freshly rotated files.
      // Selected paths from before rotation still match, plus any newly rotated file is included.
      final selectedPaths = Set<String>.from(_selectedLogFiles);
      final filesToUpload = freshFiles
          .where((f) => selectedPaths.contains(f.path))
          .toList();

      // If the rotation produced a new file that wasn't in the original selection
      // (i.e. the previously-active log that just got rotated), include it too
      // since the user selected "all" initially and this file has new content.
      final newFiles = freshFiles.where((f) => !selectedPaths.contains(f.path)).toList();
      if (newFiles.isNotEmpty && selectedPaths.length == _availableLogFiles.length) {
        filesToUpload.addAll(newFiles);
      }

      if (filesToUpload.isEmpty) {
        if (mounted) {
          setState(() {
            _errorMessage = 'No log files to upload after preparation';
            _isSubmitting = false;
            _progress = 0.0;
            _progressStatus = '';
          });
        }
        return;
      }

      final service = DebugSubmitService();

      final publicKey = widget.appState.devicePublicKey ??
          widget.appState.lastConnectedPublicKey ??
          'not-connected';
      final deviceName = widget.appState.lastConnectedDeviceName ?? 'not-connected';
      final userNotes = _descriptionController.text.trim();

      int uploadedCount = 0;
      int failedCount = 0;
      final totalFiles = filesToUpload.length;

      for (int i = 0; i < totalFiles; i++) {
        final file = filesToUpload[i];
        final progressBase = i / totalFiles;
        final progressPerFile = 1.0 / totalFiles;

        _onProgressUpdate(BugReportProgress(
          status: 'Uploading file ${i + 1} of $totalFiles...',
          progress: progressBase,
          currentFile: i + 1,
          totalFiles: totalFiles,
        ));

        final success = await service.uploadDebugFileOnly(
          file: file,
          deviceId: deviceName,
          publicKey: publicKey,
          appVersion: AppConstants.appVersion,
          devicePlatform: DebugSubmitService.getDevicePlatform(),
          userNotes: userNotes,
          onProgress: (p) {
            _onProgressUpdate(BugReportProgress(
              status: p.status,
              progress: (progressBase + p.progress * progressPerFile).clamp(0.0, 1.0),
              currentFile: i + 1,
              totalFiles: totalFiles,
            ));
          },
        );

        if (success) {
          uploadedCount++;
        } else {
          failedCount++;
        }
      }

      service.dispose();

      if (!mounted) return;

      final result = UploadLogsResult(
        success: uploadedCount > 0,
        uploadedCount: uploadedCount,
        failedCount: failedCount,
        errorMessage: failedCount > 0 ? '$failedCount file(s) failed to upload' : null,
      );

      Navigator.of(context).pop(result);
    } catch (e) {
      debugError('[DEBUG] Upload logs error: $e');
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

        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.cloud_upload_outlined, color: theme.colorScheme.primary, size: 28),
              const SizedBox(width: 12),
              Text('Upload Logs', style: theme.textTheme.titleLarge),
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
                  // Explanation text
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: theme.colorScheme.primary.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Upload your debug logs directly to the MeshMapper developers. '
                            'This helps us diagnose issues and improve the app.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Description field (mandatory)
                  _buildSectionLabel(theme, Icons.description, 'Description'),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _descriptionController,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: _buildInputDecoration(
                      theme,
                      hintText: 'Briefly describe why you\'re uploading these logs...',
                      alignLabelWithHint: true,
                    ),
                    maxLines: 3,
                    maxLength: 500,
                    enabled: !_isSubmitting,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'A description is required';
                      }
                      if (value.trim().length < 10) {
                        return 'Please provide more detail (at least 10 characters)';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Log files section
                  _buildSectionLabel(theme, Icons.folder_open, 'Log Files'),
                  const SizedBox(height: 8),

                  if (_isLoadingFiles)
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
                    )
                  else if (_availableLogFiles.isEmpty)
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
                          Icon(
                            Icons.info_outline,
                            size: 20,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'No log files available to upload',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
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
                          // Select all / deselect all header
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: Row(
                              children: [
                                Text(
                                  '${_selectedLogFiles.length} of ${_availableLogFiles.length} selected',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const Spacer(),
                                TextButton(
                                  onPressed: () {
                                    setState(() {
                                      if (_selectedLogFiles.length == _availableLogFiles.length) {
                                        _selectedLogFiles.clear();
                                      } else {
                                        _selectedLogFiles.clear();
                                        _selectedLogFiles.addAll(
                                          _availableLogFiles.map((f) => f.path),
                                        );
                                      }
                                    });
                                  },
                                  child: Text(
                                    _selectedLogFiles.length == _availableLogFiles.length
                                        ? 'Deselect All'
                                        : 'Select All',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Divider(
                            height: 1,
                            color: theme.colorScheme.outline.withValues(alpha: 0.3),
                          ),
                          // File list
                          ...List.generate(_availableLogFiles.length, (index) {
                            final file = _availableLogFiles[index];
                            final filename = file.path.split('/').last;
                            final sizeBytes = file.lengthSync();
                            final isSelected = _selectedLogFiles.contains(file.path);

                            String sizeDisplay;
                            final partCount = DebugFileLogger.estimatePartCount(sizeBytes);
                            if (sizeBytes >= DebugFileLogger.maxUploadSizeBytes) {
                              final sizeMb = (sizeBytes / 1024 / 1024).toStringAsFixed(1);
                              sizeDisplay = '$sizeMb MB ($partCount parts)';
                            } else {
                              sizeDisplay = '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
                            }

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
                                  sizeDisplay,
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
                  onPressed: _isSubmitting || _availableLogFiles.isEmpty
                      ? null
                      : _submit,
                  icon: const Icon(Icons.cloud_upload, size: 18),
                  label: Text(
                    _selectedLogFiles.isEmpty
                        ? 'Upload'
                        : 'Upload ${_selectedLogFiles.length} Log${_selectedLogFiles.length == 1 ? '' : 's'}',
                  ),
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
              Icon(Icons.cloud_upload_outlined, color: theme.colorScheme.primary, size: 28),
              const SizedBox(width: 12),
              Text('Uploading...', style: theme.textTheme.titleLarge),
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

                  Text(
                    _progressStatus.isNotEmpty ? _progressStatus : 'Please wait...',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),

                  if (_totalFiles != null && _currentFile != null)
                    Text(
                      'File $_currentFile of $_totalFiles',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(height: 24),

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
}

/// Show the upload logs dialog and return the result
Future<UploadLogsResult?> showUploadLogsDialog(
  BuildContext context,
  AppStateProvider appState,
) async {
  return showModalBottomSheet<UploadLogsResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => UploadLogsSheet(
        appState: appState,
        scrollController: scrollController,
      ),
    ),
  );
}
