import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show RootIsolateToken;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drop_auth_client.dart';
import 'gateway_http.dart';
import 'gateway_session.dart';

abstract interface class GatewaySessionStore {
  Future<String?> read();
  Future<void> write(String value);
}

/// One secure item is the commit unit: credentials, metadata and rotation journal
/// can never come from different refresh responses. No shared Keychain group,
/// iCloud synchronization or other Erebrus application's storage is used.
class SecureGatewaySessionStore implements GatewaySessionStore {
  SecureGatewaySessionStore({required String gateway})
    : _key = 'erebrus_drop_session_v1:$gateway' {
    if (kIsWeb) {
      throw UnsupportedError(
        'Flutter Web requires a server-side browser session',
      );
    }
  }

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      storageNamespace: 'erebrus_drop_auth',
      resetOnError: false,
    ),
    iOptions: IOSOptions(
      accountName: 'io.erebrus.drop.auth',
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
    mOptions: MacOsOptions(
      accountName: 'io.erebrus.drop.auth',
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
  );
  final String _key;
  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
}

class StoredGatewaySession {
  const StoredGatewaySession({
    required this.session,
    required this.generation,
    required this.method,
    this.mwaToken,
    this.rotationPending = false,
    this.loginRequired = false,
    this.retryAt,
  });
  final DropAuthSession session;
  final String generation;
  final String method;
  final String? mwaToken;
  final bool rotationPending;
  final bool loginRequired;
  final DateTime? retryAt;

  StoredGatewaySession withSession(
    DropAuthSession value, {
    bool rotationPending = false,
    bool loginRequired = false,
    DateTime? retryAt,
  }) => StoredGatewaySession(
    session: value,
    generation: generation,
    method: method,
    mwaToken: mwaToken,
    rotationPending: rotationPending,
    loginRequired: loginRequired,
    retryAt: retryAt,
  );

  Map<String, dynamic> toJson() => {
    'session': session.toJson(),
    'generation': generation,
    'method': method,
    'mwa_token': mwaToken,
    'rotation_pending': rotationPending,
    'login_required': loginRequired,
    'retry_at': retryAt?.toUtc().toIso8601String(),
  };

  factory StoredGatewaySession.fromJson(Map<String, dynamic> json) =>
      StoredGatewaySession(
        session: DropAuthSession.fromJson(
          Map<String, dynamic>.from(json['session']),
        ),
        generation: json['generation'] as String,
        method: json['method'] as String,
        mwaToken: json['mwa_token'] as String?,
        rotationPending: json['rotation_pending'] == true,
        loginRequired: json['login_required'] == true,
        retryAt: DateTime.tryParse('${json['retry_at']}'),
      );
}

/// Sole owner of refresh credentials. All operations execute in the root isolate;
/// background workers use GatewaySessionBroker, never construct another owner.
class GatewaySessionRepository implements GatewaySessionAuthorization {
  GatewaySessionRepository({
    required this.client,
    required this.store,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (RootIsolateToken.instance == null) {
      throw StateError('Use GatewaySessionBroker from background isolates');
    }
  }

  final DropAuthClient client;
  final GatewaySessionStore store;
  final DateTime Function() _now;
  final current = ValueNotifier<StoredGatewaySession?>(null);
  final message = ValueNotifier<String?>(null);
  StoredGatewaySession? _record;
  Future<void> _tail = Future<void>.value();
  Future<void>? _restoreFuture;
  Future<GatewayCredential>? _renewal;
  int _epoch = 0;
  bool _blocked = false;
  bool _logoutRequested = false;
  Future<void> _writes = Future<void>.value();

  int get generation => _epoch;
  static const terminalCodes = {
    'REFRESH_TOKEN_INVALID',
    'REFRESH_TOKEN_REUSED',
    'SESSION_REVOKED',
  };

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace stack) {});
    return next;
  }

  Future<void> restore() {
    final active = _restoreFuture;
    if (active != null) return active;
    late final Future<void> future;
    future = _serialize(_restore).catchError((Object error, StackTrace stack) {
      if (identical(_restoreFuture, future)) _restoreFuture = null;
      Error.throwWithStackTrace(error, stack);
    });
    _restoreFuture = future;
    return future;
  }

  Future<void> _restore() async {
    final saved = await store.read();
    if (saved != null) {
      final json = Map<String, dynamic>.from(jsonDecode(saved));
      if (json['session'] != null) {
        _record = StoredGatewaySession.fromJson(json);
      }
    } else {
      // One-time migration of this app's old bearer; never write new secrets to
      // preferences. Commit secure storage before deleting the legacy values.
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('erebrus_gateway_token');
      if (token != null && token.isNotEmpty) {
        await _save(
          StoredGatewaySession(
            session: DropAuthSession(
              token: token,
              userId: prefs.getString('erebrus_gateway_user_id') ?? '',
              role: 'user',
              walletAddress: prefs.getString('erebrus_gateway_wallet') ?? '',
            ),
            generation: _newGeneration(),
            method: prefs.getString('erebrus_gateway_auth_method') ?? 'legacy',
            mwaToken: prefs.getString('erebrus_gateway_mwa_token'),
          ),
        );
      } else {
        await _writeBlob(jsonEncode({'session': null}));
      }
    }
    await _removeLegacySecrets();
    if (!_blocked) current.value = _record;
  }

  Future<void> _removeLegacySecrets() async {
    final prefs = await SharedPreferences.getInstance();
    for (final suffix in [
      'token',
      'user_id',
      'wallet',
      'auth_method',
      'mwa_token',
    ]) {
      await prefs.remove('erebrus_gateway_$suffix');
    }
  }

  Future<void> _writeBlob(String value) {
    final write = _writes.then((_) => store.write(value));
    _writes = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace stack) {},
    );
    return write;
  }

  Future<void> _save(StoredGatewaySession record) async {
    // Logout's tombstone must win even while an earlier refresh is in flight.
    // Retain its replacement only in memory for the queued remote revocation.
    if (!_logoutRequested) await _writeBlob(jsonEncode(record.toJson()));
    _record = record;
  }

  /// Capture before a provider starts; logout or a newer login invalidates it.
  int beginLogin() {
    _blocked = true;
    return ++_epoch;
  }

  void finishLogin(int epoch) {
    if (epoch == _epoch) _blocked = false;
  }

  String get _requestGeneration => '${_record!.generation}:$_epoch';

  @override
  Future<void> validate(GatewayCredential credential) async {
    if (_blocked ||
        _record == null ||
        credential.generation != _requestGeneration) {
      throw _changed();
    }
  }

  Future<void> install(
    DropAuthSession session, {
    required int expectedGeneration,
    required String method,
    String? mwaToken,
  }) async {
    await restore();
    await _serialize(() async {
      if (expectedGeneration != _epoch) throw _changed();
      if (session.token.isEmpty) throw GatewayException('Missing access token');
      final previous = _record;
      if (previous != null) {
        final confirmed = await _revoke(previous);
        if (!confirmed) {
          message.value = 'Previous session revocation is unconfirmed.';
        }
      }
      if (expectedGeneration != _epoch) throw _changed();
      await _clearOrgSelection();
      _logoutRequested = false;
      await _save(
        StoredGatewaySession(
          session: session,
          generation: _newGeneration(),
          method: method,
          mwaToken: mwaToken,
        ),
      );
      if (expectedGeneration != _epoch) throw _changed();
      _blocked = false;
      current.value = _record;
    });
  }

  @override
  Future<GatewayCredential> authorize({GatewayCredential? rejected}) async {
    final epoch = _epoch;
    await restore();
    if (_blocked || epoch != _epoch || _record == null) throw _changed();
    final record = _record!;
    if (rejected != null && rejected.generation != _requestGeneration) {
      throw _changed();
    }
    // Every caller (including workers via the broker) waits for this commit.
    final active = _renewal;
    if (active != null) return _checkEpoch(await active, epoch);
    if (record.session.isRefreshable &&
        !record.session.expiresSoon(_now()) &&
        (rejected == null || rejected.token != record.session.token)) {
      return GatewayCredential(record.session.token, _requestGeneration);
    }
    late final Future<GatewayCredential> future;
    future = _serialize(() => _renew(epoch, rejected)).whenComplete(() {
      if (identical(_renewal, future)) _renewal = null;
    });
    _renewal = future;
    return _checkEpoch(await future, epoch);
  }

  GatewayCredential _checkEpoch(GatewayCredential credential, int epoch) {
    if (_blocked || epoch != _epoch) throw _changed();
    return credential;
  }

  Future<GatewayCredential> _renew(
    int epoch,
    GatewayCredential? rejected,
  ) async {
    if (_blocked || epoch != _epoch || _record == null) throw _changed();
    var record = _record!;
    if (rejected != null &&
        record.session.token != rejected.token &&
        !record.session.expiresSoon(_now())) {
      return GatewayCredential(record.session.token, _requestGeneration);
    }
    if (record.rotationPending || record.loginRequired) {
      throw GatewayException(
        'Session renewal could not be confirmed. Sign in again to reconnect.',
        errorCode: 'SESSION_LOGIN_REQUIRED',
      );
    }
    if (record.retryAt != null && _now().isBefore(record.retryAt!)) {
      throw GatewayException(
        'Session renewal is rate limited. Try again later.',
        statusCode: 429,
        retryAt: record.retryAt,
      );
    }
    if (record.session.refreshExpiresAt != null &&
        !record.session.refreshExpiresAt!.isAfter(_now())) {
      await _save(record.withSession(record.session, loginRequired: true));
      if (!_blocked && epoch == _epoch) current.value = _record;
      throw GatewayException(
        'Sign in again to renew this session.',
        errorCode: 'SESSION_LOGIN_REQUIRED',
      );
    }
    // Write ahead: a crash/timeout/5xx may occur AFTER server-side rotation.
    // A surviving pending marker forbids replay of that single-use credential.
    record = record.withSession(record.session, rotationPending: true);
    await _save(record);
    try {
      final replacement = record.session.isRefreshable
          ? await client.refreshSession(record.session.refreshToken!)
          : await client.upgradeSession(record.session.token);
      if (!replacement.isRefreshable ||
          replacement.token.isEmpty ||
          replacement.sessionId?.isNotEmpty != true ||
          replacement.expiresAt == null ||
          replacement.refreshExpiresAt == null) {
        throw GatewayException(
          'Incomplete session renewal response',
          outcomeUncertain: true,
        );
      }
      // Preserve wallet identity when the refresh endpoint omits it.
      final json = replacement.toJson();
      if (replacement.walletAddress.isEmpty) {
        json['wallet_address'] = record.session.walletAddress;
      }
      await _save(record.withSession(DropAuthSession.fromJson(json)));
      // A logout intent may have arrived while HTTP was in flight. Keep the
      // replacement for the queued revocation, but never publish it to callers.
      if (!_blocked && epoch == _epoch) current.value = _record;
      return GatewayCredential(_record!.session.token, _requestGeneration);
    } on GatewayException catch (e) {
      if (terminalCodes.contains(e.errorCode)) {
        await _clear();
        message.value = 'Your session expired. Please sign in again.';
      } else if (!e.outcomeUncertain &&
          (e.statusCode == null || e.statusCode! < 500)) {
        final needsLogin =
            !record.session.isRefreshable &&
            (e.statusCode == 401 ||
                e.errorCode == 'SESSION_ALREADY_REFRESHABLE');
        await _save(
          record.withSession(
            record.session,
            loginRequired: needsLogin,
            retryAt: e.retryAt,
          ),
        );
      }
      // Unknown outcomes retain the write-ahead marker and all user data.
      if (!_blocked && epoch == _epoch) current.value = _record;
      if (_record?.loginRequired == true) {
        throw GatewayException(
          'Sign in once to reconnect this legacy session.',
          errorCode: 'SESSION_LOGIN_REQUIRED',
        );
      }
      rethrow;
    } catch (_) {
      if (!_blocked && epoch == _epoch) current.value = _record;
      rethrow;
    }
  }

  @override
  Future<void> handleFailure(
    GatewayCredential credential,
    String? errorCode,
  ) async {
    if (!terminalCodes.contains(errorCode)) return;
    await _serialize(() async {
      if (!_blocked &&
          _record != null &&
          _requestGeneration == credential.generation &&
          _record?.session.token == credential.token) {
        ++_epoch;
        await _clear();
        message.value = 'Your session expired. Please sign in again.';
      }
    });
  }

  /// Invalidate immediately; serialize remote revoke after any ongoing rotation.
  /// Local logout succeeds offline too, with an explicit unconfirmed result.
  Future<bool> logout() {
    final epoch = ++_epoch;
    _blocked = true;
    _logoutRequested = true;
    current.value = null;
    final restored = restore();
    // Persist the logout intent without waiting for an HTTP refresh to finish.
    // A process death at any later point cannot resurrect the old account.
    final localClear = restored.then(
      (_) => _writeBlob(jsonEncode({'session': null})),
    );
    // The queue may still be waiting for HTTP; keep early storage errors handled
    // until the logout operation can report them to its caller.
    localClear.ignore();
    return _serialize(() async {
      await localClear;
      final record = _record;
      await _clear();
      final confirmed = record == null || await _revoke(record);
      if (epoch == _epoch) {
        message.value = confirmed
            ? null
            : 'Signed out on this device. Remote revocation is unconfirmed.';
      }
      return confirmed;
    });
  }

  Future<void> _clearOrgSelection() async {
    final prefs = await SharedPreferences.getInstance();
    for (final suffix in ['id', 'slug', 'name']) {
      await prefs.remove('erebrus_selected_org_$suffix');
    }
  }

  Future<bool> _revoke(StoredGatewaySession record) async {
    if (!record.session.isRefreshable) return false;
    try {
      await client.logoutSession(record.session.refreshToken!);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _clear() async {
    // Tombstone also prevents resurrection from partially removed legacy prefs.
    await _writeBlob(jsonEncode({'session': null}));
    _record = null;
    current.value = null;
    await _removeLegacySecrets();
    await _clearOrgSelection();
  }

  static String _newGeneration() => List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  GatewayException _changed() => GatewayException(
    'Session changed. Try again.',
    errorCode: 'SESSION_CHANGED',
  );
}
