import 'dart:convert';
import 'dart:io';
import 'package:sp_laravel_api/src/typegen/generator.dart';

const String usage = '''
Usage:
  dart run sp_laravel_api:typegen (--url <url> | --file <path> | --schema <url|path>) [options]

Generates Dart model classes and a Tables schema registry from an OpenAPI document.

Options:
  --url <url>             Fetch the OpenAPI document over HTTP/S
  --file <path>           Read a local OpenAPI JSON export
  --schema <url|path>     Path or URL to the OpenAPI document
  -i, --input <url|path>  Alias for --schema
  -o, --out <path>        Output directory or .dart file path (default: lib/src/models)
  --name <filename>       File name when --out is a directory (default: models.dart)
  --header <name:value>   Extra HTTP header for remote fetches (repeatable)
  --token <token>         Bearer token for remote fetches
  --tenant <id>           Tenant ID for multi-tenant backend
  --tenant-header <name>  Tenant header name (default: X-Tenant-ID)
  --timeout <seconds>     Fetch timeout in seconds (default: 30)
  -h, --help              Show this help message

Environment:
  SP_API_TOKEN            Used for Authorization header if --token is not specified
''';

void main(List<String> args) async {
  final cli = _parseArgs(args);

  if (cli.help) {
    stdout.writeln(usage);
    return;
  }

  String? target = cli.url;
  bool isRemote = target != null;

  if (target == null) {
    final candidate = cli.schema ?? cli.file;
    if (candidate != null && candidate.isNotEmpty) {
      if (candidate.startsWith('http://') || candidate.startsWith('https://')) {
        target = candidate;
        isRemote = true;
      } else {
        target = candidate;
        isRemote = false;
      }
    }
  }

  if (target == null || target.isEmpty) {
    stderr.writeln(usage);
    exitCode = 1;
    return;
  }

  Map<String, dynamic> decoded;

  try {
    if (isRemote) {
      final client = HttpClient();
      client.connectionTimeout = Duration(seconds: cli.timeoutSeconds);
      try {
        final uri = Uri.parse(target);
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');

        for (final h in cli.headers) {
          final colon = h.indexOf(':');
          if (colon > 0) {
            final k = h.substring(0, colon).trim();
            final v = h.substring(colon + 1).trim();
            request.headers.set(k, v);
          }
        }

        final effectiveToken =
            cli.token ?? Platform.environment['SP_API_TOKEN'];
        if (effectiveToken != null && effectiveToken.isNotEmpty) {
          if (request.headers.value(HttpHeaders.authorizationHeader) == null) {
            request.headers.set(
              HttpHeaders.authorizationHeader,
              'Bearer $effectiveToken',
            );
          }
        }

        if (cli.tenant != null && cli.tenant!.isNotEmpty) {
          if (request.headers.value(cli.tenantHeader) == null) {
            request.headers.set(cli.tenantHeader, cli.tenant!);
          }
        }

        final response = await request.close().timeout(
          Duration(seconds: cli.timeoutSeconds),
        );

        if (response.statusCode < 200 || response.statusCode >= 300) {
          stderr.writeln(
            'Error: Failed to fetch OpenAPI schema from $target (HTTP ${response.statusCode})',
          );
          exitCode = 1;
          return;
        }

        final body = await response.transform(utf8.decoder).join();
        decoded = jsonDecode(body) as Map<String, dynamic>;
      } finally {
        client.close();
      }
    } else {
      final inputFile = File(target);
      if (!inputFile.existsSync()) {
        stderr.writeln('Error: Input OpenAPI file not found at $target');
        exitCode = 1;
        return;
      }
      final jsonContent = inputFile.readAsStringSync();
      decoded = jsonDecode(jsonContent) as Map<String, dynamic>;
    }

    final outDir = cli.out ?? 'lib/src/models';
    final outFileName = cli.name ?? 'models.dart';

    final generator = OpenApiGenerator(openApi: decoded);
    final generatedSource = generator.generate();

    final File targetFile;
    if (outDir.endsWith('.dart')) {
      targetFile = File(outDir);
      if (!targetFile.parent.existsSync()) {
        targetFile.parent.createSync(recursive: true);
      }
    } else {
      final targetDirectory = Directory(outDir);
      if (!targetDirectory.existsSync()) {
        targetDirectory.createSync(recursive: true);
      }
      targetFile = File('${targetDirectory.path}/$outFileName');
    }

    targetFile.writeAsStringSync(generatedSource);
    stdout.writeln('Successfully generated Dart models at ${targetFile.path}');
  } catch (err) {
    stderr.writeln('Typegen failed: $err');
    exitCode = 1;
  }
}

class _CliOptions {
  final String? url;
  final String? file;
  final String? schema;
  final String? out;
  final String? name;
  final List<String> headers;
  final String? token;
  final String? tenant;
  final String tenantHeader;
  final int timeoutSeconds;
  final bool help;

  _CliOptions({
    this.url,
    this.file,
    this.schema,
    this.out,
    this.name,
    this.headers = const [],
    this.token,
    this.tenant,
    this.tenantHeader = 'X-Tenant-ID',
    this.timeoutSeconds = 30,
    this.help = false,
  });
}

_CliOptions _parseArgs(List<String> args) {
  String? url;
  String? file;
  String? schema;
  String? out;
  String? name;
  final headers = <String>[];
  String? token;
  String? tenant;
  String tenantHeader = 'X-Tenant-ID';
  int timeoutSeconds = 30;
  bool help = false;

  for (int i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '-h' || arg == '--help') {
      help = true;
      continue;
    }

    String optName;
    String? optValue;

    if (arg.startsWith('--')) {
      final eq = arg.indexOf('=');
      if (eq > 0) {
        optName = arg.substring(2, eq);
        optValue = arg.substring(eq + 1);
      } else {
        optName = arg.substring(2);
        if (i + 1 < args.length && !args[i + 1].startsWith('-')) {
          optValue = args[++i];
        }
      }
    } else if (arg.startsWith('-')) {
      final flag = arg.substring(1);
      if (flag == 'i') {
        optName = 'schema';
        if (i + 1 < args.length && !args[i + 1].startsWith('-')) {
          optValue = args[++i];
        }
      } else if (flag == 'o') {
        optName = 'out';
        if (i + 1 < args.length && !args[i + 1].startsWith('-')) {
          optValue = args[++i];
        }
      } else {
        continue;
      }
    } else {
      continue;
    }

    switch (optName) {
      case 'url':
        url = optValue;
        break;
      case 'file':
        file = optValue;
        break;
      case 'schema':
      case 'input':
        schema = optValue;
        break;
      case 'out':
        out = optValue;
        break;
      case 'name':
        name = optValue;
        break;
      case 'header':
        if (optValue != null) headers.add(optValue);
        break;
      case 'token':
        token = optValue;
        break;
      case 'tenant':
        tenant = optValue;
        break;
      case 'tenant-header':
        if (optValue != null) tenantHeader = optValue;
        break;
      case 'timeout':
        if (optValue != null) timeoutSeconds = int.tryParse(optValue) ?? 30;
        break;
    }
  }

  return _CliOptions(
    url: url,
    file: file,
    schema: schema,
    out: out,
    name: name,
    headers: headers,
    token: token,
    tenant: tenant,
    tenantHeader: tenantHeader,
    timeoutSeconds: timeoutSeconds,
    help: help,
  );
}
