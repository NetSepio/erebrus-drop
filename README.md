# erebrus-drop
A local-first, cross-device sharing app that allows a phone to become a temporary secure file server on the current Wi-Fi network or, where supported, on a device-created local hotspot.

## Implemented

This Flutter app is scaffolded directly in this repository with Android and iOS targets.

- Start a password-protected Drop Room on the current local network.
- Show a local Drop Link and QR code.
- Serve a bundled browser client from the phone-hosted HTTP server.
- Browser guests get a polished file-manager UI with icon controls, breadcrumbs, storage visualization, drag/drop upload, folder shortcuts, file rows, media cards, and demo-mode preview data.
- Browser guests can log in, browse folders, create folders, upload files, download files, paste text, view storage, and open stream links for audio/video files.
- The Flutter app includes Home, Rooms, Library, Smart Send, and Settings tabs.
- Native Manual Join can preview a Drop Link, authenticate, browse remote folders, create folders, send text, and download files.
- Android app clients can pick and upload files to the selected/default joined-room folder; iOS document-picker upload is next.
- QR scanner can read a Drop Code and feed the detected Drop Link into Manual Join.
- Android local-only hotspot can be requested from the Start Room flow, with SSID/password display when Android exposes them and a manual guide when the device denies hotspot creation.
- Room creators can choose a default upload folder; browser and app clients show/use that folder unless the user browses into a specific folder.
- First-run onboarding includes the 3 required slides from the product spec.
- Native platform channel contracts are in place for local IP discovery, storage stats, and future hotspot/local-network work.

See [docs/spec_coverage.md](docs/spec_coverage.md) for the current implementation map against the full product spec.

## Run

```sh
flutter pub get
flutter run
```

## Verify

```sh
flutter analyze
flutter test
```
