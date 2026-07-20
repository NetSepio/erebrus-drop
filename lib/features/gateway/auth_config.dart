import 'dart:io';

/// Reown (WalletConnect) project id — Android / iOS wallet login.
const kReownProjectId = String.fromEnvironment('REOWN_PROJECT_ID');

/// True when [kReownProjectId] was passed via --dart-define / .env.
bool get hasReownProjectId => kReownProjectId.isNotEmpty;

/// Google Sign-In server (web) client id. Its audience must be listed in the
/// gateway's GOOGLE_CLIENT_IDS. Empty => Google sign-in is hidden.
const kGoogleServerClientId = String.fromEnvironment(
  'GOOGLE_SERVER_CLIENT_ID',
  defaultValue:
      '743089346496-15iub9ug9b4jkqonokg2js80ndjv8nba.apps.googleusercontent.com',
);
bool get hasGoogleSignIn => kGoogleServerClientId.isNotEmpty;

/// Apple Sign-In Services id + redirect, needed only for the web/Android relay
/// flow; on iOS/macOS native Apple sign-in uses the app's capability instead.
const kAppleServiceId = String.fromEnvironment('APPLE_SERVICE_ID');
const kAppleRedirectUri = String.fromEnvironment(
  'APPLE_REDIRECT_URI',
  defaultValue: 'https://gateway.erebrus.io/api/v2/auth/apple/callback',
);

/// Erebrus webapp origin.
const kErebrusWebOrigin = String.fromEnvironment(
  'EREBRUS_WEB_ORIGIN',
  defaultValue: 'https://erebrus.io',
);
const kErebrusProductionOrigin = 'https://erebrus.io';

/// Webapp route the browser opens for sign-in.
const kErebrusDesktopAuthPath = '/auth';

/// Native deep link the webapp redirects to after auth.
const kErebrusAuthCallbackScheme = 'erebrusdrop';
const kErebrusAuthCallbackHost = 'auth';
const kErebrusAuthCallback = 'erebrusdrop://auth';

/// Gateway chain identifier for Solana wallet login.
const kSolanaChain = 'sol';

/// App path on the erebrus site for icons and MWA identity.
const kErebrusDropBasePath = '/drop';
const kErebrusDropLogoFile = 'logo.png?v=2';
const kErebrusDropLogoPath = '$kErebrusDropBasePath/$kErebrusDropLogoFile';

String _erebrusOriginBase(String webOrigin) =>
    webOrigin.replaceAll(RegExp(r'/+$'), '');

/// Trailing-slash site URL for WalletConnect / Reown metadata.
String erebrusSiteUrlFromOrigin(String webOrigin) =>
    '${_erebrusOriginBase(webOrigin)}$kErebrusDropBasePath/';

/// Publicly reachable icon for Reown / WalletConnect pairing metadata.
String erebrusSiteIconFromOrigin(String webOrigin) =>
    '${_erebrusOriginBase(webOrigin)}$kErebrusDropLogoPath';

/// MWA identity URI base.
String erebrusMwaIdentityUrlFromOrigin(String webOrigin) =>
    '${_erebrusOriginBase(webOrigin)}$kErebrusDropBasePath/';

const kErebrusMwaIconRelative = kErebrusDropLogoFile;

const kErebrusNativeRedirect = 'erebrusdrop://';
const kErebrusUniversalRedirect = 'https://erebrus.io/drop';

const kReownProjectIdMissingMessage =
    'REOWN_PROJECT_ID is not set. Add it via --dart-define=REOWN_PROJECT_ID=... '
    'or in a .env file, then rebuild the app.';

String reownOriginNotAllowedMessage(String relayOrigin) =>
    'Reown relay rejected this app (origin not allowed). In cloud.reown.com → '
    'your project → Allowlist, add: $relayOrigin and https://erebrus.io/drop — then '
    'wait ~15 minutes and restart the app.';

const kErebrusBundleId = 'com.erebrus.drop';
const kErebrusLinuxApplicationId = 'com.erebrus.drop';

/// Whether the current platform is a desktop OS.
bool get isDesktopPlatform {
  if (Platform.isAndroid || Platform.isIOS) return false;
  return Platform.isLinux || Platform.isMacOS || Platform.isWindows;
}
