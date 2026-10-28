import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

void main() {
  SpApi build(Object data) {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: data),
          );
        },
      ),
    );
    return SpApi(
      baseUrl: Uri.parse('https://example.com/api/v1'),
      dio: dio,
      auth: ApiAuth(
        headers: () async => {'Authorization': 'Bearer tok'},
        handleUnauthorized: () async => false,
      ),
    );
  }

  group('SpApi.getBytes returns Uint8List', () {
    test('returns the identical instance for a Uint8List response', () async {
      final source = Uint8List.fromList([1, 2, 3]);
      final result = await build(source).getBytes('f');
      expect(result, isA<Uint8List>());
      expect(identical(result, source), isTrue);
    });

    test('converts a plain List<int> response', () async {
      final result = await build(<int>[4, 5, 6]).getBytes('f');
      expect(result, isA<Uint8List>());
      expect(result, equals([4, 5, 6]));
    });

    test('result is assignable to List<int>', () async {
      final List<int> bytes = await build(
        Uint8List.fromList([7, 8]),
      ).getBytes('f');
      expect(bytes, equals([7, 8]));
    });

    test('AttachmentsModule.viewBytes returns a Uint8List', () async {
      final attachments = AttachmentsModule(api: build(<int>[9, 10]));
      final result = await attachments.viewBytes('att_1');
      expect(result, isA<Uint8List>());
      expect(result, equals([9, 10]));
    });
  });
}
