import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../utils/debug_logger_io.dart';
import 'debug_file_logger.dart';

/// Progress update during bug report submission
class BugReportProgress {
  final String status;
  final double progress; // 0.0 to 1.0
  final int? currentFile;
  final int? totalFiles;

  const BugReportProgress({
    required this.status,
    required this.progress,
    this.currentFile,
    this.totalFiles,
  });
}

/// Callback for progress updates
typedef BugReportProgressCallback = void Function(BugReportProgress progress);

/// Result of a bug report submission
class BugReportResult {
  final bool success;
  final String? issueUrl;
  final int? issueNumber;
  final String? errorMessage;
  final int uploadedFileCount;
  final int failedFileCount;

  const BugReportResult({
    required this.success,
    this.issueUrl,
    this.issueNumber,
    this.errorMessage,
    this.uploadedFileCount = 0,
    this.failedFileCount = 0,
  });

  factory BugReportResult.error(String message) => BugReportResult(
        success: false,
        errorMessage: message,
      );
}

/// Upload session info from request-upload endpoint
class UploadSession {
  final String uploadUrl;
  final String sessionId;
  final int expiresAt;

  const UploadSession({
    required this.uploadUrl,
    required this.sessionId,
    required this.expiresAt,
  });

  factory UploadSession.fromJson(Map<String, dynamic> json) => UploadSession(
        uploadUrl: json['upload_url'] as String,
        sessionId: json['session_id'] as String,
        expiresAt: json['expires_at'] as int,
      );
}

/// Service for submitting bug reports and uploading debug files
class DebugSubmitService {
  static const String baseUrl = 'https://meshmapper.net/debug/submitdebug.php';

  final http.Client _client;

  DebugSubmitService({http.Client? client}) : _client = client ?? http.Client();

  /// Main orchestration method - submits bug report with optional file uploads
  Future<BugReportResult> submitBugReport({
    required String title,
    required String body,
    required String platform,
    required String ticketType,
    required String deviceId,
    required String publicKey,
    required String appVersion,
    required String devicePlatform,
    List<File>? debugFiles,
    String? userNotes,
    BugReportProgressCallback? onProgress,
  }) async {
    final totalFiles = debugFiles?.length ?? 0;
    final hasFiles = totalFiles > 0;

    // Progress calculation:
    // - Creating ticket: 0% -> 20%
    // - Uploading files: 20% -> 90% (divided among files)
    // - Finalizing: 90% -> 100%

    void reportProgress(String status, double progress, {int? currentFile}) {
      onProgress?.call(BugReportProgress(
        status: status,
        progress: progress.clamp(0.0, 1.0),
        currentFile: currentFile,
        totalFiles: hasFiles ? totalFiles : null,
      ));
    }

    debugLog('[BUG REPORT] ========================================');
    debugLog('[BUG REPORT] Starting bug report submission');
    debugLog('[BUG REPORT] Title: $title');
    debugLog('[BUG REPORT] Platform: $platform, Type: $ticketType');
    debugLog('[BUG REPORT] Device ID: $deviceId');
    debugLog('[BUG REPORT] App Version: $appVersion, OS: $devicePlatform');
    if (hasFiles) {
      debugLog('[BUG REPORT] Files to upload: $totalFiles');
      for (final file in debugFiles!) {
        final filename = file.path.split('/').last;
        final sizeKb = (await file.length() / 1024).toStringAsFixed(1);
        debugLog('[BUG REPORT]   - $filename ($sizeKb KB)');
      }
    }
    debugLog('[BUG REPORT] ----------------------------------------');

    // Step 1: Create the ticket
    reportProgress('Creating GitHub ticket...', 0.05);
    debugLog('[BUG REPORT] Step 1/4: Creating GitHub ticket...');
    final ticketResult = await createTicket(
      title: title,
      body: body,
      platform: platform,
      ticketType: ticketType,
    );

    if (ticketResult == null || ticketResult['success'] != true) {
      final error = ticketResult?['message'] as String? ?? 'Failed to create ticket';
      debugError('[BUG REPORT] FAILED: Ticket creation failed: $error');
      debugLog('[BUG REPORT] ========================================');
      return BugReportResult.error(error);
    }

    final issueUrl = ticketResult['issue_url'] as String?;
    final issueNumber = ticketResult['issue_number'] as int?;
    debugLog('[BUG REPORT] SUCCESS: Ticket created - Issue #$issueNumber');
    debugLog('[BUG REPORT] URL: $issueUrl');

    reportProgress('Ticket created: #$issueNumber', 0.20);

    // Step 2-4: Upload debug files (if any)
    int uploadedCount = 0;
    int failedCount = 0;

    if (hasFiles) {
      debugLog('[BUG REPORT] ----------------------------------------');
      debugLog('[BUG REPORT] Starting file uploads ($totalFiles files)...');

      // Calculate progress per file (70% of progress bar divided among files)
      final progressPerFile = 0.70 / totalFiles;

      for (int i = 0; i < totalFiles; i++) {
        final file = debugFiles![i];
        final filename = file.path.split('/').last;
        final fileProgress = 0.20 + (i * progressPerFile);

        debugLog('[BUG REPORT] ----------------------------------------');
        debugLog('[BUG REPORT] File ${i + 1}/$totalFiles: $filename');

        reportProgress('Uploading $filename...', fileProgress, currentFile: i + 1);

        // Add delay before file uploads to prevent server overload
        if (totalFiles > 1) {
          final delayMs = i == 0 ? 500 : 1000; // 500ms before first, 1s between others
          debugLog('[BUG REPORT] Waiting ${delayMs}ms before upload...');
          await Future.delayed(Duration(milliseconds: delayMs));
        }

        final success = await _uploadSingleFile(
          file: file,
          deviceId: deviceId,
          publicKey: publicKey,
          appVersion: appVersion,
          devicePlatform: devicePlatform,
          issueNumber: issueNumber,
        );

        if (success) {
          uploadedCount++;
          debugLog('[BUG REPORT] File ${i + 1}/$totalFiles: SUCCESS');
          reportProgress('Uploaded $filename', fileProgress + progressPerFile, currentFile: i + 1);
        } else {
          failedCount++;
          debugError('[BUG REPORT] File ${i + 1}/$totalFiles: FAILED');
          reportProgress('Failed to upload $filename', fileProgress + progressPerFile, currentFile: i + 1);
        }
      }

      debugLog('[BUG REPORT] ----------------------------------------');
      debugLog('[BUG REPORT] Upload summary: $uploadedCount succeeded, $failedCount failed');
    }

    reportProgress('Finalizing...', 0.95);

    debugLog('[BUG REPORT] ========================================');
    debugLog('[BUG REPORT] Bug report submission complete');
    debugLog('[BUG REPORT] Issue: #$issueNumber');
    debugLog('[BUG REPORT] Files: $uploadedCount uploaded, $failedCount failed');
    debugLog('[BUG REPORT] ========================================');

    reportProgress('Complete!', 1.0);

    return BugReportResult(
      success: true,
      issueUrl: issueUrl,
      issueNumber: issueNumber,
      uploadedFileCount: uploadedCount,
      failedFileCount: failedCount,
    );
  }

  /// Upload a single file, splitting into chunks if it exceeds the size limit.
  ///
  /// For files under 4.5MB, uploads directly via [_uploadSingleChunk].
  /// For larger files, splits at newline boundaries and uploads each chunk.
  Future<bool> _uploadSingleFile({
    required File file,
    required String deviceId,
    required String publicKey,
    required String appVersion,
    required String devicePlatform,
    int? issueNumber,
  }) async {
    final filename = file.path.split('/').last;
    final fileSize = await file.length();

    // Split file if needed
    final chunks = await DebugFileLogger.splitFileIntoChunks(file);

    if (chunks.length == 1 && chunks.first.path == file.path) {
      // No splitting needed - upload directly
      return _uploadSingleChunk(
        file: file,
        deviceId: deviceId,
        publicKey: publicKey,
        appVersion: appVersion,
        devicePlatform: devicePlatform,
        issueNumber: issueNumber,
      );
    }

    // File was split into chunks
    debugLog('[BUG REPORT] File $filename (${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB) split into ${chunks.length} chunks');

    bool allSucceeded = true;
    try {
      for (int i = 0; i < chunks.length; i++) {
        final chunkName = chunks[i].path.split('/').last;
        debugLog('[BUG REPORT] Uploading chunk ${i + 1}/${chunks.length}: $chunkName');

        if (i > 0) {
          // Delay between chunk uploads
          debugLog('[BUG REPORT] Waiting 1s before next chunk...');
          await Future.delayed(const Duration(seconds: 1));
        }

        final success = await _uploadSingleChunk(
          file: chunks[i],
          deviceId: deviceId,
          publicKey: publicKey,
          appVersion: appVersion,
          devicePlatform: devicePlatform,
          issueNumber: issueNumber,
        );

        if (!success) {
          debugError('[BUG REPORT] Chunk ${i + 1}/${chunks.length} failed: $chunkName');
          allSucceeded = false;
          break;
        }
        debugLog('[BUG REPORT] Chunk ${i + 1}/${chunks.length} uploaded successfully');
      }
    } finally {
      // Always clean up temp chunk files
      debugLog('[BUG REPORT] Cleaning up ${chunks.length} temp chunk files');
      await DebugFileLogger.cleanupChunkFiles(chunks);
    }

    return allSucceeded;
  }

  /// Upload a single file (or chunk) through the 3-step process (request, upload, complete)
  Future<bool> _uploadSingleChunk({
    required File file,
    required String deviceId,
    required String publicKey,
    required String appVersion,
    required String devicePlatform,
    int? issueNumber,
  }) async {
    final filename = file.path.split('/').last;

    try {
      // Compute file hash and size
      debugLog('[BUG REPORT] Computing file hash for: $filename');
      final fileHash = await computeFileHash(file);
      final fileSize = await file.length();
      final fileSizeKb = (fileSize / 1024).toStringAsFixed(1);
      debugLog('[BUG REPORT] File size: $fileSizeKb KB, Hash: ${fileHash.substring(0, 16)}...');

      // Step 2: Request upload URL
      debugLog('[BUG REPORT] Step 2/4: Requesting upload URL...');
      final session = await requestUpload(
        deviceId: deviceId,
        publicKey: publicKey,
        fileSizeBytes: fileSize,
        fileHash: fileHash,
        appVersion: appVersion,
        platform: devicePlatform,
      );

      if (session == null) {
        debugError('[BUG REPORT] FAILED: Could not get upload URL for: $filename');
        return false;
      }
      debugLog('[BUG REPORT] SUCCESS: Got upload session: ${session.sessionId}');

      // Step 3: Upload the file (with retry logic)
      debugLog('[BUG REPORT] Step 3/4: Uploading file data...');
      var uploadSuccess = false;
      const maxRetries = 3;

      for (int attempt = 1; attempt <= maxRetries; attempt++) {
        uploadSuccess = await uploadFile(
          uploadUrl: session.uploadUrl,
          file: file,
        );

        if (uploadSuccess) {
          debugLog('[BUG REPORT] SUCCESS: File data uploaded');
          break;
        }

        if (attempt < maxRetries) {
          final delaySeconds = attempt * 2; // 2s, 4s backoff
          debugWarn('[BUG REPORT] Upload attempt $attempt/$maxRetries failed, retrying in ${delaySeconds}s...');
          await Future.delayed(Duration(seconds: delaySeconds));
        }
      }

      if (!uploadSuccess) {
        debugError('[BUG REPORT] FAILED: File upload failed after $maxRetries attempts for: $filename');
        return false;
      }

      // Step 4: Complete the upload with GitHub issue reference
      debugLog('[BUG REPORT] Step 4/4: Confirming upload...');
      final userNotes = issueNumber != null ? 'GitHub Issue: $issueNumber' : null;
      if (userNotes != null) {
        debugLog('[BUG REPORT] User notes: $userNotes');
      }

      final completeSuccess = await completeUpload(
        deviceId: deviceId,
        publicKey: publicKey,
        sessionId: session.sessionId,
        success: true,
        userNotes: userNotes,
      );

      if (!completeSuccess) {
        debugWarn('[BUG REPORT] WARNING: Upload confirmation failed for: $filename');
        debugWarn('[BUG REPORT] File was uploaded but confirmation failed - treating as success');
      } else {
        debugLog('[BUG REPORT] SUCCESS: Upload confirmed');
      }

      return true;
    } catch (e, stackTrace) {
      debugError('[BUG REPORT] EXCEPTION uploading file $filename: $e');
      debugError('[BUG REPORT] Stack trace: $stackTrace');
      return false;
    }
  }

  /// Step 1: Create a ticket (GitHub issue)
  Future<Map<String, dynamic>?> createTicket({
    required String title,
    required String body,
    required String platform,
    required String ticketType,
  }) async {
    try {
      final payload = {
        'title': title,
        'body': body,
        'platform': platform,
        'ticket_type': ticketType,
      };

      const url = '$baseUrl/create-ticket';
      debugLog('[BUG REPORT] POST $url');
      debugLog('[BUG REPORT] Request payload:');
      debugLog('[BUG REPORT]   title: $title');
      debugLog('[BUG REPORT]   platform: $platform');
      debugLog('[BUG REPORT]   ticket_type: $ticketType');
      debugLog('[BUG REPORT]   body: ${body.length} chars');

      final stopwatch = Stopwatch()..start();
      final response = await _client.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(payload),
      ).timeout(const Duration(seconds: 30));
      stopwatch.stop();

      debugLog('[BUG REPORT] Response received in ${stopwatch.elapsedMilliseconds}ms');
      debugLog('[BUG REPORT] HTTP Status: ${response.statusCode}');

      if (response.statusCode != 200) {
        debugError('[BUG REPORT] HTTP error: ${response.statusCode}');
        debugError('[BUG REPORT] Response body: ${response.body}');
        return {'success': false, 'message': 'Server error: ${response.statusCode}'};
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      debugLog('[BUG REPORT] Response JSON:');
      debugLog('[BUG REPORT]   success: ${data['success']}');
      debugLog('[BUG REPORT]   issue_number: ${data['issue_number']}');
      debugLog('[BUG REPORT]   issue_url: ${data['issue_url']}');
      if (data['message'] != null) {
        debugLog('[BUG REPORT]   message: ${data['message']}');
      }

      return data;
    } catch (e, stackTrace) {
      debugError('[BUG REPORT] Create ticket exception: $e');
      debugError('[BUG REPORT] Stack trace: $stackTrace');
      return {'success': false, 'message': 'Network error: $e'};
    }
  }

  /// Step 2: Request an upload URL for a file
  Future<UploadSession?> requestUpload({
    required String deviceId,
    required String publicKey,
    required int fileSizeBytes,
    required String fileHash,
    required String appVersion,
    required String platform,
  }) async {
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final payload = {
        'device_id': deviceId,
        'public_key': publicKey,
        'timestamp': timestamp,
        'file_size_bytes': fileSizeBytes,
        'file_hash': fileHash,
        'app_version': appVersion,
        'platform': platform,
      };

      const url = '$baseUrl/request-upload';
      final fileSizeKb = (fileSizeBytes / 1024).toStringAsFixed(1);
      debugLog('[BUG REPORT] POST $url');
      debugLog('[BUG REPORT] Request payload:');
      debugLog('[BUG REPORT]   device_id: $deviceId');
      debugLog('[BUG REPORT]   public_key: ${publicKey.length > 20 ? '${publicKey.substring(0, 20)}...' : publicKey}');
      debugLog('[BUG REPORT]   file_size_bytes: $fileSizeBytes ($fileSizeKb KB)');
      debugLog('[BUG REPORT]   file_hash: ${fileHash.substring(0, 16)}...');
      debugLog('[BUG REPORT]   app_version: $appVersion');
      debugLog('[BUG REPORT]   platform: $platform');

      final stopwatch = Stopwatch()..start();
      final response = await _client.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(payload),
      ).timeout(const Duration(seconds: 30));
      stopwatch.stop();

      debugLog('[BUG REPORT] Response received in ${stopwatch.elapsedMilliseconds}ms');
      debugLog('[BUG REPORT] HTTP Status: ${response.statusCode}');

      if (response.statusCode != 200) {
        debugError('[BUG REPORT] HTTP error: ${response.statusCode}');
        debugError('[BUG REPORT] Response body: ${response.body}');
        return null;
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      debugLog('[BUG REPORT] Response JSON:');
      debugLog('[BUG REPORT]   session_id: ${data['session_id']}');
      debugLog('[BUG REPORT]   upload_url: ${data['upload_url'] != null ? '(present)' : '(missing)'}');
      debugLog('[BUG REPORT]   expires_at: ${data['expires_at']}');

      if (data['upload_url'] == null || data['session_id'] == null) {
        debugError('[BUG REPORT] Missing required fields in response');
        debugError('[BUG REPORT] Full response: $data');
        return null;
      }

      return UploadSession.fromJson(data);
    } catch (e, stackTrace) {
      debugError('[BUG REPORT] Request upload exception: $e');
      debugError('[BUG REPORT] Stack trace: $stackTrace');
      return null;
    }
  }

  /// Step 3: Upload the file using multipart/form-data
  Future<bool> uploadFile({
    required String uploadUrl,
    required File file,
  }) async {
    try {
      final filename = file.path.split('/').last;
      final fileSize = await file.length();
      final fileSizeKb = (fileSize / 1024).toStringAsFixed(1);

      debugLog('[BUG REPORT] POST $uploadUrl');
      debugLog('[BUG REPORT] Uploading: $filename ($fileSizeKb KB)');
      debugLog('[BUG REPORT] Content-Type: multipart/form-data');

      final request = http.MultipartRequest('POST', Uri.parse(uploadUrl));

      request.files.add(await http.MultipartFile.fromPath(
        'debug_file',
        file.path,
        filename: filename,
      ));

      final stopwatch = Stopwatch()..start();
      final streamedResponse = await request.send().timeout(const Duration(seconds: 120));
      final response = await http.Response.fromStream(streamedResponse);
      stopwatch.stop();

      final durationSec = (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1);
      final speedKbps = fileSize > 0
          ? ((fileSize / 1024) / (stopwatch.elapsedMilliseconds / 1000)).toStringAsFixed(1)
          : '0';
      debugLog('[BUG REPORT] Upload completed in ${durationSec}s ($speedKbps KB/s)');
      debugLog('[BUG REPORT] HTTP Status: ${response.statusCode}');

      if (response.statusCode != 200) {
        debugError('[BUG REPORT] HTTP error: ${response.statusCode}');
        debugError('[BUG REPORT] Response body: ${response.body}');
        return false;
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      debugLog('[BUG REPORT] Response JSON:');
      debugLog('[BUG REPORT]   success: ${data['success']}');
      if (data['message'] != null) {
        debugLog('[BUG REPORT]   message: ${data['message']}');
      }
      if (data['stored_hash'] != null) {
        debugLog('[BUG REPORT]   stored_hash: ${data['stored_hash'].toString().substring(0, 16)}...');
      }

      final success = data['success'] == true;
      return success;
    } catch (e, stackTrace) {
      debugError('[BUG REPORT] Upload file exception: $e');
      debugError('[BUG REPORT] Stack trace: $stackTrace');
      return false;
    }
  }

  /// Step 4: Confirm upload completion
  Future<bool> completeUpload({
    required String deviceId,
    required String publicKey,
    required String sessionId,
    required bool success,
    String? userNotes,
  }) async {
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final payload = {
        'device_id': deviceId,
        'public_key': publicKey,
        'session_id': sessionId,
        'timestamp': timestamp,
        'success': success,
        if (userNotes != null) 'user_notes': userNotes,
      };

      const url = '$baseUrl/upload-complete';
      debugLog('[BUG REPORT] POST $url');
      debugLog('[BUG REPORT] Request payload:');
      debugLog('[BUG REPORT]   device_id: $deviceId');
      debugLog('[BUG REPORT]   session_id: $sessionId');
      debugLog('[BUG REPORT]   success: $success');
      if (userNotes != null) {
        debugLog('[BUG REPORT]   user_notes: $userNotes');
      }

      final stopwatch = Stopwatch()..start();
      final response = await _client.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(payload),
      ).timeout(const Duration(seconds: 30));
      stopwatch.stop();

      debugLog('[BUG REPORT] Response received in ${stopwatch.elapsedMilliseconds}ms');
      debugLog('[BUG REPORT] HTTP Status: ${response.statusCode}');

      if (response.statusCode != 200) {
        debugError('[BUG REPORT] HTTP error: ${response.statusCode}');
        debugError('[BUG REPORT] Response body: ${response.body}');
        return false;
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      debugLog('[BUG REPORT] Response JSON:');
      debugLog('[BUG REPORT]   success: ${data['success']}');
      debugLog('[BUG REPORT]   hash_match: ${data['hash_match']}');
      if (data['message'] != null) {
        debugLog('[BUG REPORT]   message: ${data['message']}');
      }

      final completed = data['success'] == true;
      return completed;
    } catch (e, stackTrace) {
      debugError('[BUG REPORT] Complete upload exception: $e');
      debugError('[BUG REPORT] Stack trace: $stackTrace');
      return false;
    }
  }

  /// Upload a single debug file without creating a ticket
  /// Returns true if successful. Automatically splits large files into chunks.
  Future<bool> uploadDebugFileOnly({
    required File file,
    required String deviceId,
    required String publicKey,
    required String appVersion,
    required String devicePlatform,
    String? userNotes,
    BugReportProgressCallback? onProgress,
  }) async {
    final filename = file.path.split('/').last;

    debugLog('[DEBUG UPLOAD] ========================================');
    debugLog('[DEBUG UPLOAD] Starting single file upload');
    debugLog('[DEBUG UPLOAD] File: $filename');
    debugLog('[DEBUG UPLOAD] Device ID: $deviceId');
    debugLog('[DEBUG UPLOAD] ----------------------------------------');

    try {
      // Split file into chunks if needed
      final chunks = await DebugFileLogger.splitFileIntoChunks(file);
      final totalChunks = chunks.length;
      final isChunked = totalChunks > 1 || chunks.first.path != file.path;

      if (isChunked) {
        final fileSize = await file.length();
        debugLog('[DEBUG UPLOAD] File (${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB) split into $totalChunks chunks');
      }

      // Progress range: 0.1 to 0.9 divided across chunks
      final progressPerChunk = 0.8 / totalChunks;
      bool allSucceeded = true;

      try {
        for (int i = 0; i < totalChunks; i++) {
          final chunk = chunks[i];
          final chunkName = chunk.path.split('/').last;
          final chunkBase = 0.1 + (i * progressPerChunk);

          if (isChunked) {
            debugLog('[DEBUG UPLOAD] Chunk ${i + 1}/$totalChunks: $chunkName');
          }

          void reportChunkProgress(String status, double chunkProgress) {
            final overallProgress = chunkBase + (chunkProgress * progressPerChunk);
            onProgress?.call(BugReportProgress(
              status: isChunked ? '$status (part ${i + 1}/$totalChunks)' : status,
              progress: overallProgress.clamp(0.0, 1.0),
              currentFile: isChunked ? i + 1 : 1,
              totalFiles: isChunked ? totalChunks : 1,
            ));
          }

          // Delay between chunks
          if (i > 0) {
            debugLog('[DEBUG UPLOAD] Waiting 1s before next chunk...');
            await Future.delayed(const Duration(seconds: 1));
          }

          // Step 1: Compute hash
          reportChunkProgress('Preparing file...', 0.0);
          debugLog('[DEBUG UPLOAD] Computing file hash...');
          final fileHash = await computeFileHash(chunk);
          final chunkSize = await chunk.length();
          final chunkSizeKb = (chunkSize / 1024).toStringAsFixed(1);
          debugLog('[DEBUG UPLOAD] Chunk size: $chunkSizeKb KB, Hash: ${fileHash.substring(0, 16)}...');

          // Step 2: Request upload URL
          reportChunkProgress('Requesting upload...', 0.2);
          debugLog('[DEBUG UPLOAD] Requesting upload URL...');
          final session = await requestUpload(
            deviceId: deviceId,
            publicKey: publicKey,
            fileSizeBytes: chunkSize,
            fileHash: fileHash,
            appVersion: appVersion,
            platform: devicePlatform,
          );

          if (session == null) {
            debugError('[DEBUG UPLOAD] FAILED: Could not get upload URL for $chunkName');
            allSucceeded = false;
            break;
          }
          debugLog('[DEBUG UPLOAD] Got upload session: ${session.sessionId}');

          // Step 3: Upload file
          reportChunkProgress('Uploading $chunkName...', 0.4);
          debugLog('[DEBUG UPLOAD] Uploading file...');
          var uploadSuccess = false;
          const maxRetries = 3;

          for (int attempt = 1; attempt <= maxRetries; attempt++) {
            uploadSuccess = await uploadFile(
              uploadUrl: session.uploadUrl,
              file: chunk,
            );

            if (uploadSuccess) {
              debugLog('[DEBUG UPLOAD] File uploaded successfully');
              break;
            }

            if (attempt < maxRetries) {
              final delaySeconds = attempt * 2;
              debugWarn('[DEBUG UPLOAD] Upload attempt $attempt/$maxRetries failed, retrying in ${delaySeconds}s...');
              await Future.delayed(Duration(seconds: delaySeconds));
            }
          }

          if (!uploadSuccess) {
            debugError('[DEBUG UPLOAD] FAILED: Upload failed after $maxRetries attempts for $chunkName');
            allSucceeded = false;
            break;
          }

          // Step 4: Complete upload
          reportChunkProgress('Confirming upload...', 0.8);
          debugLog('[DEBUG UPLOAD] Confirming upload...');
          final completeSuccess = await completeUpload(
            deviceId: deviceId,
            publicKey: publicKey,
            sessionId: session.sessionId,
            success: true,
            userNotes: userNotes ?? 'Direct debug log upload',
          );

          if (!completeSuccess) {
            debugWarn('[DEBUG UPLOAD] Confirmation failed but file was uploaded');
          }

          debugLog('[DEBUG UPLOAD] Chunk ${i + 1}/$totalChunks complete');
        }
      } finally {
        // Clean up temp chunk files
        if (isChunked) {
          debugLog('[DEBUG UPLOAD] Cleaning up $totalChunks temp chunk files');
          await DebugFileLogger.cleanupChunkFiles(chunks);
        }
      }

      if (allSucceeded) {
        onProgress?.call(BugReportProgress(
          status: 'Complete!',
          progress: 1.0,
          currentFile: totalChunks,
          totalFiles: totalChunks,
        ));
        debugLog('[DEBUG UPLOAD] ========================================');
        debugLog('[DEBUG UPLOAD] Upload complete: $filename${isChunked ? ' ($totalChunks chunks)' : ''}');
        debugLog('[DEBUG UPLOAD] ========================================');
      } else {
        debugLog('[DEBUG UPLOAD] ========================================');
        debugLog('[DEBUG UPLOAD] Upload FAILED: $filename');
        debugLog('[DEBUG UPLOAD] ========================================');
      }

      return allSucceeded;
    } catch (e, stackTrace) {
      debugError('[DEBUG UPLOAD] Exception: $e');
      debugError('[DEBUG UPLOAD] Stack trace: $stackTrace');
      return false;
    }
  }

  /// Compute SHA-256 hash of a file
  Future<String> computeFileHash(File file) async {
    final bytes = await file.readAsBytes();
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Get the current device platform string
  static String getDevicePlatform() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  void dispose() {
    _client.close();
  }
}
