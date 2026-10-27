// Compile-checked copies of the code samples in README.md.
// test/readme_test.dart verifies each README sample appears here verbatim
// (ignoring whitespace), and `dart analyze` compiles this file.
// ignore_for_file: unused_local_variable, avoid_print
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';

class Invoice {
  Invoice(this.id, this.number);
  final int id;
  final String number;
  factory Invoice.fromJson(Map<String, dynamic> json) =>
      Invoice((json['id'] as num).toInt(), json['number']?.toString() ?? '');
}

/// Stand-in for an `SpJwtAuth` instance from `sp_jwt_auth`.
abstract class AuthLike {
  Future<Map<String, String>> headers();
  Future<bool> handleUnauthorized();
}

Future<void> quickStart() async {
  final api = SpApi(
    baseUrl: Uri.parse('https://api.example.com/api/v1'),
    tenant: TenantConfig(header: 'X-Tenant-ID', value: () => '42'),
    auth: ApiAuth(
      headers: () async => {'Authorization': 'Bearer <token>'},
      handleUnauthorized: () async => false,
    ),
    dio: Dio(),
  );

  final invoices = api.table('invoices', fromJson: Invoice.fromJson);
  final page = await invoices.list(
    select: 'id,number,total,status',
    where: [Filter.eq('status', 'paid'), Filter.gte('total', 100)],
    sort: Sort('created_at', Order.desc),
    perPage: 25,
  );

  for (final invoice in page.items) {
    print('Invoice: ${invoice.number}');
  }
}

void pairing(AuthLike auth) {
  final api = SpApi(
    baseUrl: Uri.parse('https://api.example.com/api/v1'),
    auth: ApiAuth(
      headers: auth.headers,
      handleUnauthorized: auth.handleUnauthorized,
    ),
  );
}

Future<void> rpcSamples(SpApi api) async {
  // POST rpc/invoices/send with a JSON body.
  final sent = await api.rpc<Map<String, dynamic>>(
    'invoices/send',
    body: {'invoice_id': 7},
  );

  // GET rpc/reports/summary?year=2026, mapped into a typed value.
  final total = await api.rpc<int>(
    'reports/summary',
    query: {'year': 2026},
    fromJson: (data) => (data as Map<String, dynamic>)['total'] as int,
  );
}

Future<void> errorSamples(SpApi api) async {
  try {
    await api.table('invoices', fromJson: Invoice.fromJson).create({
      'number': '',
    });
  } on SpApiError catch (e) {
    if (e.isTransport) {
      print('Network failure: ${e.cause}');
    } else if (e.code == SpApiErrorCode.validation) {
      print(e.fieldErrors['number']);
    } else if (e.retryAfter != null) {
      print('Retry in ${e.retryAfter} seconds');
    }
    print('Request id for support: ${e.requestId}');
  }
}

Future<void> paginationSamples(TableGateway<Invoice> invoices) async {
  // Cursor pagination.
  var page = await invoices.list(select: 'id,number', perPage: 50);
  while (true) {
    for (final invoice in page.items) {
      print(invoice.number);
    }
    final next = page.nextCursor;
    if (next == null) break;
    page = await invoices.list(select: 'id,number', perPage: 50, cursor: next);
  }

  // Offset pagination.
  final second = await invoices.list(
    select: 'id,number',
    page: 2,
    perPage: 50,
    total: true,
  );
  print(second.total);
}

Future<void> selectSamples(TableGateway<Invoice> invoices) async {
  // Columns and relations.
  await invoices.list(select: 'id,number,customer(*)');
  await invoices.list(select: 'id,number,lines(id,qty,product(id,name))');

  // Explicit opt-out.
  await invoices.list(select: Select.all);
  await invoices.list(requireSelect: false);
}

Future<void> upsertSample(TableGateway<Invoice> invoices) async {
  try {
    await invoices.upsert({'number': 'INV-1'}, matchOn: ['number']);
  } on SpApiError catch (e) {
    if (e.status == 404 || e.status == 405) {
      print('upsert is disabled on this backend');
    } else {
      rethrow;
    }
  }
}

SpApi retrySample() {
  final api = SpApi(
    baseUrl: Uri.parse('https://api.example.com/api/v1'),
    retry: const RetryConfig(maxAttempts: 3),
  );
  return api;
}

Future<void> perCallRetrySample(SpApi api) async {
  await api.request('POST', 'invoices', data: {'number': 'INV-2'}, retry: true);
  await api.request('GET', 'invoices', retry: false);
}

SpApi envelopeSample() {
  final api = SpApi(
    baseUrl: Uri.parse('https://api.example.com/api/v1'),
    treatSuccessFalseAsError: false,
  );
  return api;
}

Future<void> perRequestSamples(TableGateway<Invoice> invoices) async {
  final cancel = CancelToken();
  final page = await invoices.list(
    select: 'id,number',
    options: Options(headers: {'X-Request-Source': 'mobile'}),
    cancelToken: cancel,
  );
  // Later, e.g. when the screen closes: cancel.cancel();
}

Future<void> realtimeRecoverySamples(SpRealtime rt) async {
  rt.onDisconnected(() => print('socket lost'));
  rt.onRecovered(() async {
    // Channels are re-authorized and re-subscribed; refetch missed data.
  });

  // Wire these to your app lifecycle and connectivity plugin.
  rt.onAppPaused();
  rt.onAppResumed();
  rt.onNetworkChanged(true);
}

Future<void> rawEventSample(SpRealtime rt) async {
  await rt.subscribe(
    'private-tenant.42',
    events: {'invoices.updated', 'courier_location.updated'},
    onEvent: (event) {
      if (event.isRecord) {
        print('${event.table}: ${event.action.name}');
      } else {
        print('${event.eventName}: ${event.raw}');
      }
    },
  );
}

Future<void> attachmentSamples(AttachmentsModule attachments) async {
  final bytes = Uint8List.fromList([1, 2, 3]);
  final file = await attachments.upload(bytes: bytes, filename: 'scan.pdf');
  await attachments.link('invoices', 7, file['id'].toString());
  final content = await attachments.viewBytes(file['id'].toString());
  await attachments.unlink('invoices', 7, file['id'].toString());
}

Future<void> realtimeSetup() async {
  final rt = SpRealtime(
    apiBaseUrl: Uri.parse('https://api.example.com/api/v1'),
    driver: Driver.reverb(
      host: 'ws.example.com',
      port: 443,
      appKey: 'app-key-123',
      useTls: true,
    ),
    tokenProvider: () async => 'jwt-token',
  );

  await rt.connect();

  final unsubscribe = await rt.subscribe(
    'private-tenant.42',
    events: {'invoices.created', 'invoices.updated'},
    onEvent: (event) {
      print('Event received: ${event.table}.${event.action.name}');
      print('Record payload: ${event.record}');
    },
  );

  // When done:
  unsubscribe();
}
