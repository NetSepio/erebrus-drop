# Persistent gateway sessions

`DropAuthService` continues to expose ValueNotifiers for login, organizations,
provider availability and errors. `GatewaySessionRepository` owns credentials;
`GatewayHttp` supplies the shared protected-request wrapper. Existing wallet,
email, Google, Apple, browser callback and clipboard entry points all install
sessions through the repository. Successful provider responses preserve every
gateway expiry/session field. Access tokens remain opaque; no JWT decoding is used.

## Native storage and lifecycle

The complete session, identity, wallet adapter credential, absolute expiries,
rotation journal and retry deadline are committed as one secure-storage item.
Legacy preferences are migrated once, after a successful secure write, and their
old credential keys are removed. A secure tombstone prevents migration from
resurrecting an explicitly cleared session. Organization selection preferences
contain only non-secret organization metadata.

`flutter_secure_storage` uses app-specific Android storage/Keystore and an
unsynchronized, device-only Keychain service on Apple platforms. No Keychain
access group or credential is shared with other Erebrus apps. Android backup is
disabled. Native desktop plugin registrations and Apple entitlements are included;
Linux builds need `libsecret-1-dev` and runtime needs an unlocked Secret Service
keyring. See the [secure-storage package](https://pub.dev/packages/flutter_secure_storage).

Startup restores local state before online discovery. The existing app resume
observer calls `revalidateSession`; every protected request also authorizes
through the repository. Access expiring within 60 seconds triggers renewal.
Suspended apps require no background timer. A locked/unavailable secure store
fails closed and is retried when the app resumes.

## Rotation and failure recovery

Concurrent foreground requests share one renewal future. The replacement secure
write completes before any waiter receives the new access token. Requests retain
their account generation; delayed responses cannot update a switched account.
An explicit 401 `ACCESS_TOKEN_EXPIRED` renews and retries once, reusing a replacement
that another request already committed. JSON bodies and idempotency keys are
encoded once; uploads reopen the same source stream. Refresh, upgrade and logout
use raw requests and never recursively intercept themselves.

A durable rotation marker is written **before** refresh/legacy upgrade. If the
server rotates and the response is lost, replay could revoke the whole session.
An uncertain timeout, disconnect, malformed success, failed replacement commit,
5xx, or process death therefore leaves the marker in place and requires a fresh
login to reconnect. Auth and user data remain available; the client never blindly
retries the potentially consumed credential. A connection failure known to occur
before transmission is safe to try again on a later request. A 429 is a definite
rejection: its Retry-After deadline is persisted, and another attempt is allowed
after that deadline. Retry-After seconds and HTTP dates are supported.

Only `REFRESH_TOKEN_INVALID`, `REFRESH_TOKEN_REUSED` and `SESSION_REVOKED` erase
an established session automatically. Business errors, generic 401s, network
errors, 429 and 5xx preserve it and the organization/file state. Expired refresh
metadata and unrecoverable legacy credentials expose a Reconnect action without
discarding user data. A still-valid legacy bearer is upgraded once via
`POST /api/v2/auth/session`. Expired legacy access or 409
`SESSION_ALREADY_REFRESHABLE` requires one fresh login.

Browser/clipboard callbacks accept the access-token aliases and follow this same
legacy upgrade path. **Browser refresh tokens are never imported**: independent
Erebrus applications must own independent sessions. A modern bearer supplied
without its app's refresh credential cannot be upgraded; the gateway's 409
requires a new login through a native provider. A browser handoff must provide an
app-specific legacy bearer; this app cannot mint one or recover a missing modern
refresh credential from the gateway contract given here.

## Logout and account switching

Logout immediately invalidates the in-memory generation and writes a secure
tombstone, even while refresh HTTP is in flight. The operation queue waits for any
rotation, then revokes the latest replacement credential. A late response can
supply the credential for revocation but cannot restore auth or overwrite the
tombstone. Local clearing succeeds offline; the UI reports remote revocation as
unconfirmed. Account switching and provider completions use the same queue and
generation checks. Logout also invalidates pending browser callback state.

## Background isolates

The root isolate creates one owner per normalized gateway URL using
`GatewaySessionBroker.owner`. Background isolates must use the broker:

```dart
final client = DropGatewayClient(
  authorization: GatewaySessionBroker(),
);
final files = await client.fetchMyFiles();
```

For a custom gateway, pass the same `gatewayUrl` to both the client and broker.
Only access credentials and generation checks cross isolate ports. Never read
secure storage, pass a refresh token to a worker, or construct another repository
in a worker. An unavailable owner fails closed instead of electing a second owner.

## Platforms and verification

This repository has Android, iOS, macOS, Windows and Linux targets. It does not
have a Flutter Web runner and depends on `dart:io`. The secure-store adapter rejects
web use. A future web port needs a server-side browser session with HttpOnly
cookies; the plugin's browser storage must not be treated as native secure storage.

Automated coverage lives in `gateway_session_repository_test.dart`,
`gateway_session_http_test.dart`, `gateway_session_lifecycle_test.dart` and the
existing auth/navigation tests. It exercises restart/resume after 25 hours,
concurrent root/worker requests, committed rotation, one-time request replay,
legacy migration/upgrade, revoked/reused tokens, uncertain outcomes, storage
failure, offline logout, Retry-After and logout/account-switch races. Local HTTP
fixtures exercise the real transport and all four gateway login exchanges.
Verification on this change: all 170 Flutter tests pass, the macOS debug build
passes, and `integration_test/gateway_session_storage_test.dart` passes against
the real macOS Keychain using a dedicated test key. Android/iOS device storage and
live provider flows still need smoke testing with the configured gateway and
signing identities.

```sh
flutter analyze --no-pub
flutter test --no-pub
flutter build macos --debug --no-pub
flutter test integration_test/gateway_session_storage_test.dart -d macos --no-pub
```
