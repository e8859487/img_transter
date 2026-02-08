import 'dart:io';
// Let's use relative import for safety as we don't know the package import name for sure from previous context, but likely 'iphone_img_transfer'.
// Checking pubspec.yaml confirms package name is 'iphone_img_transfer'.
import 'package:iphone_img_transfer/file_transfer_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('FileTransferService Tests', () {
    late FileTransferService service;
    late Directory tempDir;
    late String sourcePath;
    late String targetPath;

    setUp(() async {
      service = FileTransferService();
      tempDir = await Directory.systemTemp.createTemp('transfer_test_');
      sourcePath = p.join(tempDir.path, 'source');
      targetPath = p.join(tempDir.path, 'target');
      await Directory(sourcePath).create();
      await Directory(targetPath).create();
    });

    tearDown(() async {
      service.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'Critical Test 1: Supported files are transferred, unsupported ignored',
      () async {
        // Create test files
        final jpgFile = File(p.join(sourcePath, 'test.jpg'));
        await jpgFile.writeAsString('dummy content');
        // Set last modified to ensure consistent target folder if needed (default is now)

        final txtFile = File(p.join(sourcePath, 'test.txt'));
        await txtFile.writeAsString('dummy content');

        final hiddenFile = File(p.join(sourcePath, '.hidden.jpg'));
        await hiddenFile.writeAsString('dummy content');

        final transferredFiles = <String>[];
        service.onFileTransferred = (path) {
          transferredFiles.add(p.basename(path));
        };

        // Start service with short interval
        service.start(
          sourcePath: sourcePath,
          targetPath: targetPath,
          deleteAfterTransfer: false,
          scanInterval: const Duration(milliseconds: 100),
        );

        // Wait for scan cycles (need 2 cycles usually because of size check logic on first scan?)
        // The logic says: "File is ready if size > 0 and matches previous scan"
        // So yes, it needs at least 2 scans.
        await Future.delayed(const Duration(milliseconds: 500));

        expect(transferredFiles, contains('test.jpg'));
        expect(transferredFiles, isNot(contains('test.txt')));
        expect(transferredFiles, isNot(contains('.hidden.jpg')));
      },
    );

    test(
      'Critical Test 2: Files are organized by Year/Month and verification passes',
      () async {
        final file = File(p.join(sourcePath, 'dated.jpg'));
        await file.writeAsString('content');

        // Set a specific date: 2023-05-15
        // Dart's setLastModified is reliable on most platforms.
        final date = DateTime(2023, 5, 15);
        await file.setLastModified(date);

        service.start(
          sourcePath: sourcePath,
          targetPath: targetPath,
          deleteAfterTransfer: false, // Keep source
          scanInterval: const Duration(milliseconds: 100),
        );

        await Future.delayed(const Duration(milliseconds: 500));

        final expectedPath = p.join(targetPath, '2023', '05', 'dated.jpg');
        expect(File(expectedPath).existsSync(), isTrue);
        expect(File(file.path).existsSync(), isTrue); // Source remains
      },
    );

    test('Critical Test 3: Delete after transfer works correctly', () async {
      final file = File(p.join(sourcePath, 'todelete.jpg'));
      await file.writeAsString('content');

      service.start(
        sourcePath: sourcePath,
        targetPath: targetPath,
        deleteAfterTransfer: true, // Delete source
        scanInterval: const Duration(milliseconds: 100),
      );

      await Future.delayed(const Duration(milliseconds: 500));

      // Check target exists
      // Actually let's just check if source is gone.
      expect(
        file.existsSync(),
        isFalse,
        reason: 'Source file should be deleted',
      );

      // Verify it exists somewhere in target
      final targetDir = Directory(targetPath);
      final entities = targetDir.listSync(recursive: true);
      final movedFile = entities.firstWhere(
        (e) => p.basename(e.path) == 'todelete.jpg',
        orElse: () => File('not_found'),
      );
      expect(
        movedFile.existsSync(),
        isTrue,
        reason: 'File should exist in target',
      );
    });
  });
}
