import 'dart:io';

import 'package:test/test.dart';

void main() {
  final readme = File('README.md').readAsStringSync();

  test('README has no beta install snippet', () {
    expect(readme, isNot(contains('^0.1.0-beta')));
    expect(readme, isNot(contains('ref: v0.1.0-beta')));
    final version = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1)!;
    expect(readme, contains('sp_laravel_api: ^$version'));
  });

  for (final entry in {
    'rpc': RegExp(r'^#{2,3} .*\brpc\b', multiLine: true, caseSensitive: false),
    'SpApiError': RegExp(r'^#{2,3} .*SpApiError', multiLine: true),
    'Pagination': RegExp(
      r'^#{2,3} .*pagination',
      multiLine: true,
      caseSensitive: false,
    ),
    'select': RegExp(
      r'^#{2,3} .*\bselect\b',
      multiLine: true,
      caseSensitive: false,
    ),
    'upsert': RegExp(
      r'^#{2,3} .*upsert',
      multiLine: true,
      caseSensitive: false,
    ),
    'realtime recovery': RegExp(
      r'^#{2,3} .*realtime recovery',
      multiLine: true,
      caseSensitive: false,
    ),
  }.entries) {
    test('README has a ${entry.key} heading', () {
      expect(readme, contains(entry.value));
    });
  }

  test('README names the select opt-out and relation syntax', () {
    expect(readme, contains('requireSelect: false'));
    expect(readme, contains('(*)'));
  });

  test('every linked test file exists', () {
    final links = RegExp(
      r'\]\((test/[^)#\s]+\.dart)\)',
    ).allMatches(readme).map((m) => m.group(1)!).toSet();
    expect(links, isNotEmpty);
    for (final path in links) {
      expect(File(path).existsSync(), isTrue, reason: '$path is missing');
    }
  });

  test('every example linked from README exists', () {
    final links = RegExp(
      r'\]\((example/[^)#\s]+\.dart)\)',
    ).allMatches(readme).map((m) => m.group(1)!).toSet();
    for (final path in links) {
      expect(File(path).existsSync(), isTrue, reason: '$path is missing');
    }
  });

  test('every README dart sample is compiled in example/', () {
    String norm(String t) => t.replaceAll(RegExp(r'[\s,]+'), '');
    final samples = norm(
      File('example/readme_samples.dart').readAsStringSync() +
          File('example/main.dart').readAsStringSync(),
    );
    final blocks = RegExp(
      r'```dart\n(.*?)```',
      dotAll: true,
    ).allMatches(readme).map((m) => m.group(1)!).toList();
    expect(blocks, isNotEmpty);
    for (final block in blocks) {
      expect(
        samples.contains(
          norm(block.replaceAll(RegExp(r'^import .*\n', multiLine: true), '')),
        ),
        isTrue,
        reason: 'not in example/: ${block.split('\n').first}',
      );
    }
  });
}
