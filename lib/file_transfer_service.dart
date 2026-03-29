import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:intl/intl.dart';

class FileTransferService {
  /// Max tasks in queue at any time.
  static const int _maxQueueSize = 30;

  /// Number of concurrent transfer workers.
  static const int _concurrency = 3;

  static const _imageExtensions = {
    '.jpg', '.jpeg', '.png', '.heic', '.heif',
    '.gif', '.bmp', '.tiff', '.webp',
  };
  static const _videoExtensions = {
    '.mp4', '.mov', '.avi', '.mkv', '.wmv', '.flv', '.m4v',
  };

  Timer? _timer;
  final Map<String, int> _previousSizes = {};

  /// Task queue for worker pool
  final List<_TransferTask> _taskQueue = [];
  bool _poolActive = false;
  bool _paused = false;

  /// Tracks paths already queued or transferred to avoid duplicates.
  final Set<String> _transferredPaths = {};
  final Set<String> _queuedPaths = {};

  // --- Callbacks ---

  void Function(String message)? onLog;
  void Function(String sourcePath)? onFileTransferred;
  void Function(String? fileName, double progress)? onTransferProgress;
  void Function(int queueSize)? onQueueStatus;

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
    _paused = false;
    _log('開始監控: $sourcePath');

    _startWorkerPool(
      targetPath: targetPath,
      deleteAfterTransfer: deleteAfterTransfer,
    );

    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      _scan(sourcePath: sourcePath);
    });
  }

  void pause() {
    _paused = true;
    _log('已暫停');
  }

  void resume() {
    _paused = false;
    _log('已恢復');
  }

  bool get isPaused => _paused;

  void _startWorkerPool({
    required String targetPath,
    required bool deleteAfterTransfer,
  }) {
    _stopWorkerPool();
    _poolActive = true;

    for (var i = 0; i < _concurrency; i++) {
      _workerLoop(
        workerId: i + 1,
        targetPath: targetPath,
        deleteAfterTransfer: deleteAfterTransfer,
      );
    }

    _log('已啟動 $_concurrency 個 worker');
  }

  Future<void> _workerLoop({
    required int workerId,
    required String targetPath,
    required bool deleteAfterTransfer,
  }) async {
    while (_poolActive) {
      if (_paused || _taskQueue.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 100));
        continue;
      }

      final task = _taskQueue.removeAt(0);
      onQueueStatus?.call(_taskQueue.length);

      await _transferFile(
        file: task.file,
        targetPath: targetPath,
        deleteAfterTransfer: deleteAfterTransfer,
        workerId: workerId,
      );
    }
  }

  void _stopWorkerPool() {
    _poolActive = false;
    _taskQueue.clear();
    _queuedPaths.clear();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _stopWorkerPool();
    _previousSizes.clear();
    _paused = false;
  }

  bool get isRunning => _timer != null;

  List<String> get transferredPaths => _transferredPaths.toList();

  void clearTransferredPaths() {
    _transferredPaths.clear();
  }

  Future<void> _scan({required String sourcePath}) async {
    if (_paused) return;
    if (_taskQueue.length >= _maxQueueSize) return;

    final sourceDir = Directory(sourcePath);
    if (!await sourceDir.exists()) return;

    final currentFiles = <String, int>{};

    try {
      await for (final entity in sourceDir.list()) {
        if (entity is! File) continue;
        if (!_isSupportedFile(entity.path)) continue;

        final fileName = p.basename(entity.path);
        if (fileName.startsWith('.')) continue;
        if (_transferredPaths.contains(entity.path)) continue;
        if (_queuedPaths.contains(entity.path)) continue;

        try {
          final size = await entity.length();
          currentFiles[entity.path] = size;

          if (size > 0 &&
              _previousSizes.containsKey(entity.path) &&
              _previousSizes[entity.path] == size) {
            // File is ready — enqueue if queue not full
            if (_taskQueue.length < _maxQueueSize) {
              _taskQueue.add(_TransferTask(entity));
              _queuedPaths.add(entity.path);
              onQueueStatus?.call(_taskQueue.length);
            } else {
              break; // Queue full, stop adding
            }
          }
        } catch (_) {}
      }
    } catch (e) {
      _log('掃描錯誤: $e');
    }

    _previousSizes.clear();
    _previousSizes.addAll(currentFiles);
  }

  Future<void> _transferFile({
    required File file,
    required String targetPath,
    required bool deleteAfterTransfer,
    required int workerId,
  }) async {
    final fileName = p.basename(file.path);
    try {
      final lastModified = await file.lastModified();

      onTransferProgress?.call(fileName, 0.0);

      final yearStr = DateFormat('yyyy').format(lastModified);
      final monthStr = DateFormat('MM').format(lastModified);
      final destDir = p.join(targetPath, yearStr, monthStr);

      final destDirectory = Directory(destDir);
      if (!await destDirectory.exists()) {
        await destDirectory.create(recursive: true);
      }

      final sourceSize = await file.length();
      var destPath = p.join(destDir, fileName);
      var destFile = File(destPath);

      // Duplicate detection
      if (await destFile.exists()) {
        final existingSize = await destFile.length();
        if (existingSize == sourceSize) {
          _transferredPaths.add(file.path);
          _queuedPaths.remove(file.path);
          onFileTransferred?.call(file.path);
          onTransferProgress?.call(null, 0.0);
          if (deleteAfterTransfer) {
            await file.delete();
            _log('[W$workerId] 跳過 (已有相同檔案) 並刪除來源: $fileName');
          } else {
            _log('[W$workerId] 跳過 (目的地已有相同檔案): $fileName');
          }
          return;
        }
        final baseName = p.basenameWithoutExtension(fileName);
        final ext = p.extension(fileName);
        var counter = 1;
        do {
          destPath = p.join(destDir, '${baseName}_$counter$ext');
          destFile = File(destPath);
          counter++;
        } while (await destFile.exists());
        _log('[W$workerId] 同名但大小不同，重新命名: $fileName -> ${p.basename(destPath)}');
      }

      // Chunked copy
      try {
        final input = file.openRead();
        final output = destFile.openWrite();
        int bytesTransferred = 0;

        await for (final chunk in input) {
          output.add(chunk);
          bytesTransferred += chunk.length;
          final progress = sourceSize > 0 ? bytesTransferred / sourceSize : 0.0;
          onTransferProgress?.call(fileName, progress);
        }

        await output.close();
      } catch (e) {
        if (await destFile.exists()) await destFile.delete();
        _log('[W$workerId] 寫入失敗 $fileName: $e');
        onTransferProgress?.call(null, 0.0);
        _queuedPaths.remove(file.path);
        return;
      }

      // Verify
      final destSize = await destFile.length();
      if (destSize != sourceSize) {
        _log('[W$workerId] 驗證失敗，大小不符: $fileName (來源: $sourceSize, 目標: $destSize)');
        if (await destFile.exists()) await destFile.delete();
        onTransferProgress?.call(null, 0.0);
        _queuedPaths.remove(file.path);
        return;
      }

      _transferredPaths.add(file.path);
      _queuedPaths.remove(file.path);
      onFileTransferred?.call(file.path);
      onTransferProgress?.call(null, 0.0);

      if (deleteAfterTransfer) {
        await file.delete();
        _log('[W$workerId] 已轉移並刪除: $fileName -> $yearStr/$monthStr/');
      } else {
        _log('[W$workerId] 已轉移: $fileName -> $yearStr/$monthStr/');
      }
    } catch (e) {
      _log('[W$workerId] 轉移失敗 $fileName: $e');
      onTransferProgress?.call(null, 0.0);
      _queuedPaths.remove(file.path);
    }
  }

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

class _TransferTask {
  final File file;
  _TransferTask(this.file);
}
