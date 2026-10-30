import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A dio transport that answers every request from [handler], so tests run
/// through the real interceptor chain of the `Dio` it is installed on and a
/// second `Dio` that shares the adapter is intercepted too.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final FutureOr<Response<dynamic>> Function(RequestOptions) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final res = await handler(options);
    final headers = <String, List<String>>{
      for (final e in res.headers.map.entries) e.key: e.value,
    };
    final data = res.data;
    if (data is String || data == null) {
      return ResponseBody.fromString(
        (data as String?) ?? '',
        res.statusCode ?? 200,
        headers: headers,
      );
    }
    headers[Headers.contentTypeHeader] = [Headers.jsonContentType];
    return ResponseBody.fromString(
      jsonEncode(data),
      res.statusCode ?? 200,
      headers: headers,
    );
  }

  @override
  void close({bool force = false}) {}
}
