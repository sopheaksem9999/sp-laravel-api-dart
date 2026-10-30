import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

void main() {
  late List<RequestOptions> seen;

  AttachmentsModule moduleWith({String rpcPrefix = 'rpc'}) {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          seen.add(options);
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {'success': true, 'data': <String, dynamic>{}},
            ),
          );
        },
      ),
    );
    return AttachmentsModule(
      api: SpApi(
        baseUrl: Uri.parse('https://example.com/api/v1'),
        rpcPrefix: rpcPrefix,
        dio: dio,
      ),
    );
  }

  setUp(() => seen = []);

  Matcher unencodable() => isA<SpApiError>()
      .having((e) => e.code, 'code', SpApiErrorCode.unencodableValue)
      .having((e) => e.status, 'status', 0);

  group('path guard', () {
    for (final bad in ['', '.', '..']) {
      test(
        "an id of '$bad' throws unencodableValue and sends nothing",
        () async {
          final att = moduleWith();
          await expectLater(att.viewBytes(bad), throwsA(unencodable()));
          // link() sends the attachment id in the body, not in the path.
          await expectLater(att.link(bad, 7, 'a1'), throwsA(unencodable()));
          await expectLater(
            att.link('invoices', bad, 'a1'),
            throwsA(unencodable()),
          );
          await expectLater(
            att.unlink('invoices', 7, bad),
            throwsA(unencodable()),
          );
          expect(() => att.getViewUrl(bad), throwsA(unencodable()));
          expect(() => att.getDownloadUrl(bad), throwsA(unencodable()));
          expect(seen, isEmpty);
        },
      );
    }

    test('ids are percent-encoded', () {
      final att = moduleWith();
      expect(
        att.getViewUrl('a b/c'),
        'https://example.com/api/v1/sp_attachments/rpc/a%20b%2Fc/view',
      );
      expect(
        att.getDownloadUrl(12),
        'https://example.com/api/v1/sp_attachments/rpc/12/download',
      );
    });
  });

  group('rpcPrefix guard', () {
    for (final prefix in ['..', '.', 'a/../b', 'a//b']) {
      test("an rpcPrefix of '$prefix' throws and sends nothing", () async {
        final att = moduleWith(rpcPrefix: prefix);
        expect(() => att.getViewUrl('att_1'), throwsA(unencodable()));
        await expectLater(att.viewBytes('att_1'), throwsA(unencodable()));
        expect(seen, isEmpty);
      });
    }

    test('a normal multi-segment prefix still works', () {
      final att = moduleWith(rpcPrefix: 'v2/t');
      expect(
        att.getViewUrl('att_1'),
        'https://example.com/api/v1/sp_attachments/v2/t/att_1/view',
      );
    });

    test('a null id still builds a URL like before (no TypeError)', () {
      final att = moduleWith();
      expect(
        att.getViewUrl(null),
        'https://example.com/api/v1/sp_attachments/rpc/null/view',
      );
    });
  });

  group('URL builders and rpcPrefix', () {
    test('default prefix URLs are unchanged, query included', () {
      final att = moduleWith();
      expect(
        att.getViewUrl('att_1', width: 100, fit: 'crop', format: 'webp'),
        'https://example.com/api/v1/sp_attachments/rpc/att_1/view'
        '?w=100&fit=crop&format=webp',
      );
    });

    test('getViewUrl and getDownloadUrl honour a custom rpcPrefix', () {
      final att = moduleWith(rpcPrefix: 't');
      expect(
        att.getViewUrl('att_1'),
        'https://example.com/api/v1/sp_attachments/t/att_1/view',
      );
      expect(
        att.getDownloadUrl('att_1'),
        'https://example.com/api/v1/sp_attachments/t/att_1/download',
      );
    });

    test('an empty rpcPrefix drops that segment', () {
      final att = moduleWith(rpcPrefix: '');
      expect(
        att.getViewUrl('att_1'),
        'https://example.com/api/v1/sp_attachments/att_1/view',
      );
    });
  });
}
