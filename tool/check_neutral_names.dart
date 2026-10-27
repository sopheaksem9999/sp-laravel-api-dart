import 'dart:io';

void main(List<String> args) {
  final forbiddenEnv = Platform.environment['FORBIDDEN_NAMES'];
  final isCi = Platform.environment['CI'] == 'true';

  if (args.length >= 2 && args[0] == '--test-string') {
    final testStr = args.sublist(1).join(' ').toLowerCase();
    if (forbiddenEnv == null || forbiddenEnv.trim().isEmpty) {
      stderr.writeln('FORBIDDEN_NAMES is not set for test.');
      exit(1);
    }
    final forbiddenList = forbiddenEnv
        .split(',')
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toList();

    for (final name in forbiddenList) {
      if (testStr.contains(name)) {
        stderr.writeln('Forbidden name found: "$name"');
        exit(1);
      }
    }
    stdout.writeln('Clean test string.');
    exit(0);
  }

  if (forbiddenEnv == null || forbiddenEnv.trim().isEmpty) {
    if (isCi) {
      stderr.writeln('Error: FORBIDDEN_NAMES environment variable must be set in CI.');
      exit(1);
    } else {
      stdout.writeln('Notice: FORBIDDEN_NAMES is not set locally; skipping check.');
      exit(0);
    }
  }

  final forbiddenList = forbiddenEnv
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty)
      .toList();

  var found = false;

  // 1. Scan tracked files
  final gitFilesResult = Process.runSync('git', ['ls-files']);
  if (gitFilesResult.exitCode == 0) {
    final files = (gitFilesResult.stdout as String).split('\n');
    for (final path in files) {
      final trimmedPath = path.trim();
      if (trimmedPath.isEmpty) continue;
      final file = File(trimmedPath);
      if (!file.existsSync()) continue;

      // Check path itself
      final lowerPath = trimmedPath.toLowerCase();
      for (final forbidden in forbiddenList) {
        if (lowerPath.contains(forbidden)) {
          stderr.writeln('Forbidden name in file path: $trimmedPath (matches "$forbidden")');
          found = true;
        }
      }

      // Check file content (skip binary or very large files)
      try {
        final content = file.readAsStringSync();
        final lowerContent = content.toLowerCase();
        for (final forbidden in forbiddenList) {
          if (lowerContent.contains(forbidden)) {
            stderr.writeln('Forbidden name in $trimmedPath (matches "$forbidden")');
            found = true;
          }
        }
      } catch (_) {
        // Skip binary files
      }
    }
  }

  // 2. Scan commit messages
  final gitLogResult = Process.runSync('git', ['log', '-n', '50', '--format=%B']);
  if (gitLogResult.exitCode == 0) {
    final logText = (gitLogResult.stdout as String).toLowerCase();
    for (final forbidden in forbiddenList) {
      if (logText.contains(forbidden)) {
        stderr.writeln('Forbidden name found in git commit log (matches "$forbidden")');
        found = true;
      }
    }
  }

  if (found) {
    stderr.writeln('Public repo hygiene check FAILED: client or proprietary names detected.');
    exit(1);
  }

  stdout.writeln('Public repo hygiene check PASSED: zero forbidden names detected.');
}
