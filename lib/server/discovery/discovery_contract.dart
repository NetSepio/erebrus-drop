class DiscoveryTxtRecord {
  const DiscoveryTxtRecord({
    required this.roomId,
    required this.roomName,
    required this.deviceName,
    required this.authRequired,
    required this.version,
    required this.capabilities,
    required this.availableBytes,
  });

  final String roomId;
  final String roomName;
  final String deviceName;
  final bool authRequired;
  final String version;
  final List<String> capabilities;
  final int? availableBytes;

  Map<String, String> toTxt() {
    return {
      'roomId': roomId,
      'roomName': roomName,
      'deviceName': deviceName,
      'auth': authRequired ? 'required' : 'open',
      'version': version,
      'caps': capabilities.join(','),
      if (availableBytes != null) 'free': '$availableBytes',
    };
  }
}

abstract interface class DiscoveryPublisher {
  Future<void> publish({
    required String serviceType,
    required String serviceName,
    required int port,
    required DiscoveryTxtRecord txt,
  });

  Future<void> stop();
}
