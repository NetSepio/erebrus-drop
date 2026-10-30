/// Gateway tokens are opaque (including PASETO); expiry comes from metadata.
class DropAuthSession {
  const DropAuthSession({
    required this.token,
    required this.userId,
    required this.role,
    required this.walletAddress,
    this.tokenType = 'Bearer',
    this.expiresIn,
    this.expiresAt,
    this.refreshToken,
    this.refreshExpiresIn,
    this.refreshExpiresAt,
    this.sessionId,
  });

  final String token;
  final String userId;
  final String role;
  final String walletAddress;
  final String tokenType;
  final int? expiresIn;
  final DateTime? expiresAt;
  final String? refreshToken;
  final int? refreshExpiresIn;
  final DateTime? refreshExpiresAt;
  final String? sessionId;

  factory DropAuthSession.fromJson(
    Map<String, dynamic> json, {
    String? walletAddress,
    DateTime? now,
  }) {
    final receivedAt = (now ?? DateTime.now()).toUtc();
    final expiresIn = int.tryParse('${json['expires_in']}');
    final refreshExpiresIn = int.tryParse('${json['refresh_expires_in']}');
    return DropAuthSession(
      token: (json['access_token'] ?? json['token'] ?? '').toString(),
      userId: (json['user_id'] ?? '').toString(),
      role: (json['role'] ?? 'user').toString(),
      walletAddress:
          walletAddress ??
          (json['wallet_address'] ?? json['wallet'] ?? json['public_key'] ?? '')
              .toString(),
      tokenType: (json['token_type'] ?? 'Bearer').toString(),
      expiresIn: expiresIn,
      expiresAt:
          _expiry(json['expires_at']) ??
          (expiresIn == null
              ? null
              : receivedAt.add(Duration(seconds: expiresIn))),
      refreshToken: json['refresh_token']?.toString(),
      refreshExpiresIn: refreshExpiresIn,
      refreshExpiresAt:
          _expiry(json['refresh_expires_at']) ??
          (refreshExpiresIn == null
              ? null
              : receivedAt.add(Duration(seconds: refreshExpiresIn))),
      sessionId: json['session_id']?.toString(),
    );
  }

  bool get isRefreshable => refreshToken?.isNotEmpty == true;
  bool expiresSoon(DateTime now) =>
      expiresAt == null ||
      !expiresAt!.isAfter(now.toUtc().add(const Duration(seconds: 60)));

  Map<String, dynamic> toJson() => {
    'access_token': token,
    'user_id': userId,
    'role': role,
    'wallet_address': walletAddress,
    'token_type': tokenType,
    'expires_in': expiresIn,
    'expires_at': expiresAt?.toUtc().toIso8601String(),
    'refresh_token': refreshToken,
    'refresh_expires_in': refreshExpiresIn,
    'refresh_expires_at': refreshExpiresAt?.toUtc().toIso8601String(),
    'session_id': sessionId,
  };

  static DateTime? _expiry(dynamic value) {
    if (value == null) return null;
    final number = num.tryParse(value.toString());
    if (number != null) {
      // The gateway uses Unix seconds; also tolerate Unix milliseconds.
      return DateTime.fromMillisecondsSinceEpoch(
        (number < 100000000000 ? number * 1000 : number).round(),
        isUtc: true,
      );
    }
    return DateTime.tryParse(value.toString())?.toUtc();
  }
}

/// Captured for each request so retries cannot cross an account boundary.
class GatewayCredential {
  const GatewayCredential(this.token, this.generation);
  final String token;
  final String generation;
}

abstract interface class GatewaySessionAuthorization {
  Future<GatewayCredential> authorize({GatewayCredential? rejected});
  Future<void> validate(GatewayCredential credential);
  Future<void> handleFailure(GatewayCredential credential, String? errorCode);
}
