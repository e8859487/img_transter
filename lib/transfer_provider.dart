import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'file_transfer_service.dart';

// Keys for SharedPreferences
const _keySourcePath = 'source_path';
const _keyTargetPath = 'target_path';
const _keyDeleteAfterTransfer = 'delete_after_transfer';

// SharedPreferences instance provider
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('Must be overridden in ProviderScope');
});

// Source path - auto saves to disk
final sourcePathProvider =
    StateNotifierProvider<_PersistentStringNotifier, String?>((ref) {
      final prefs = ref.watch(sharedPreferencesProvider);
      return _PersistentStringNotifier(prefs, _keySourcePath);
    });

// Target path - auto saves to disk
final targetPathProvider =
    StateNotifierProvider<_PersistentStringNotifier, String?>((ref) {
      final prefs = ref.watch(sharedPreferencesProvider);
      return _PersistentStringNotifier(prefs, _keyTargetPath);
    });

// Delete after transfer toggle - auto saves to disk
final deleteAfterTransferProvider =
    StateNotifierProvider<_PersistentBoolNotifier, bool>((ref) {
      final prefs = ref.watch(sharedPreferencesProvider);
      return _PersistentBoolNotifier(prefs, _keyDeleteAfterTransfer);
    });

final monitoringProvider = StateProvider<bool>((ref) => false);

// --- Transfer counter & transferred files tracking ---

/// Tracks the count of files transferred in this session
final transferCountProvider = StateProvider<int>((ref) => 0);

/// Tracks the list of source file paths that were successfully transferred
/// (for the "one-click delete" feature)
class TransferredFilesNotifier extends StateNotifier<List<String>> {
  TransferredFilesNotifier() : super([]);

  void add(String path) {
    state = [...state, path];
  }

  void clear() {
    state = [];
  }

  void removeAll(List<String> paths) {
    final toRemove = paths.toSet();
    state = state.where((p) => !toRemove.contains(p)).toList();
  }
}

final transferredFilesProvider =
    StateNotifierProvider<TransferredFilesNotifier, List<String>>(
      (ref) => TransferredFilesNotifier(),
    );

// --- Transfer progress tracking ---

/// Data class for tracking current file transfer progress
class TransferProgress {
  final String? fileName;
  final double progress; // 0.0 to 1.0

  const TransferProgress({this.fileName, this.progress = 0.0});

  bool get isTransferring => fileName != null && progress > 0.0;
}

class TransferProgressNotifier extends StateNotifier<TransferProgress> {
  TransferProgressNotifier() : super(const TransferProgress());

  void update(String? fileName, double progress) {
    state = TransferProgress(fileName: fileName, progress: progress);
  }

  void clear() {
    state = const TransferProgress();
  }
}

final transferProgressProvider =
    StateNotifierProvider<TransferProgressNotifier, TransferProgress>(
      (ref) => TransferProgressNotifier(),
    );

// --- Batch progress tracking ---

class BatchProgress {
  final int batchTotal;
  final int batchDone;
  final int totalFound;

  const BatchProgress({
    this.batchTotal = 0,
    this.batchDone = 0,
    this.totalFound = 0,
  });

  double get batchProgress =>
      batchTotal > 0 ? batchDone / batchTotal : 0.0;

  bool get isActive => batchTotal > 0 && batchDone < batchTotal;
}

class BatchProgressNotifier extends StateNotifier<BatchProgress> {
  BatchProgressNotifier() : super(const BatchProgress());

  void update(int batchTotal, int batchDone, int totalFound) {
    state = BatchProgress(
      batchTotal: batchTotal,
      batchDone: batchDone,
      totalFound: totalFound,
    );
  }
}

final batchProgressProvider =
    StateNotifierProvider<BatchProgressNotifier, BatchProgress>(
      (ref) => BatchProgressNotifier(),
    );

// --- Persistent notifiers ---

class _PersistentStringNotifier extends StateNotifier<String?> {
  final SharedPreferences _prefs;
  final String _key;

  _PersistentStringNotifier(this._prefs, this._key)
    : super(_loadAndValidate(_prefs, _key));

  /// Load saved value, but only if the directory still exists
  static String? _loadAndValidate(SharedPreferences prefs, String key) {
    final saved = prefs.getString(key);
    if (saved == null) return null;
    if (Directory(saved).existsSync()) return saved;
    // Path no longer exists, clear it
    prefs.remove(key);
    return null;
  }

  set value(String? newValue) {
    state = newValue;
    if (newValue != null) {
      _prefs.setString(_key, newValue);
    } else {
      _prefs.remove(_key);
    }
  }
}

class _PersistentBoolNotifier extends StateNotifier<bool> {
  final SharedPreferences _prefs;
  final String _key;

  _PersistentBoolNotifier(this._prefs, this._key)
    : super(_prefs.getBool(_key) ?? false);

  set value(bool newValue) {
    state = newValue;
    _prefs.setBool(_key, newValue);
  }
}

// --- Log notifier ---

class LogNotifier extends StateNotifier<List<String>> {
  LogNotifier() : super([]);

  void add(String log) {
    state = [log, ...state];
    if (state.length > 200) {
      state = state.sublist(0, 200);
    }
  }

  void clear() {
    state = [];
  }
}

final transferLogsProvider = StateNotifierProvider<LogNotifier, List<String>>(
  (ref) => LogNotifier(),
);

// --- File transfer service ---

final fileTransferServiceProvider = Provider<FileTransferService>((ref) {
  final service = FileTransferService();

  service.onLog = (message) {
    ref.read(transferLogsProvider.notifier).add(message);
  };

  service.onFileTransferred = (sourcePath) {
    ref.read(transferCountProvider.notifier).state++;
    ref.read(transferredFilesProvider.notifier).add(sourcePath);
  };

  service.onTransferProgress = (fileName, progress) {
    ref.read(transferProgressProvider.notifier).update(fileName, progress);
  };

  service.onBatchProgress = (batchTotal, batchDone, totalFound) {
    ref.read(batchProgressProvider.notifier).update(
      batchTotal, batchDone, totalFound,
    );
  };

  ref.onDispose(() {
    service.dispose();
  });

  return service;
});

// --- Path validation helper ---

/// Returns null if valid, or an error message string if invalid
String? validatePath(String? path, String label) {
  if (path == null || path.isEmpty) {
    return '$label 尚未設定';
  }
  if (!Directory(path).existsSync()) {
    return '$label 不存在: $path';
  }
  return null;
}
