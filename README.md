# Erebrus Drop

Current version: `1.0.5+5`

Erebrus Drop is a local-first file and text sharing app for nearby devices. A
phone can create a temporary Drop Room on the current Wi-Fi network or hotspot,
and other devices can join from the mobile app or a browser without an account
or cloud upload.

[Get Erebrus Drop on Google Play](https://play.google.com/store/apps/details?id=com.erebrus.drop)

## What It Does

- Create a local Drop Room over Wi-Fi or hotspot.
- Discover nearby Drop Rooms with mDNS on Android and iOS.
- Share files, folders, text, and streamable media on the local network.
- Receive Android and iOS share-sheet text and files into Smart Send or a live room.
- Join from the app, a QR code, a Drop Link, or the bundled browser client.
- Download selected browser files or folders as ZIP bundles.
- Connect WebDAV clients to a live Drop Room through the `/dav` endpoint.
- Scan Drop Room QR codes with native Android and iOS camera scanners.
- Pull files from a joined room directly into a live hosted room.
- Use optional room passwords and scoped folder access.
- Save received files to the platform-appropriate user-visible location.
- Transfer locally without analytics, tracking, accounts, or cloud relay.

## App Surfaces

- Home: start or resume the current Drop Room.
- Rooms: discover and join nearby Drop Rooms.
- Library: view, share, and delete hosted files.
- Smart Send: send quick text into a room.
- Settings and About: app details, privacy, terms, and NetSepio ethos.

## Release

Current release version:

```text
1.0.5+5
```

Android release versioning:

- The number after `+` is the Android `versionCode`.
- Google Play permanently reserves any uploaded `versionCode`, even if the
  draft/release is discarded.
- Always increase the `+` build number before uploading another AAB.

The Android package id is:

```text
com.erebrus.drop
```

Android release signing uses a local upload keystore configured through:

```text
android/key.properties
```

Do not commit signing secrets. The template lives at:

```text
android/key.properties.example
```

Build the Play Store bundle with:

```sh
flutter build appbundle --release
```

The release bundle is generated at:

```text
build/app/outputs/bundle/release/app-release.aab
```

## Development

Install dependencies:

```sh
flutter pub get
```

Run the app:

```sh
flutter run
```

Verify:

```sh
flutter analyze
flutter test
```

## Native QR Scanner

The app uses its own platform-channel QR scanner instead of a third-party
Flutter scanner plugin. Android uses CameraX with ZXing QR decoding. iOS uses
AVFoundation QR metadata scanning. The scanner returns the raw Drop Link or Drop
Code to Flutter, where the existing join parser validates and opens the room.

## Local Network Debugging

Browse for advertised Drop Rooms on macOS:

```sh
dns-sd -B _erebrusdrop._tcp local
```

Resolve a discovered room:

```sh
dns-sd -L "<device name>" _erebrusdrop._tcp local
```

Check the room API:

```sh
curl http://<room-ip>:8787/api/room
```

## Privacy

Erebrus Drop is designed for local device-to-device transfer. NetSepio does not
collect analytics, advertising identifiers, contact lists, location history,
account profiles, transferred files, pasted text, folder contents, room
passwords, or Drop Links.

Erebrus Platform, brand, and apps are products of NetSepio.
