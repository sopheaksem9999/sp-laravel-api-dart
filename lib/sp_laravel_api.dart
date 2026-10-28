/// Typed REST client and multi-broadcaster realtime client for the SP Laravel backend packages.
library;

export 'src/api_auth.dart';
export 'src/api_core.dart';
export 'src/debug.dart';
export 'src/errors.dart';
export 'src/logging.dart' show SpLogMode, SpLogger, SpLogEntry, SpLog;
export 'src/pagination.dart';
export 'src/query/filter.dart';
export 'src/query/serialize.dart';
export 'src/query/sort.dart';
export 'src/table_gateway.dart';
export 'src/modules/attachments_module.dart';
export 'src/modules/audit_module.dart';
export 'src/modules/bulk_module.dart';
export 'src/modules/permissions_module.dart';
export 'src/realtime/driver.dart';
export 'src/realtime/pusher_framing.dart';
export 'src/realtime/record_event.dart';
export 'src/realtime/sp_realtime.dart';
export 'src/realtime/transport.dart';
export 'src/realtime/websocket_transport.dart';

/// Current version of the `sp_laravel_api` package.
const String packageVersion = '0.2.0';
