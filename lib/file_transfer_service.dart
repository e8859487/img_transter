import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:intl/intl.dart';

class FileTransferService {
  /// Maximum number of files to transfer per scan cycle.
  static const int _batchSize = 30;

  /// Number of concurrent transfer workers.
  static const int _concurrency = 3;

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

  /// Task queue for worker pool
  final List<_TransferTask> _taskQueue = [];
  Completer<void>? _batchCompleter;
  int _pendingTasks = 0;
  int _batchTotal = 0;
  int _batchDone = 0;
  int _totalFound = 0;
  bool _poolActive = false;

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

  /// Callback for batch progress updates.
  /// Parameters: batchTotal, batchDone, totalFound
  void Function(int batchTotal, int batchDone, int totalFound)? onBatchProgress;

  bool _isSupportedFile(String path) {
    final ext = p.extension(path).toLowerCase();
    return _imageExtensions.contains(ext) || _videoExtensions.contains(ext);
  }

  void start({
    required String sourcePath,
    required String targetPath,
    required bool deleteAfterTransfer,
    Duration scanInterval = const Duration(seconds: 5),
  }) {
    stop();
    _previousSizes.clear();
    _log('開始監控: $sourcePath');

    // Start worker pool
    _startWorkerPool(
      targetPath: targetPath,
      deleteAfterTransfer: deleteAfterTransfer,
    );

    _timer = Timer.periodic(scanInterval, (_) {
      _scan(sourcePath: sourcePath);
    });
  }

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

  /// Each worker pulls tasks from the shared queue.
  /// When the queue is empty, the worker waits for _batchCompleter to be
  /// replaced (next batch) via a polling micro-delay.
  Future<void> _workerLoop({
    required int workerId,
    required String targetPath,
    required bool deleteAfterTransfer,
  }) async {
    while (_poolActive) {
      // Try to grab a task from the queue
      final task = _taskQueue.isNotEmpty ? _taskQueue.removeAt(0) : null;
      if (task == null) {
        // No work available — yield and wait briefly
        await Future.delayed(const Duration(milliseconds: 50));
        continue;
      }

      await _transferFile(
        file: task.file,
        targetPath: targetPath,
        deleteAfterTransfer: deleteAfterTransfer,
        workerId: workerId,
      );

      _pendingTasks--;
      _batchDone++;
      onBatchProgress?.call(_batchTotal, _batchDone, _totalFound);
      if (_pendingTasks <= 0 && _batchCompleter != null && !_batchCompleter!.isCompleted) {
        _batchCompleter!.complete();
      }
    }
  }

  void _stopWorkerPool() {
    _poolActive = false;
    _taskQueue.clear();
    _batchCompleter = null;
    _pendingTasks = 0;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _stopWorkerPool();
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

        final fileName = p.basename(entity.path);
        if (fileName.startsWith('.')) continue;
        if (_transferredPaths.contains(entity.path)) continue;

        try {
          final size = await entity.length();
          final path = entity.path;
          currentFiles[path] = size;

          if (size > 0 &&
              _previousSizes.containsKey(path) &&
              _previousSizes[path] == size) {
            readyFiles.add(entity);
          }
        } catch (e) {
          // File might be locked/in-use, skip
        }
      }

      // Dispatch batch to worker pool
      final batch = readyFiles.take(_batchSize).toList();
      if (batch.isNotEmpty) {
        if (batch.length < readyFiles.length) {
          _log('發現 ${readyFiles.length} 個檔案，本批次處理 ${batch.length} 個');
        }
        _log('派發 ${batch.length} 個檔案至 $_concurrency 個 worker');

        _totalFound = readyFiles.length;
        _batchTotal = batch.length;
        _batchDone = 0;
        _pendingTasks = batch.length;
        _batchCompleter = Completer<void>();
        onBatchProgress?.call(_batchTotal, _batchDone, _totalFound);

        for (final file in batch) {
          _taskQueue.add(_TransferTask(file));
          currentFiles.remove(file.path);
        }

        // Wait for all tasks in this batch to complete before next scan
        await _batchCompleter!.future;
      }

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

      // Check for existing file with same name
      if (await destFile.exists()) {
        final existingSize = await destFile.length();
        if (existingSize == sourceSize) {
          _transferredPaths.add(file.path);
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
        // Different size — rename with suffix
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
        if (await destFile.exists()) {
          await destFile.delete();
        }
        _log('[W$workerId] 寫入失敗 $fileName: $e');
        onTransferProgress?.call(null, 0.0);
        return;
      }

      final destSize = await destFile.length();

      if (destSize != sourceSize) {
        _log('[W$workerId] 驗證失敗，大小不符: $fileName (來源: $sourceSize, 目標: $destSize)');
        if (await destFile.exists()) {
          await destFile.delete();
        }
        onTransferProgress?.call(null, 0.0);
        return;
      }

      _transferredPaths.add(file.path);
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

class _TransferTask {
  final File file;
  _TransferTask(this.file);
}
