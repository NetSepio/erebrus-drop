import 'package:erebrus_drop/features/gateway/gateway_session_repository.dart';

class MemorySessionStore implements GatewaySessionStore {
  String? value;
  Future<void> Function(String)? beforeWrite;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    await beforeWrite?.call(value);
    this.value = value;
  }
}
