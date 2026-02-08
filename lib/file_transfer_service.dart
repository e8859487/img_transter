import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:intl/intl.dart';

class FileTransferService {
  static const _imageExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.heic',
    '.heif',
    '.gif',
    '.bmp',
    '.tiff',
    '.webp',
  };
  static const _videoExtensions = {
    '.mp4',
    '.mov',
    '.avi',
    '.mkv',
    '.wmv',
    '.flv',
    '.m4v',
  };

  Timer? _timer;
  final Map<String, int> _previousSizes = {};
  bool _isProcessing = false;

  /// Set of source file paths that have been successfully transferred this session.
  /// Used to avoid re-processing the same file.
  final Set<String> _transferredPaths = {};

  /// Callback for log messages
  void Function(String message)? onLog;

  /// Callback when a file is successfully transferred.
  /// Parameters: sourcePath of the transferred file
  void Function(String sourcePath)? onFileTransferred;

  /// Callback for transfer progress updates.
  /// Parameters: fileName, progress (0.0 to 1.0)
  void Function(String? fileName, double progress)? onTransferProgress;

  bool _isSupportedFile(String path) {
    final ext = p.extension(path).toLowerCase();
    return _imageExtensions.contains(ext) || _videoExtensions.contains(ext);
  }

  void start({
    required String sourcePath,
    required String targetPath,
    required bool deleteAfterTransfer,
  }) {
    stop();
    _previousSizes.clear();
    // Don't clear _transferredPaths here — we keep the session history
    // so re-starting monitoring won't re-process already transferred files.
    _log('開始監控: $sourcePath');

    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      _scan(
        sourcePath: sourcePath,
        targetPath: targetPath,
        deleteAfterTransfer: deleteAfterTransfer,
      );
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _previousSizes.clear();
  }

  bool get isRunning => _timer != null;

  /// Get list of transferred source paths (for one-click delete)
  List<String> get transferredPaths => _transferredPaths.toList();

  /// Clear the transferred paths record (after deletion)
  void clearTransferredPaths() {
    _transferredPaths.clear();
  }

  Future<void> _scan({
    required String sourcePath,
    required String targetPath,
    required bool deleteAfterTransfer,
  }) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final sourceDir = Directory(sourcePath);
      if (!await sourceDir.exists()) {
        _log('來源資料夾不存在: $sourcePath');
        _isProcessing = false;
        return;
      }

      final currentFiles = <String, int>{};
      final readyFiles = <File>[];

      await for (final entity in sourceDir.list()) {
        if (entity is! File) continue;
        if (!_isSupportedFile(entity.path)) continue;

        // Skip hidden/temp files (macOS sometimes creates ._ files)
        final fileName = p.basename(entity.path);
        if (fileName.startsWith('.')) continue;

        // Skip already transferred files
        if (_transferredPaths.contains(entity.path)) continue;

        try {
          final size = await entity.length();
          final path = entity.path;
          currentFiles[path] = size;

          // File is ready if size > 0 and matches previous scan
          if (size > 0 &&
              _previousSizes.containsKey(path) &&
              _previousSizes[path] == size) {
            readyFiles.add(entity);
          }
        } catch (e) {
          // File might be locked/in-use, skip
        }
      }

      // Transfer ready files
      for (final file in readyFiles) {
        await _transferFile(
          file: file,
          targetPath: targetPath,
          deleteAfterTransfer: deleteAfterTransfer,
        );
        currentFiles.remove(file.path);
      }

      // Update tracked sizes for next scan
      _previousSizes.clear();
      _previousSizes.addAll(currentFiles);
    } catch (e) {
      _log('掃描錯誤: $e');
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _transferFile({
    required File file,
    required String targetPath,
    required bool deleteAfterTransfer,
  }) async {
    try {
      final fileName = p.basename(file.path);
      final lastModified = await file.lastModified();

      // Notify start of transfer
      onTransferProgress?.call(fileName, 0.0);

      // Build target directory: targetPath/YYYY/MM
      final yearStr = DateFormat('yyyy').format(lastModified);
      final monthStr = DateFormat('MM').format(lastModified);

      final destDir = p.join(targetPath, yearStr, monthStr);

      final destDirectory = Directory(destDir);
      if (!await destDirectory.exists()) {
        await destDirectory.create(recursive: true);
      }

      final destPath = p.join(destDir, fileName);
      final sourceSize = await file.length();

      // Use chunked copy for progress tracking
      final destFile = File(destPath);
      try {
        final input = file.openRead();
        final output = destFile.openWrite();

        int bytesTransferred = 0;

        await for (final chunk in input) {
          output.add(chunk);
          bytesTransferred += chunk.length;

          // Report progress
          final progress = sourceSize > 0 ? bytesTransferred / sourceSize : 0.0;
          onTransferProgress?.call(fileName, progress);
        }

        await output.close();
      } catch (e) {
        if (await destFile.exists()) {
          await destFile.delete();
        }
        _log('寫入失敗 $fileName: $e');
        onTransferProgress?.call(null, 0.0); // Clear progress
        return;
      }

      // Verify copied file size matches
      final destSize = await destFile.length();

      if (destSize != sourceSize) {
        _log('驗證失敗，大小不符: $fileName (來源: $sourceSize, 目標: $destSize)');
        if (await destFile.exists()) {
          await destFile.delete();
        }
        onTransferProgress?.call(null, 0.0); // Clear progress
        return;
      }

      // Mark as transferred — won't be processed again this session
      _transferredPaths.add(file.path);

      // Notify callback
      onFileTransferred?.call(file.path);

      // Clear progress indicator
      onTransferProgress?.call(null, 0.0);

      if (deleteAfterTransfer) {
        await file.delete();
        _log('已轉移並刪除: $fileName -> $yearStr/$monthStr/');
      } else {
        _log('已轉移: $fileName -> $yearStr/$monthStr/');
      }
    } catch (e) {
      _log('轉移失敗 ${p.basename(file.path)}: $e');
      onTransferProgress?.call(null, 0.0); // Clear progress
    }
  }

  /// Delete a list of source files. Returns count of successfully deleted files.
  Future<int> deleteFiles(List<String> paths) async {
    int deleted = 0;
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
          deleted++;
          _log('已刪除來源: ${p.basename(path)}');
        } else {
          // File already gone, still count it
          deleted++;
        }
      } catch (e) {
        _log('刪除失敗 ${p.basename(path)}: $e');
      }
    }
    return deleted;
  }

  void _log(String message) {
    final time = DateFormat('HH:mm:ss').format(DateTime.now());
    onLog?.call('[$time] $message');
  }

  void dispose() {
    stop();
  }
}
