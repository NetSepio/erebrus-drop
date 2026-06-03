class StreamLink {
  const StreamLink({
    required this.url,
    required this.expiresAt,
    required this.warning,
  });

  final String url;
  final DateTime expiresAt;
  final String warning;
}

class MediaStreaming {
  StreamLink createStreamLink({
    required String baseUrl,
    required String fileId,
    required String token,
    Duration expiresIn = const Duration(hours: 2),
  }) {
    final expiresAt = DateTime.now().add(expiresIn);
    return StreamLink(
      url: '$baseUrl/api/files/$fileId/stream?token=$token',
      expiresAt: expiresAt,
      warning:
          'Anyone on this local network with this link can stream this file until the token expires.',
    );
  }
}
