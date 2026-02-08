import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_img_transfer/file_transfer_service.dart';
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

    // --- Feature 1: Auto Monitoring ---
    group('Feature 1: Auto Monitoring', () {
      test(
        '1.1: Detects and transfers new files created after start',
        () async {
          service.start(
            sourcePath: sourcePath,
            targetPath: targetPath,
            deleteAfterTransfer: false,
            scanInterval: const Duration(milliseconds: 100),
          );

          await Future.delayed(
            const Duration(milliseconds: 200),
          ); // First scan empty

          // Create file
          final file = File(p.join(sourcePath, 'new.jpg'));
          await file.writeAsString('content');

          await Future.delayed(
            const Duration(milliseconds: 300),
          ); // Allow scan to pick it up

          expect(
            File(p.join(targetPath, _year(), _month(), 'new.jpg')).existsSync(),
            isTrue,
          );
        },
      );
    });

    // --- Feature 2: Smart Classification ---
    group('Feature 2: Smart Classification', () {
      test(
        '2.1: Organizes files by Year/Month based on modification time',
        () async {
          final file = File(p.join(sourcePath, 'old.jpg'));
          await file.writeAsString('content');
          // Set date to 2022-11-15
          await file.setLastModified(DateTime(2022, 11, 15));

          service.start(
            sourcePath: sourcePath,
            targetPath: targetPath,
            deleteAfterTransfer: false,
            scanInterval: const Duration(milliseconds: 50),
          );
          await Future.delayed(const Duration(milliseconds: 400));

          expect(
            File(p.join(targetPath, '2022', '11', 'old.jpg')).existsSync(),
            isTrue,
          );
        },
      );
    });

    // --- Feature 3: Flexible Deletion ---
    group('Feature 3: Flexible Deletion', () {
      test('3.1: Deletes source file if deleteAfterTransfer is true', () async {
        final file = File(p.join(sourcePath, 'del.jpg'));
        await file.writeAsString('content');

        service.start(
          sourcePath: sourcePath,
          targetPath: targetPath,
          deleteAfterTransfer: true,
          scanInterval: const Duration(milliseconds: 50),
        );
        await Future.delayed(const Duration(milliseconds: 400));

        // Source should be gone
        expect(file.existsSync(), isFalse);
        // Target should exist
        expect(
          File(p.join(targetPath, _year(), _month(), 'del.jpg')).existsSync(),
          isTrue,
        );
      });

      test(
        '3.2: deleteFiles (One-click delete) removes multiple source files',
        () async {
          // Create files manually
          final f1 = File(p.join(sourcePath, 'f1.jpg'));
          final f2 = File(p.join(sourcePath, 'f2.jpg'));
          await f1.writeAsString('c1');
          await f2.writeAsString('c2');

          final count = await service.deleteFiles([f1.path, f2.path]);

          expect(count, equals(2));
          expect(f1.existsSync(), isFalse);
          expect(f2.existsSync(), isFalse);
        },
      );
    });

    // --- Feature 4: Progress Reporting ---
    group('Feature 4: Progress Reporting', () {
      test('4.1: onTransferProgress reports filename and progress', () async {
        final file = File(p.join(sourcePath, 'prog.jpg'));
        await file.writeAsString('content' * 100);

        final progressUpdates = <double>[];
        String? reportedName;

        service.onTransferProgress = (name, progress) {
          if (name != null) reportedName = name;
          progressUpdates.add(progress);
        };

        service.start(
          sourcePath: sourcePath,
          targetPath: targetPath,
          deleteAfterTransfer: false,
          scanInterval: const Duration(milliseconds: 50),
        );
        await Future.delayed(const Duration(milliseconds: 400));

        expect(reportedName, equals('prog.jpg'));
        expect(progressUpdates, contains(1.0)); // Should reach 100%
        expect(progressUpdates.first, equals(0.0));
      });
    });

    // --- Feature 5: Logging ---
    group('Feature 5: Logging', () {
      test('5.1: onLog receives messages', () async {
        final logs = <String>[];
        service.onLog = (msg) => logs.add(msg);

        service.start(
          sourcePath: sourcePath,
          targetPath: targetPath,
          deleteAfterTransfer: false,
          // Long interval to avoid scan logs interfering with check, though start log is immediate
          scanInterval: const Duration(milliseconds: 1000),
        );

        // Check for "Start monitoring" log
        expect(logs.any((l) => l.contains('開始監控')), isTrue);
      });
    });

    // --- Feature 7: Filtering ---
    group('Feature 7: Filtering', () {
      test('7.1: Ignores unsupported file extensions (e.g. .txt)', () async {
        final txt = File(p.join(sourcePath, 'ignore.txt'));
        await txt.writeAsString('content');

        service.start(
          sourcePath: sourcePath,
          targetPath: targetPath,
          deleteAfterTransfer: false,
          scanInterval: const Duration(milliseconds: 50),
        );
        await Future.delayed(const Duration(milliseconds: 400));

        final targetDir = Directory(targetPath);
        expect(targetDir.listSync().isEmpty, isTrue);
      });

      test('7.2: Ignores hidden files (starting with dot)', () async {
        final hidden = File(p.join(sourcePath, '.hidden.jpg'));
        await hidden.writeAsString('content');

        service.start(
          sourcePath: sourcePath,
          targetPath: targetPath,
          deleteAfterTransfer: false,
          scanInterval: const Duration(milliseconds: 50),
        );
        await Future.delayed(const Duration(milliseconds: 400));

        final targetDir = Directory(targetPath);
        expect(targetDir.listSync().isEmpty, isTrue);
      });
    });

    // --- Feature 8: Security ---
    group('Feature 8: Security', () {
      test('8.1: Verifies file content size match after transfer', () async {
        final file = File(p.join(sourcePath, 'sec.jpg'));
        await file.writeAsString('important content');

        service.start(
          sourcePath: sourcePath,
          targetPath: targetPath,
          deleteAfterTransfer: false,
          scanInterval: const Duration(milliseconds: 50),
        );
        await Future.delayed(const Duration(milliseconds: 400));

        final targetFile = File(
          p.join(targetPath, _year(), _month(), 'sec.jpg'),
        );
        expect(targetFile.existsSync(), isTrue);
        expect(await targetFile.length(), equals(await file.length()));
      });
    });
  });
}

String _year() => DateTime.now().year.toString();
String _month() => DateTime.now().month.toString().padLeft(2, '0');
