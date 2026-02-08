import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:iphone_img_transfer/transfer_provider.dart';

void main() {
  group('TransferProvider Tests (Feature 6: Path Memory)', () {
    late Directory tempDir;

    setUp(() async {
      // Create a real temp directory because validation logic checks checking for existence
      tempDir = await Directory.systemTemp.createTemp('provider_test_');
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'Critical Test 6.1: sourcePathProvider loads from SharedPreferences if valid',
      () async {
        final validPath = tempDir.path;
        // Pre-populate SharedPreferences
        SharedPreferences.setMockInitialValues({'source_path': validPath});
        final prefs = await SharedPreferences.getInstance();

        final container = ProviderContainer(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        );

        // Verify it loads correctly
        final sourcePath = container.read(sourcePathProvider);
        expect(sourcePath, equals(validPath));
      },
    );

    test(
      'Critical Test 6.2: sourcePathProvider clears invalid path from SharedPreferences',
      () async {
        // Use a path that definitely doesn't exist
        final invalidPath = '${tempDir.path}/non_existent_subdir';
        SharedPreferences.setMockInitialValues({'source_path': invalidPath});
        final prefs = await SharedPreferences.getInstance();

        final container = ProviderContainer(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        );

        // Should return null and remove the invalid key
        final sourcePath = container.read(sourcePathProvider);
        expect(sourcePath, isNull);

        // We can't easily check 'prefs' directly for removal synchronously here without awaiting?
        // Actually SharedPreferences mock is synchronous usually.
        expect(prefs.containsKey('source_path'), isFalse);
      },
    );

    test(
      'Critical Test 6.3: sourcePathProvider saves new value to SharedPreferences',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final container = ProviderContainer(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        );

        final newPath = tempDir.path;
        // Set value
        container.read(sourcePathProvider.notifier).value = newPath;

        // Verify in state and in prefs
        expect(container.read(sourcePathProvider), equals(newPath));
        expect(prefs.getString('source_path'), equals(newPath));
      },
    );
  });
}
