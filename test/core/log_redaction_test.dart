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

  test('the shared fixture has not been cut down', () {
    expect(headers.length, greaterThanOrEqualTo(46));
    expect(bodies.length, greaterThanOrEqualTo(103));
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
