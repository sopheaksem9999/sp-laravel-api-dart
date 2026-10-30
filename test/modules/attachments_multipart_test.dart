import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

import '../support/fake_adapter.dart';

const sig = 'SIG-SECRET';
const token = 'TOKEN-SECRET-abc123';
const key = 'attachments/private/k-secret.bin';
const mib = 1024 * 1024;
const part = 5 * mib;

void main() {
  late List<RequestOptions> seen;
  late AttachmentsModule attachments;
  late Map<String, FutureOr<Response<dynamic>> Function(RequestOptions)> routes;
  late FutureOr<Response<dynamic>> Function(RequestOptions) onPut;

  Response<dynamic> ok(RequestOptions o, Object? data) => Response(
    requestOptions: o,
    statusCode: 200,
    data: {'success': true, 'data': data},
  );

  String fn(RequestOptions o) => o.uri.pathSegments.last;
  int partNumber(RequestOptions o) =>
      int.parse(o.uri.queryParameters['partNumber'] ?? '0');

  Response<dynamic> putOk(RequestOptions o) => Response(
    requestOptions: o,
    statusCode: 200,
    headers: Headers.fromMap({
      'etag': ['"etag-${partNumber(o)}"'],
    }),
  );

  setUp(() {
    seen = [];
    routes = {
      'create-multipart-upload': (o) => ok(o, {
        'key': key,
        'upload_id': 'UP-1',
        'upload_token': token,
        'expires_at': 1900000000,
      }),
      'sign-multipart-part': (o) {
        final n = (o.data as Map)['part_number'];
        return ok(o, {
          'url':
              'https://s3.test/bucket/$key?partNumber=$n&uploadId=UP-1'
              '&X-Amz-Signature=$sig-$n',
          'headers': {
            'Host': ['s3.test'],
            'x-amz-meta': ['m'],
          },
        });
      },
      'complete-multipart-upload': (o) => ok(o, {'id': 42}),
      'abort-multipart-upload': (o) => ok(o, null),
    };
    onPut = putOk;
    final dio = Dio();
    dio.httpClientAdapter = FakeAdapter((options) async {
      seen.add(options);
      if (options.uri.host == 's3.test') return onPut(options);
      final route = routes[fn(options)];
      if (route == null) fail('no route for ${options.uri}');
      return route(options);
    });
    final api = SpApi(
      baseUrl: Uri.parse('https://host.test/api'),
      dio: dio,
      auth: ApiAuth(
        headers: () async => {'Authorization': 'Bearer user-jwt'},
        handleUnauthorized: () async => false,
      ),
      tenant: TenantConfig(header: 'X-Tenant', value: () => '5'),
    );
    attachments = AttachmentsModule(api: api);
  });

  List<String> order() => [
    for (final o in seen) o.uri.host == 's3.test' ? 'PUT' : fn(o),
  ];
  List<RequestOptions> puts() =>
      seen.where((o) => o.uri.host == 's3.test').toList();
  int len(RequestOptions o) => (o.data as Uint8List).length;

  Stream<List<int>> chunks(List<int> sizes) =>
      Stream.fromIterable([for (final s in sizes) Uint8List(s)]);

  Future<SpApiError> failure(Future<Object?> f) => f.then<SpApiError>(
    (_) => throw StateError('expected a failure'),
    onError: (Object e) => e as SpApiError,
  );

  group('AttachmentsModule.uploadMultipart', () {
    test(
      'create, sign per part, PUT, complete with ordered parts (3 parts)',
      () async {
        final r = await attachments.uploadMultipart(
          filename: 'big.bin',
          stream: chunks([part, part, 1 * mib]),
          totalBytes: 2 * part + mib,
          partSize: part,
          concurrency: 1,
          visibility: 'private',
        );
        expect(r['id'], 42);
        expect(order(), [
          'create-multipart-upload',
          'sign-multipart-part',
          'PUT',
          'sign-multipart-part',
          'PUT',
          'sign-multipart-part',
          'PUT',
          'complete-multipart-upload',
        ]);
        expect(
          seen.first.path,
          endsWith('/sp_attachments/rpc/create-multipart-upload'),
        );
        expect(seen.first.data, {
          'filename': 'big.bin',
          'visibility': 'private',
        });
        final complete = seen.last.data as Map;
        expect(complete['key'], key);
        expect(complete['upload_id'], 'UP-1');
        expect(complete['upload_token'], token);
        expect(complete['expires_at'], 1900000000);
        expect(complete['parts'], [
          {'part_number': 1, 'etag': '"etag-1"'},
          {'part_number': 2, 'etag': '"etag-2"'},
          {'part_number': 3, 'etag': '"etag-3"'},
        ]);
        expect(complete['filename'], 'big.bin');
        expect(complete['visibility'], 'private');
      },
    );

    test(
      'parts finish out of order but complete lists them in number order',
      () async {
        onPut = (o) async {
          await Future<void>.delayed(
            Duration(milliseconds: partNumber(o) == 1 ? 60 : 5),
          );
          return putOk(o);
        };
        await attachments.uploadMultipart(
          filename: 'big.bin',
          stream: chunks([part, part, part]),
          partSize: part,
          concurrency: 3,
        );
        final parts = (seen.last.data as Map)['parts'] as List;
        expect([for (final p in parts) (p as Map)['part_number']], [1, 2, 3]);
      },
    );

    test('the part PUTs carry the backend headers except Host and no '
        'Authorization or tenant header (auth configured)', () async {
      await attachments.uploadMultipart(
        filename: 'a.bin',
        stream: chunks([part]),
        partSize: part,
      );
      final put = puts().single;
      expect(put.method, 'PUT');
      expect(put.headers['x-amz-meta'], 'm');
      expect(put.headers['Host'], isNull);
      expect(put.headers['Authorization'], isNull);
      expect(put.headers['X-Tenant'], isNull);
      expect(seen.first.headers['Authorization'], 'Bearer user-jwt');
    });

    test('a stream of small chunks is re-cut into exact partSize parts and '
        'the last is smaller', () async {
      await attachments.uploadMultipart(
        filename: 'a.bin',
        stream: chunks(List.filled(11, mib)),
        totalBytes: 11 * mib,
        partSize: part,
        concurrency: 1,
      );
      expect([for (final p in puts()) len(p)], [part, part, mib]);
    });

    test('an empty stream uploads one empty part', () async {
      await attachments.uploadMultipart(
        filename: 'a.bin',
        stream: const Stream<List<int>>.empty(),
        partSize: part,
      );
      expect([for (final p in puts()) len(p)], [0]);
      expect(((seen.last.data as Map)['parts'] as List).length, 1);
    });

    test('a failing part triggers one abort-multipart-upload and rethrows the '
        'original error', () async {
      onPut = (o) => partNumber(o) == 2
          ? Response(requestOptions: o, statusCode: 500)
          : putOk(o);
      final e = await failure(
        attachments.uploadMultipart(
          filename: 'a.bin',
          stream: chunks([part, part, part]),
          partSize: part,
          concurrency: 1,
        ),
      );
      expect(e.status, 500);
      expect(order().where((s) => s == 'abort-multipart-upload').length, 1);
      expect(order().contains('complete-multipart-upload'), isFalse);
      final abort = seen.firstWhere((o) => fn(o) == 'abort-multipart-upload');
      expect((abort.data as Map)['upload_token'], token);
    });

    test('abort failure does not mask the original error', () async {
      onPut = (o) => Response(requestOptions: o, statusCode: 403);
      routes['abort-multipart-upload'] = (o) => Response(
        requestOptions: o,
        statusCode: 500,
        data: {'success': false},
      );
      final e = await failure(
        attachments.uploadMultipart(
          filename: 'a.bin',
          stream: chunks([part]),
          partSize: part,
        ),
      );
      expect(e.status, 403);
    });

    test(
      'a missing ETag header is a typed error mentioning ExposeHeaders',
      () async {
        onPut = (o) => Response(requestOptions: o, statusCode: 200);
        final e = await failure(
          attachments.uploadMultipart(
            filename: 'a.bin',
            stream: chunks([part]),
            partSize: part,
          ),
        );
        expect(e.message, contains('ExposeHeaders: ETag'));
      },
    );

    test(
      'no error contains the signed URL, the upload token or the key',
      () async {
        onPut = (o) => Response(
          requestOptions: o,
          statusCode: 500,
          data: 'storage echoed $sig $token $key',
        );
        final e = await failure(
          attachments.uploadMultipart(
            filename: 'a.bin',
            stream: chunks([part]),
            partSize: part,
          ),
        );
        final text = '${e.message} $e ${e.body} ${e.cause}';
        for (final secret in [sig, token, key]) {
          expect(text, isNot(contains(secret)));
        }
      },
    );

    test('a stream error aborts only after the in-flight parts finish and no '
        'progress arrives after the failure', () async {
      final log = <String>[];
      onPut = (o) async {
        log.add('put-start ${partNumber(o)}');
        await Future<void>.delayed(const Duration(milliseconds: 40));
        log.add('put-end ${partNumber(o)}');
        return putOk(o);
      };
      final base = routes['abort-multipart-upload']!;
      routes['abort-multipart-upload'] = (o) {
        log.add('abort');
        return base(o);
      };
      Stream<List<int>> broken() async* {
        yield Uint8List(part);
        yield Uint8List(part);
        throw StateError('read failed');
      }

      var progressAfterFailure = false;
      var failed = false;
      final e = await attachments
          .uploadMultipart(
            filename: 'a.bin',
            stream: broken(),
            partSize: part,
            concurrency: 2,
            onProgress: (l, t) {
              if (failed) progressAfterFailure = true;
            },
          )
          .then<Object?>((_) => null, onError: (Object e) => e);
      failed = true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(e, isA<StateError>());
      expect(log.indexOf('abort'), greaterThan(log.indexOf('put-end 1')));
      expect(log.indexOf('abort'), greaterThan(log.indexOf('put-end 2')));
      expect(order().where((s) => s == 'abort-multipart-upload').length, 1);
      expect(order().contains('complete-multipart-upload'), isFalse);
      expect(progressAfterFailure, isFalse);
    });

    test('partSize below 5 MiB, concurrency 0 and too many parts throw '
        'before any request', () async {
      for (final call in <Future<Object?> Function()>[
        () => attachments.uploadMultipart(
          filename: 'a.bin',
          stream: chunks([1]),
          partSize: part - 1,
        ),
        () => attachments.uploadMultipart(
          filename: 'a.bin',
          stream: chunks([1]),
          concurrency: 0,
        ),
        () => attachments.uploadMultipart(
          filename: 'a.bin',
          stream: chunks([1]),
          totalBytes: part * 10001,
          partSize: part,
        ),
      ]) {
        final e = await failure(call());
        expect(e.code, SpApiErrorCode.unencodableValue);
      }
      expect(seen, isEmpty);
    });

    test('complete carries replace_old, title and temp_timeout_minutes '
        '(visibility temp_private) and create does not', () async {
      await attachments.uploadMultipart(
        filename: 'a.bin',
        stream: chunks([part]),
        partSize: part,
        visibility: 'temp_private',
        recordType: 'products',
        recordId: 7,
        collection: 'gallery',
        replaceOld: true,
        title: 'Logo',
        tempTimeoutMinutes: 30,
      );
      final create = seen.first.data as Map;
      for (final k in ['replace_old', 'title', 'temp_timeout_minutes']) {
        expect(create.containsKey(k), isFalse);
      }
      final complete = seen.last.data as Map;
      expect(complete['replace_old'], true);
      expect(complete['title'], 'Logo');
      expect(complete['temp_timeout_minutes'], '30');
      expect(complete['record_type'], 'products');
      expect(complete['record_id'], '7');
      expect(complete['collection_name'], 'gallery');
      expect(complete['visibility'], 'temp_private');
    });

    test('resize options are not parameters and a timeout needs a temp '
        'visibility', () async {
      final e = await failure(
        attachments.uploadMultipart(
          filename: 'a.bin',
          stream: chunks([1]),
          tempTimeoutMinutes: 5,
        ),
      );
      expect(e.code, SpApiErrorCode.unencodableValue);
      expect(seen, isEmpty);
    });

    test('onProgress reaches loaded == total', () async {
      final events = <(int, int?)>[];
      await attachments.uploadMultipart(
        filename: 'a.bin',
        stream: chunks([part, mib]),
        totalBytes: part + mib,
        partSize: part,
        concurrency: 1,
        onProgress: (l, t) => events.add((l, t)),
      );
      expect(events.last, (part + mib, part + mib));
      final unknown = <(int, int?)>[];
      seen.clear();
      await attachments.uploadMultipart(
        filename: 'a.bin',
        stream: chunks([mib]),
        partSize: part,
        onProgress: (l, t) => unknown.add((l, t)),
      );
      expect(unknown.last, (mib, mib));
    });
  });
}
