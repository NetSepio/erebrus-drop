import 'gateway_config.dart';
import 'gateway_http.dart';
import 'gateway_models.dart';

/// Wallet/social auth against the Erebrus gateway (v2).
class DropAuthClient {
  DropAuthClient({String? gatewayUrl})
      : _base = GatewayHttp.normalizeBase(gatewayUrl ?? resolveGatewayUrl());

  final Uri _base;

  String get baseUrl {
    final port = _base.hasPort ? ':${_base.port}' : '';
    return '${_base.scheme}://${_base.host}$port';
  }

  /// `GET /api/v2/auth` — fetch a challenge for [walletAddress].
  Future<DropAuthChallenge> fetchAuthChallenge({
    required String walletAddress,
    String chain = 'sol',
  }) async {
    final uri = GatewayHttp.apiUri(
      _base,
      path: '/api/v2/auth',
      query: {'wallet_address': walletAddress, 'chain': chain},
    );
    final map = await GatewayHttp.getJson(uri);
    return DropAuthChallenge(
      challengeId: (map['flow_id'] ?? '').toString(),
      message: (map['message'] ?? '').toString(),
    );
  }

  /// `POST /api/v2/auth` — complete wallet-signature login.
  Future<DropAuthSession> authenticate({
    required String challengeId,
    required String signature,
    required String publicKey,
    String? referralCode,
  }) async {
    final body = <String, dynamic>{
      'flow_id': challengeId,
      'signature': signature,
      'public_key': publicKey,
    };
    final ref = referralCode?.trim();
    if (ref != null && ref.isNotEmpty) {
      body['ref'] = ref;
    }
    final map = await GatewayHttp.postJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/auth'),
      body,
    );
    return DropAuthSession(
      token: (map['token'] ?? '').toString(),
      userId: (map['user_id'] ?? '').toString(),
      role: (map['role'] ?? 'user').toString(),
      walletAddress: publicKey,
    );
  }

  /// `GET /api/v2/orgs` — list organizations the caller belongs to.
  Future<List<DropOrg>> fetchOrgs(String bearerToken) async {
    final list = await GatewayHttp.getJsonList(
      GatewayHttp.apiUri(_base, path: '/api/v2/orgs'),
      bearerToken: bearerToken,
    );
    return list
        .whereType<Map<dynamic, dynamic>>()
        .map((e) => DropOrg.fromJson(Map<String, dynamic>.from(e)))
        .where((o) => o.id.isNotEmpty)
        .toList();
  }

  /// `POST /api/v2/orgs` — create a new organization.
  Future<DropOrg> createOrg({
    required String bearerToken,
    required String name,
    required String slug,
  }) async {
    final map = await GatewayHttp.postJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/orgs'),
      {'name': name.trim(), 'slug': slug.trim().toLowerCase()},
      bearerToken: bearerToken,
    );
    return DropOrg.fromJson(map);
  }
}

class DropAuthChallenge {
  const DropAuthChallenge({required this.challengeId, required this.message});
  final String challengeId;
  final String message;
}

class DropAuthSession {
  const DropAuthSession({
    required this.token,
    required this.userId,
    required this.role,
    required this.walletAddress,
  });
  final String token;
  final String userId;
  final String role;
  final String walletAddress;
}
