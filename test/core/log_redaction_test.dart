import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:sp_laravel_api/src/logging.dart';
import 'package:test/test.dart';

void main() {
  final vectors =
      jsonDecode(File('test/vectors/log_redaction.json').readAsStringSync())
          as Map<String, dynamic>;
  final headers = (vectors['headers'] as List).cast<Map<String, dynamic>>();
  final bodies = (vectors['bodies'] as List).cast<Map<String, dynamic>>();
  final urls = (vectors['urls'] as List).cast<Map<String, dynamic>>();
  final perf = (vectors['perf'] as List).cast<Map<String, dynamic>>();
  String build(Object? parts) => (parts as List)
      .map((p) => ((p as List)[0] as String) * (p[1] as int))
      .join();

  test('the shared fixture has not been cut down', () {
    expect(headers.length, greaterThanOrEqualTo(46));
    expect(bodies.length, greaterThanOrEqualTo(106));
    expect(perf.length, greaterThanOrEqualTo(17));
    expect(urls.length, greaterThanOrEqualTo(69));
  });

  group('sensitive body and query keys are redacted at any depth', () {
    for (final v in bodies) {
      test(v['name'] as String, () {
        expect(redactBody(v['input']), v['expected']);
      });
    }
    for (final v in urls) {
      test('url: ${v['name']}', () {
        expect(redactUrl(v['input'] as String), v['expected']);
      });
    }
  });

  group('sensitive headers are redacted (fixture)', () {
    for (final v in headers) {
      test(v['name'] as String, () {
        final input = v['input'] as Map<String, dynamic>;
        expect(
          redactHeaders(
            (input['headers'] as Map).cast<String, dynamic>(),
            tenantHeader: input['tenantHeader'] as String?,
          ),
          v['expected'],
        );
      });
    }
  });

  group('perf (every rule stays linear in the input length)', () {
    for (final v in perf) {
      test(v['name'] as String, () {
        final input = v['input'] as Map<String, dynamic>;
        final text = build(input['parts']);
        final kind = v['kind'] as String;
        final json = kind == 'bodyJson' ? jsonDecode(text) : null;
        final sw = Stopwatch()..start();
        final Object? out = switch (kind) {
          'url' => redactUrl(text),
          'header' => redactHeaders({
            input['header'] as String: text,
          })[input['header'] as String],
          'body' => redactBody(text),
          _ => redactBody(json),
        };
        sw.stop();
        expect(out, build((v['expected'] as Map)['parts']));
        expect(sw.elapsedMilliseconds, lessThan(v['maxMs'] as int));
      });
    }
  });

  test('isSpace is exactly the \\s class on every BMP code unit', () {
    final ws = RegExp(r'\s');
    final differ = [
      for (var c = 0; c <= 0xffff; c++)
        if (isSpace(c) != ws.hasMatch(String.fromCharCode(c))) c,
    ];
    expect(differ, isEmpty);
  });

  test('redaction does not mutate its input', () {
    final body = {
      'a': {'token': 't1'},
      'l': [
        {'password': 'p'},
      ],
    };
    redactBody(body);
    expect(body['a'], {'token': 't1'});
    expect((body['l'] as List).first, {'password': 'p'});
  });

  test('binary, multipart and stream bodies are described, not read', () {
    expect(redactBody(Uint8List(5)), '<5 bytes>');
    expect(redactBody(<int>[1, 2, 3]), '<3 bytes>');
    expect(redactBody(FormData.fromMap({'a': 'b'})), '<multipart>');
    expect(redactBody(const Stream<List<int>>.empty()), '<stream>');
  });

  test('a large object is truncated after redaction', () {
    final out = redactBody({'token': 'T', 'items': List.filled(2000, 'x')});
    expect(out, isA<String>());
    expect((out as String).endsWith('…[truncated]'), isTrue);
    expect(out, contains('<redacted>'));
    expect(out, isNot(contains('"T"')));
  });

  test('truncation does not split a surrogate pair', () {
    // 2047 ASCII then an emoji: the pair straddles the 2048 boundary.
    final s = '${'a' * 2047}\u{1F600}tail';
    final out = redactBody(s) as String;
    expect(out, '${'a' * 2047}…[truncated]');
    expect(out.codeUnits.where((c) => c >= 0xd800 && c <= 0xdfff), isEmpty);
  });
}
