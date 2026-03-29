import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'transfer_provider.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sourcePath = ref.watch(sourcePathProvider);
    final targetPath = ref.watch(targetPathProvider);
    final deleteAfterTransfer = ref.watch(deleteAfterTransferProvider);
    final isMonitoring = ref.watch(monitoringProvider);
    final logs = ref.watch(transferLogsProvider);
    final transferCount = ref.watch(transferCountProvider);
    final transferredFiles = ref.watch(transferredFilesProvider);

    // Check path existence for UI indicators
    final sourceExists =
        sourcePath != null && Directory(sourcePath).existsSync();
    final targetExists =
        targetPath != null && Directory(targetPath).existsSync();

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '照片檔案搬移工具',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              '自動監控來源資料夾，將圖片與影片依年/月分類轉移至目標資料夾',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),

            // Source folder
            _FolderSelector(
              label: '來源資料夾',
              path: sourcePath,
              pathExists: sourceExists,
              enabled: !isMonitoring,
              onSelect: () => _pickFolder(context, ref, isSource: true),
            ),
            const SizedBox(height: 12),

            // Target folder
            _FolderSelector(
              label: '目標資料夾',
              path: targetPath,
              pathExists: targetExists,
              enabled: !isMonitoring,
              onSelect: () => _pickFolder(context, ref, isSource: false),
            ),
            const SizedBox(height: 20),

            // Toggle and button row
            Row(
              children: [
                Switch(
                  value: deleteAfterTransfer,
                  onChanged: isMonitoring
                      ? null
                      : (val) {
                          ref.read(deleteAfterTransferProvider.notifier).value =
                              val;
                        },
                ),
                const SizedBox(width: 8),
                Text(
                  '轉移成功後刪除來源檔案',
                  style: TextStyle(color: isMonitoring ? Colors.grey : null),
                ),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: (sourcePath != null && targetPath != null)
                      ? () => _toggleMonitoring(context, ref)
                      : null,
                  icon: Icon(isMonitoring ? Icons.stop : Icons.play_arrow),
                  label: Text(isMonitoring ? '停止監控' : '開始監控'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isMonitoring ? Colors.red : Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                  ),
                ),
              ],
            ),

            // Status row: monitoring indicator + transfer count + delete button
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  if (isMonitoring) ...[
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.green.shade600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '監控中... 每 5 秒掃描一次',
                      style: TextStyle(
                        color: Colors.green.shade700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  if (!isMonitoring && transferCount == 0)
                    Text(
                      '尚未開始',
                      style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 13,
                      ),
                    ),
                  const Spacer(),

                  // Transfer count badge
                  if (transferCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.blue.shade200),
                      ),
                      child: Text(
                        '已轉移 $transferCount 個檔案',
                        style: TextStyle(
                          color: Colors.blue.shade700,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),

                  // One-click delete button for transferred source files
                  if (transferredFiles.isNotEmpty && !deleteAfterTransfer) ...[
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: () => _deleteTransferredSources(context, ref),
                      icon: Icon(
                        Icons.delete_sweep,
                        size: 18,
                        color: Colors.red.shade600,
                      ),
                      label: Text(
                        '刪除來源 (${transferredFiles.length})',
                        style: TextStyle(
                          color: Colors.red.shade600,
                          fontSize: 13,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.red.shade300),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // Batch & file transfer progress — always visible
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Consumer(
                builder: (context, ref, child) {
                  final batch = ref.watch(batchProgressProvider);
                  final fileProgress = ref.watch(transferProgressProvider);
                  final totalTransferred = ref.watch(transferCountProvider);

                  final hasFileInProgress = fileProgress.isTransferring;
                  final batchLabel = batch.batchTotal > 0
                      ? '批次進度: ${batch.batchDone}/${batch.batchTotal}'
                          '${batch.totalFound > batch.batchTotal ? '  (待處理共 ${batch.totalFound} 個)' : ''}'
                      : '等待檔案...';

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Batch progress row
                      Row(
                        children: [
                          Text(
                            batchLabel,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: batch.isActive
                                  ? Colors.blue.shade700
                                  : Colors.grey.shade600,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '累計已轉移: $totalTransferred',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Batch progress bar
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: batch.batchProgress,
                          minHeight: 6,
                          backgroundColor: Colors.grey.shade200,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            batch.isActive
                                ? Colors.blue.shade600
                                : Colors.grey.shade400,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Current file name
                      Row(
                        children: [
                          if (hasFileInProgress) ...[
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.blue.shade400,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${fileProgress.fileName}  ${(fileProgress.progress * 100).toStringAsFixed(0)}%',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade700,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ] else
                            Text(
                              '閒置中',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade500,
                              ),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),

            const SizedBox(height: 16),

            // Log section
            Row(
              children: [
                const Text(
                  '轉移日誌',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                TextButton(
                  onPressed: logs.isEmpty
                      ? null
                      : () => ref.read(transferLogsProvider.notifier).clear(),
                  child: const Text('清除'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: logs.isEmpty
                    ? const Center(
                        child: Text(
                          '尚無日誌',
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: logs.length,
                        itemBuilder: (context, index) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              logs[index],
                              style: const TextStyle(
                                fontSize: 13,
                                fontFamily: 'monospace',
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFolder(
    BuildContext context,
    WidgetRef ref, {
    required bool isSource,
  }) async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: isSource ? '選擇來源資料夾' : '選擇目標資料夾',
    );
    if (result == null) return;

    if (!Directory(result).existsSync()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('所選路徑不存在: $result'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    if (isSource) {
      ref.read(sourcePathProvider.notifier).value = result;
    } else {
      ref.read(targetPathProvider.notifier).value = result;
    }
  }

  void _toggleMonitoring(BuildContext context, WidgetRef ref) {
    final isMonitoring = ref.read(monitoringProvider);
    final service = ref.read(fileTransferServiceProvider);

    if (isMonitoring) {
      service.stop();
      ref.read(monitoringProvider.notifier).state = false;
      ref.read(transferLogsProvider.notifier).add('[${_timeNow()}] 已停止監控');
      return;
    }

    final source = ref.read(sourcePathProvider);
    final target = ref.read(targetPathProvider);

    final sourceError = validatePath(source, '來源資料夾');
    if (sourceError != null) {
      _showError(context, sourceError);
      ref.read(sourcePathProvider.notifier).value = null;
      return;
    }

    final targetError = validatePath(target, '目標資料夾');
    if (targetError != null) {
      _showError(context, targetError);
      ref.read(targetPathProvider.notifier).value = null;
      return;
    }

    final deleteAfter = ref.read(deleteAfterTransferProvider);

    service.start(
      sourcePath: source!,
      targetPath: target!,
      deleteAfterTransfer: deleteAfter,
    );
    ref.read(monitoringProvider.notifier).state = true;
  }

  Future<void> _deleteTransferredSources(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final transferredFiles = ref.read(transferredFilesProvider);
    if (transferredFiles.isEmpty) return;

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('確認刪除'),
        content: Text('確定要刪除 ${transferredFiles.length} 個已轉移的來源檔案嗎？\n此操作無法復原。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('刪除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final service = ref.read(fileTransferServiceProvider);
    final paths = List<String>.from(transferredFiles);
    final deleted = await service.deleteFiles(paths);

    // Clear the transferred files list
    ref.read(transferredFilesProvider.notifier).clear();
    service.clearTransferredPaths();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已刪除 $deleted 個來源檔案'),
          backgroundColor: Colors.green.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showError(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _timeNow() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
  }
}

class _FolderSelector extends StatelessWidget {
  final String label;
  final String? path;
  final bool pathExists;
  final bool enabled;
  final VoidCallback onSelect;

  const _FolderSelector({
    required this.label,
    required this.path,
    required this.pathExists,
    required this.enabled,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final hasPath = path != null;
    final isInvalid = hasPath && !pathExists;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 100,
              child: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: isInvalid ? Colors.red.shade50 : Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isInvalid
                        ? Colors.red.shade300
                        : Colors.grey.shade300,
                  ),
                ),
                child: Row(
                  children: [
                    if (hasPath && pathExists)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Icon(
                          Icons.check_circle,
                          size: 16,
                          color: Colors.green.shade600,
                        ),
                      ),
                    if (isInvalid)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Icon(
                          Icons.error,
                          size: 16,
                          color: Colors.red.shade600,
                        ),
                      ),
                    Expanded(
                      child: Text(
                        path ?? '尚未選擇',
                        style: TextStyle(
                          color: isInvalid
                              ? Colors.red.shade700
                              : (hasPath ? Colors.black87 : Colors.grey),
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: enabled ? onSelect : null,
              child: const Text('選擇'),
            ),
          ],
        ),
        if (isInvalid)
          Padding(
            padding: const EdgeInsets.only(left: 100, top: 4),
            child: Text(
              '路徑不存在，請重新選擇',
              style: TextStyle(color: Colors.red.shade600, fontSize: 12),
            ),
          ),
      ],
    );
  }
}
