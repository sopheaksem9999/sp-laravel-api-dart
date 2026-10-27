import 'dart:convert';
import 'dart:io';
import 'package:sp_laravel_api/src/typegen/generator.dart';
import 'package:test/test.dart';

void main() {
  group('OpenAPI Typegen CLI & Generator', () {
    late String sampleOpenApiJson;
    late Directory tempDir;

    setUp(() {
      final fixtureFile = File('test/fixtures/openapi.sample.json');
      if (!fixtureFile.existsSync()) {
        throw StateError('Fixture file not found: ${fixtureFile.path}');
      }
      sampleOpenApiJson = fixtureFile.readAsStringSync();
      tempDir = Directory.systemTemp.createTempSync('sp_typegen_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'generates immutable Dart model classes with fromJson, toJson, and equality',
      () {
        final generator = OpenApiGenerator(
          openApi: jsonDecode(sampleOpenApiJson) as Map<String, dynamic>,
        );

        final generatedCode = generator.generate();

        // Check header and imports
        expect(generatedCode, contains("import 'package:meta/meta.dart';"));

        // Check InvoicesRead model
        expect(generatedCode, contains('class InvoicesRead {'));
        expect(generatedCode, contains('final String number;'));
        expect(generatedCode, contains('final String status;'));
        expect(generatedCode, contains('final num total;'));
        expect(generatedCode, contains('final bool isPaid;'));
        expect(generatedCode, contains('final int? customerId;'));
        expect(generatedCode, contains('final Map<String, dynamic>? meta;'));

        // Check InvoicesWrite model
        expect(generatedCode, contains('class InvoicesWrite {'));

        // Check fromJson and toJson
        expect(
          generatedCode,
          contains('factory InvoicesRead.fromJson(Map<String, dynamic> json)'),
        );
        expect(generatedCode, contains('Map<String, dynamic> toJson()'));

        // Check operator == and hashCode
        expect(generatedCode, contains('bool operator ==(Object other)'));
        expect(generatedCode, contains('int get hashCode'));

        // Check Tables registry
        expect(generatedCode, contains('class Tables {'));
        expect(
          generatedCode,
          contains("static const String invoices = 'invoices';"),
        );
        expect(
          generatedCode,
          contains("static const String invoiceItems = 'invoice_items';"),
        );
      },
    );

    test(
      'CLI bin/typegen.dart executes cleanly against local openapi file',
      () async {
        final inputFile = File('${tempDir.path}/openapi.json')
          ..writeAsStringSync(sampleOpenApiJson);
        final outDir = Directory('${tempDir.path}/out')..createSync();

        final result = await Process.run('dart', [
          'run',
          'bin/typegen.dart',
          '--file',
          inputFile.path,
          '--out',
          outDir.path,
        ]);

        expect(
          result.exitCode,
          equals(0),
          reason: 'stderr: ${result.stderr}\nstdout: ${result.stdout}',
        );
        final outputFile = File('${outDir.path}/models.dart');
        expect(outputFile.existsSync(), isTrue);

        final code = outputFile.readAsStringSync();
        expect(code, contains('class InvoicesRead'));
        expect(code, contains('class InvoiceItemsRead'));
      },
    );

    test(
      'CLI bin/typegen.dart supports --schema alias for local file',
      () async {
        final inputFile = File('${tempDir.path}/openapi.json')
          ..writeAsStringSync(sampleOpenApiJson);
        final outDir = Directory('${tempDir.path}/out_schema')..createSync();

        final result = await Process.run('dart', [
          'run',
          'bin/typegen.dart',
          '--schema',
          inputFile.path,
          '--out',
          outDir.path,
        ]);

        expect(
          result.exitCode,
          equals(0),
          reason: 'stderr: ${result.stderr}\nstdout: ${result.stdout}',
        );
        final outputFile = File('${outDir.path}/models.dart');
        expect(outputFile.existsSync(), isTrue);
        expect(outputFile.readAsStringSync(), contains('class InvoicesRead'));
      },
    );

    test(
      'CLI bin/typegen.dart fetches remote schema via --url and sends headers/token',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        HttpHeaders? receivedHeaders;

        server.listen((HttpRequest request) {
          receivedHeaders = request.headers;
          request.response.headers.contentType = ContentType.json;
          request.response.statusCode = HttpStatus.ok;
          request.response.write(sampleOpenApiJson);
          request.response.close();
        });

        final outDir = Directory('${tempDir.path}/out_remote')..createSync();
        final targetPath = '${outDir.path}/custom_models.dart';

        try {
          final result = await Process.run('dart', [
            'run',
            'bin/typegen.dart',
            '--url',
            'http://127.0.0.1:${server.port}/docs/openapi.json',
            '--token',
            'test_bearer_token',
            '--header',
            'X-Custom-Header: custom_value',
            '--tenant',
            'tenant_xyz',
            '--out',
            targetPath,
          ]);

          expect(
            result.exitCode,
            equals(0),
            reason: 'stderr: ${result.stderr}\nstdout: ${result.stdout}',
          );

          expect(receivedHeaders, isNotNull);
          expect(
            receivedHeaders!.value('authorization'),
            equals('Bearer test_bearer_token'),
          );
          expect(
            receivedHeaders!.value('x-custom-header'),
            equals('custom_value'),
          );
          expect(receivedHeaders!.value('x-tenant-id'), equals('tenant_xyz'));

          final outputFile = File(targetPath);
          expect(outputFile.existsSync(), isTrue);
          final code = outputFile.readAsStringSync();
          expect(code, contains('class InvoicesRead'));
        } finally {
          await server.close(force: true);
        }
      },
    );

    test('CLI bin/typegen.dart supports --schema with http URL', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      server.listen((HttpRequest request) {
        request.response.headers.contentType = ContentType.json;
        request.response.statusCode = HttpStatus.ok;
        request.response.write(sampleOpenApiJson);
        request.response.close();
      });

      final outDir = Directory('${tempDir.path}/out_schema_url')..createSync();

      try {
        final result = await Process.run('dart', [
          'run',
          'bin/typegen.dart',
          '--schema',
          'http://127.0.0.1:${server.port}/docs/openapi.json',
          '--out',
          outDir.path,
        ]);

        expect(
          result.exitCode,
          equals(0),
          reason: 'stderr: ${result.stderr}\nstdout: ${result.stdout}',
        );

        final outputFile = File('${outDir.path}/models.dart');
        expect(outputFile.existsSync(), isTrue);
        expect(outputFile.readAsStringSync(), contains('class InvoicesRead'));
      } finally {
        await server.close(force: true);
      }
    });
  });
}
