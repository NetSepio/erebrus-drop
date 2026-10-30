import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:crypto/crypto.dart';

import 'drop_auth_client.dart';
import 'gateway_config.dart';
import 'gateway_http.dart';
import 'gateway_session.dart';
import 'gateway_session_repository.dart';

/// Native workers must connect to this broker, rather than reading secure
/// storage or copying refresh credentials into isolate messages. A missing
/// owner fails closed; it never elects a second refreshing isolate.
class GatewaySessionBroker implements GatewaySessionAuthorization {
  GatewaySessionBroker({String? gatewayUrl})
    : _name = _portName(
        GatewayHttp.normalizeBase(gatewayUrl ?? resolveGatewayUrl()).toString(),
      );

  final String _name;
  static final _owners = <String, GatewaySessionRepository>{};
  static final _ports = <ReceivePort>[];

  static GatewaySessionRepository owner(DropAuthClient client) {
    if (RootIsolateToken.instance == null) {
      throw StateError('Only the root isolate can own gateway credentials');
    }
    return _owners.putIfAbsent(client.sessionNamespace, () {
      final repository = GatewaySessionRepository(
        client: client,
        store: SecureGatewaySessionStore(gateway: client.sessionNamespace),
      );
      final port = ReceivePort();
      if (!IsolateNameServer.registerPortWithName(
        port.sendPort,
        _portName(client.sessionNamespace),
      )) {
        port.close();
        throw StateError('A gateway session owner is already registered');
      }
      _ports.add(port);
      port.listen((dynamic request) async {
        final parts = request as List;
        final reply = parts[0] as SendPort;
        try {
          final credential = parts[2] == null
              ? null
              : GatewayCredential(parts[2] as String, parts[3] as String);
          if (parts[1] == 'authorize') {
            final result = await repository.authorize(rejected: credential);
            reply.send({
              'token': result.token,
              'generation': result.generation,
            });
          } else if (parts[1] == 'validate' && credential != null) {
            await repository.validate(credential);
            reply.send(<String, dynamic>{});
          } else if (parts[1] == 'failure' && credential != null) {
            await repository.handleFailure(credential, parts[4] as String?);
            reply.send(<String, dynamic>{});
          } else {
            throw StateError('Unsupported session broker operation');
          }
        } on GatewayException catch (e) {
          reply.send({
            'error': e.message,
            'code': e.errorCode,
            'status': e.statusCode,
            'retry_at': e.retryAt?.toIso8601String(),
          });
        } catch (_) {
          reply.send({'error': 'Session owner is unavailable'});
        }
      });
      return repository;
    });
  }

  Future<Map> _call(
    String operation,
    GatewayCredential? credential, [
    String? errorCode,
  ]) async {
    final owner = IsolateNameServer.lookupPortByName(_name);
    if (owner == null) throw GatewayException('Session owner is unavailable');
    final response = ReceivePort();
    try {
      owner.send([
        response.sendPort,
        operation,
        credential?.token,
        credential?.generation,
        errorCode,
      ]);
      final result =
          await response.first.timeout(const Duration(seconds: 90)) as Map;
      if (result['error'] != null) {
        throw GatewayException(
          result['error'] as String,
          errorCode: result['code'] as String?,
          statusCode: result['status'] as int?,
          retryAt: DateTime.tryParse('${result['retry_at']}'),
        );
      }
      return result;
    } on TimeoutException {
      // Do not fall back to a local refresh; the owner may still be committing.
      throw GatewayException('Session owner response timed out');
    } finally {
      response.close();
    }
  }

  @override
  Future<GatewayCredential> authorize({GatewayCredential? rejected}) async {
    final result = await _call('authorize', rejected);
    return GatewayCredential(
      result['token'] as String,
      result['generation'] as String,
    );
  }

  @override
  Future<void> validate(GatewayCredential credential) async {
    await _call('validate', credential);
  }

  @override
  Future<void> handleFailure(
    GatewayCredential credential,
    String? errorCode,
  ) async {
    await _call('failure', credential, errorCode);
  }

  static String _portName(String gateway) =>
      'io.erebrus.drop.auth.${sha256.convert(utf8.encode(gateway))}';
}
