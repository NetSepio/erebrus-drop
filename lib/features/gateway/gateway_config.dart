/// Gateway base URL for the Erebrus network.
/// Override at build time via --dart-define=GATEWAY_URL=...
const String kDefaultGatewayUrl = 'https://gateway.erebrus.io';

/// Public IPFS gateway base URL.
const String kDefaultIpfsGatewayUrl = 'https://ipfs.erebrus.io';

const String _kGatewayUrlDefine = String.fromEnvironment(
  'GATEWAY_URL',
  defaultValue: '',
);

const String _kIpfsGatewayUrlDefine = String.fromEnvironment(
  'IPFS_GATEWAY_URL',
  defaultValue: '',
);

/// Resolves the gateway base URL: dart-define > production default.
String resolveGatewayUrl() {
  final fromDefine = _kGatewayUrlDefine.trim();
  if (fromDefine.isNotEmpty) return fromDefine;
  return kDefaultGatewayUrl;
}

/// Resolves the public IPFS gateway base URL: dart-define > production default.
String resolveIpfsGatewayUrl() {
  final fromDefine = _kIpfsGatewayUrlDefine.trim();
  if (fromDefine.isNotEmpty) return fromDefine;
  return kDefaultIpfsGatewayUrl;
}

/// Client label sent to the gateway for diagnostics.
String gatewayClientHeader() {
  // Drop app runs on all platforms; use a generic label.
  return 'erebrus-drop';
}
