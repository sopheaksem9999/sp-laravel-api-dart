import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

import '../support/fake_adapter.dart';

const sig = 'SIG-SECRET';
const token = 'TOKEN-SECRET-abc123';
const key = 'attachments/private/k-secret.bin';

void main() {
  late List<RequestOptions> seen;
  late AttachmentsModule attachments;
  late Dio theDio;
  late Map<String, Response<dynamic> Function(RequestOptions)> routes;
  late Response<dynamic> Function(RequestOptions) onPut;

  Response<dynamic> ok(RequestOptions o, Object data, [int status = 200]) =>
      Response(
        requestOptions: o,
        statusCode: status,
        data: {'success': true, 'data': data},
      );

  Map<String, dynamic> s3Create() => {
    'key': key,
    'upload_url': 'https://s3.test/bucket/$key?X-Amz-Signature=$sig',
    'method': 'PUT',
    'headers': {
      'Host': ['s3.test'],
      'Content-Type': ['image/png'],
      'x-amz-acl': ['private'],
    },
    'upload_token': token,
    'expires_at': 1900000000,
  };

  String fn(RequestOptions o) => o.uri.pathSegments.last;

  setUp(() {
    seen = [];
    routes = {
      'create-upload-url': (o) => ok(o, s3Create()),
      'complete-upload': (o) => ok(o, {'id': 7, 'filename': 'a.png'}),
    };
    onPut = (o) => Response(requestOptions: o, statusCode: 200);
    final dio = theDio = Dio();
    dio.httpClientAdapter = FakeAdapter((options) {
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

  group('AttachmentsModule.uploadDirect', () {
    test(
      'S3: create-upload-url, PUT to the signed URL with the backend headers '
      'and no Authorization, then complete-upload with key, token, expiry',
      () async {
        final r = await attachments.uploadDirect(
          filename: 'a.png',
          bytes: [1, 2, 3],
          contentType: 'image/png',
          visibility: 'public',
          folder: '12',
          recordType: 'products',
          recordId: 7,
          collection: 'gallery',
        );
        expect(r['id'], 7);
        expect(order(), ['create-upload-url', 'PUT', 'complete-upload']);
        final create = seen[0];
        expect(create.path, endsWith('/sp_attachments/rpc/create-upload-url'));
        expect(create.headers['Authorization'], 'Bearer user-jwt');
        final put = seen[1];
        expect(put.method, 'PUT');
        expect(
          put.uri.toString(),
          'https://s3.test/bucket/$key?X-Amz-Signature=$sig',
        );
        expect(put.headers['Authorization'], isNull);
        expect(put.headers['X-Tenant'], isNull);
        expect(put.headers['Host'], isNull);
        expect(put.headers['Content-Type'], 'image/png');
        expect(put.headers['x-amz-acl'], 'private');
        final complete = seen[2];
        expect(complete.path, endsWith('/sp_attachments/rpc/complete-upload'));
        expect(complete.data, {
          'key': key,
          'upload_token': token,
          'expires_at': 1900000000,
          'filename': 'a.png',
          'content_type': 'image/png',
          'visibility': 'public',
          'folder_id': '12',
          'record_type': 'products',
          'record_id': '7',
          'collection_name': 'gallery',
        });
      },
    );

    test('create-upload-url body has filename, content_type, visibility, '
        'folder_id and no record or shared fields', () async {
      await attachments.uploadDirect(
        filename: 'a.png',
        bytes: [1],
        contentType: 'image/png',
        folder: '12',
        recordType: 'products',
        recordId: 7,
        title: 'Logo',
        visibility: 'temp_private',
        tempTimeoutMinutes: 30,
      );
      expect(seen[0].data, {
        'filename': 'a.png',
        'content_type': 'image/png',
        'visibility': 'temp_private',
        'folder_id': '12',
      });
    });

    test('complete-upload carries record_type, record_id, collection_name, '
        'replace_old, title, caption, temp_timeout_minutes', () async {
      await attachments.uploadDirect(
        filename: 'a.png',
        bytes: [1],
        visibility: 'temp_private',
        recordType: 'products',
        recordId: 7,
        collection: 'gallery',
        replaceOld: true,
        title: 'Logo',
        caption: 'Our logo',
        tempTimeoutMinutes: 30,
      );
      final body = seen[2].data as Map;
      expect(body['replace_old'], true);
      expect(body['title'], 'Logo');
      expect(body['caption'], 'Our logo');
      expect(body['temp_timeout_minutes'], '30');
      expect(body['record_type'], 'products');
      expect(body['collection_name'], 'gallery');
      expect(body['visibility'], 'temp_private');
    });

    test('local disk: upload_url null posts the file to complete-upload with '
        'the fields as strings', () async {
      routes['create-upload-url'] = (o) => ok(o, {
        'key': key,
        'upload_url': null,
        'method': 'POST',
        'upload_token': token,
        'expires_at': 1900000000,
      });
      await attachments.uploadDirect(
        filename: 'raw.bin',
        bytes: [1, 2, 3, 4],
        visibility: 'temp_public',
        replaceOld: true,
        recordType: 'products',
        recordId: 7,
        title: 'Logo',
        tempTimeoutAt: DateTime.utc(2026, 10, 30, 10),
      );
      expect(order(), ['create-upload-url', 'complete-upload']);
      final req = seen[1];
      expect(req.headers['Authorization'], 'Bearer user-jwt');
      final form = req.data as FormData;
      final f = {for (final e in form.fields) e.key: e.value};
      expect(form.files.single.key, 'file');
      expect(form.files.single.value.filename, 'raw.bin');
      expect(form.files.single.value.length, 4);
      expect(f['key'], key);
      expect(f['upload_token'], token);
      expect(f['expires_at'], '1900000000');
      expect(f['visibility'], 'temp_public');
      expect(f['replace_old'], 'true');
      expect(f['title'], 'Logo');
      expect(f['temp_timeout_at'], '2026-10-30T10:00:00.000Z');
    });

    test(
      'a failed PUT is a typed error and complete-upload is not called',
      () async {
        onPut = (o) => Response(requestOptions: o, statusCode: 403);
        final e = await attachments
            .uploadDirect(filename: 'a.png', bytes: [1])
            .then<SpApiError?>(
              (_) => null,
              onError: (Object e) => e as SpApiError,
            );
        expect(e, isNotNull);
        expect(e!.status, 403);
        expect(order(), ['create-upload-url', 'PUT']);
      },
    );

    test('no error message, toString or body contains the signed URL, the '
        'upload token or the key', () async {
      onPut = (o) => Response(
        requestOptions: o,
        statusCode: 500,
        data: 'storage said $sig $token $key',
      );
      final e = await attachments
          .uploadDirect(filename: 'a.png', bytes: [1])
          .then<SpApiError?>(
            (_) => null,
            onError: (Object e) => e as SpApiError,
          );
      final text = '${e!.message} $e ${e.body} ${e.cause}';
      for (final secret in [sig, token, key]) {
        expect(text, isNot(contains(secret)));
      }
    });

    test('a response without key, upload_token or expires_at is a typed error '
        'that does not echo the body', () async {
      routes['create-upload-url'] = (o) =>
          ok(o, {'upload_url': 'https://s3.test/x'});
      final e = await attachments
          .uploadDirect(filename: 'a.png', bytes: [1])
          .then<SpApiError?>(
            (_) => null,
            onError: (Object e) => e as SpApiError,
          );
      expect(e, isNotNull);
      expect(order(), ['create-upload-url']);
      expect('${e!.message} ${e.body}', isNot(contains('s3.test')));
    });

    test('the PUT carries no Authorization even when an interceptor on the Dio '
        'adds one (attach(dio) from sp_jwt_auth)', () async {
      theDio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            o.headers['Authorization'] = 'Bearer from-interceptor';
            h.next(o);
          },
        ),
      );
      await attachments.uploadDirect(filename: 'a.png', bytes: [1, 2, 3]);
      expect(order(), ['create-upload-url', 'PUT', 'complete-upload']);
      expect(seen[0].headers['Authorization'], 'Bearer from-interceptor');
      expect(seen[1].headers['Authorization'], isNull);
    });

    test('a Uint8List is sent as is, without another copy', () async {
      final payload = Uint8List.fromList([1, 2, 3, 4]);
      await attachments.uploadDirect(filename: 'a.png', bytes: payload);
      expect(identical(seen[1].data, payload), isTrue);
    });

    test('a cancelled PUT rethrows a cancel error that does not hold the '
        'signed URL', () async {
      onPut = (o) =>
          throw DioException(requestOptions: o, type: DioExceptionType.cancel);
      final e = await attachments
          .uploadDirect(filename: 'a.png', bytes: [1])
          .then<DioException?>(
            (_) => null,
            onError: (Object e) => e as DioException,
          );
      expect(e, isNotNull);
      expect(e!.type, DioExceptionType.cancel);
      expect(e.requestOptions.uri.toString(), isNot(contains(sig)));
      expect('${e.requestOptions.data}', isNot(contains(token)));
    });

    test('a transport failure on an upload call has no cause that holds the '
        'token or the key', () async {
      routes['complete-upload'] = (o) => throw DioException.connectionError(
        requestOptions: o,
        reason: 'refused',
      );
      final e = await attachments
          .uploadDirect(filename: 'a.png', bytes: [1])
          .then<SpApiError?>(
            (_) => null,
            onError: (Object e) => e as SpApiError,
          );
      expect(e, isNotNull);
      expect(e!.isTransport, isTrue);
      expect(e.cause, isNull);
    });

    test(
      'a timeout needs visibility temp_*, and makes no request without it',
      () async {
        await expectLater(
          attachments.uploadDirect(
            filename: 'a.png',
            bytes: [1],
            tempTimeoutMinutes: 5,
          ),
          throwsA(
            isA<SpApiError>().having(
              (e) => e.code,
              'code',
              SpApiErrorCode.unencodableValue,
            ),
          ),
        );
        expect(seen, isEmpty);
        await attachments.uploadDirect(
          filename: 'a.png',
          bytes: [1],
          visibility: 'temp_public',
          tempTimeoutMinutes: 5,
        );
        expect((seen.last.data as Map)['temp_timeout_minutes'], '5');
      },
    );
  });
}
