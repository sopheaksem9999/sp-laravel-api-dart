import 'dart:io';

void main() {
  final errors = <String>[];

  // 1. Check forbidden imports in core
  final libDir = Directory('lib');
  if (libDir.existsSync()) {
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        final content = entity.readAsStringSync();
        final lines = content.split('\n');
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i].trim();
          if (line.startsWith('import ') || line.startsWith('export ')) {
            if (line.contains("'dart:io'") || line.contains('"dart:io"')) {
              errors.add('${entity.path}:${i + 1}: Forbidden import dart:io in core library.');
            }
            if (line.contains("'dart:html'") || line.contains('"dart:html"')) {
              errors.add('${entity.path}:${i + 1}: Forbidden import dart:html.');
            }
            if (line.contains("'dart:ui'") || line.contains('"dart:ui"')) {
              errors.add('${entity.path}:${i + 1}: Forbidden import dart:ui.');
            }
            if (line.contains("'package:flutter/") || line.contains('"package:flutter/')) {
              errors.add('${entity.path}:${i + 1}: Forbidden import package:flutter in pure Dart package.');
            }
          }
        }
      }
    }
  }

  if (errors.isNotEmpty) {
    stderr.writeln('Import policy violations found:');
    for (final err in errors) {
      stderr.writeln('  $err');
    }
    exit(1);
  }

  stdout.writeln('Import check passed: zero forbidden imports.');
}
