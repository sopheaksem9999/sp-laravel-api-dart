import 'dart:convert';
import 'dart:io';
import 'package:sp_laravel_api/src/typegen/generator.dart';

void main(List<String> args) async {
  final options = _parseArgs(args);

  final filePath = options['file'];
  if (filePath == null || filePath.isEmpty) {
    stderr.writeln(
      'Usage: dart run sp_laravel_api:typegen --file <openapi.json> [--out <dir>]',
    );
    exitCode = 1;
    return;
  }

  final inputFile = File(filePath);
  if (!inputFile.existsSync()) {
    stderr.writeln('Error: Input OpenAPI file not found at $filePath');
    exitCode = 1;
    return;
  }

  final outDir = options['out'] ?? 'lib/src/models';
  final outFileName = options['name'] ?? 'models.dart';

  try {
    final jsonContent = inputFile.readAsStringSync();
    final decoded = jsonDecode(jsonContent) as Map<String, dynamic>;

    final generator = OpenApiGenerator(openApi: decoded);
    final generatedSource = generator.generate();

    final targetDirectory = Directory(outDir);
    if (!targetDirectory.existsSync()) {
      targetDirectory.createSync(recursive: true);
    }

    final targetFile = File('${targetDirectory.path}/$outFileName');
    targetFile.writeAsStringSync(generatedSource);

    stdout.writeln('Successfully generated Dart models at ${targetFile.path}');
  } catch (err) {
    stderr.writeln('Typegen failed: $err');
    exitCode = 1;
  }
}

Map<String, String> _parseArgs(List<String> args) {
  final map = <String, String>{};
  for (int i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--')) {
      final name = arg.substring(2);
      if (name.contains('=')) {
        final parts = name.split('=');
        map[parts[0]] = parts.sublist(1).join('=');
      } else if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
        map[name] = args[++i];
      } else {
        map[name] = 'true';
      }
    }
  }
  return map;
}
