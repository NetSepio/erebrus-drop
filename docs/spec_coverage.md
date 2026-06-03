# Erebrus Drop Spec Coverage

## Implemented in this repo

- Flutter Android/iOS app scaffold in the repository root.
- Package/bundle identity: `com.erebrus.drop`.
- Dark Material 3 theme in `lib/ui/theme/drop_theme.dart`.
- Home, Rooms, Library, Smart Send, and Settings tabs.
- Start Drop Room flow on current network.
- Password-protected room auth with PBKDF2-HMAC-SHA256.
- Local HTTP server on port `8787` with fallback ports through `8799`.
- Browser Drop Link and QR code.
- Bundled browser SPA in `assets/web/drop_client/`.
- Browser login, polished file manager UI, breadcrumbs, icon controls, folder shortcuts, storage visualization, drag/drop upload, file list, folder creation, raw file upload, download, text paste, and media stream links.
- Browser multi-select for files, bulk file downloads, and upload progress with percent, speed, and ETA.
- HTTP range request support for streamed file responses.
- Storage snapshot via platform channel when available, with short cache/single-flight protection to avoid repeated scans during transfers.
- First-run onboarding with the required three slides.
- Manual native Join flow can preview `/api/room`, authenticate to `/api/auth/login`, list remote files, create folders, send text, and download files.
- Android app clients can multi-pick and upload files to the selected/default joined-room folder, with progress, speed, and ETA.
- Native joined-room downloads show progress, speed, and ETA.
- QR scanner reads raw Drop Links and spec JSON Drop Code payloads, then opens Manual Join.
- Android local-only hotspot can be requested through the platform channel; unsupported/OEM-denied devices show a manual guide.
- Android foreground hosting service keeps a room higher priority while it is live.
- App lifecycle-aware refresh avoids background UI polling while a room is being served.
- Room creators can choose a default app-managed upload folder.
- Default permission mode is `Drop folder only`, scoping guests to the creator-selected drop folder.
- Android host-folder picker can request and persist a user-granted Storage Access Framework tree URI from Settings.
- Android/iOS platform-channel methods for local IP and storage stats.

## Files added for next spec phases

- `lib/features/host/host_folder_service.dart`
- `lib/features/join/join_room_service.dart`
- `lib/features/nearby/nearby_room_service.dart`
- `lib/features/host/hotspot_service.dart`
- `lib/features/host/room_runtime_service.dart`
- `lib/features/smart_send/ocr_service.dart`
- `lib/features/smart_send/share_intake_service.dart`
- `lib/features/library/library_repository.dart`
- `lib/features/settings/drop_settings.dart`
- `lib/features/media/media_streaming.dart`
- `lib/server/discovery/discovery_contract.dart`
- `lib/server/streaming/range_request.dart`

## Still needs plugin/native/device implementation

- mDNS/DNS-SD discovery publishing and browsing.
- Full external host-folder storage adapter:
  - Android SAF tree list/read/write/delete/rename implementation for hosted rooms.
  - iOS Files/iCloud/File Provider folder picker and security-scoped URL list/read/write implementation.
- iOS document-picker upload for joined rooms.
- Share sheet intake.
- Offline OCR through Android ML Kit and iOS Vision.
- Persistent metadata database.
- Server-to-server push/pull transfer.
- Multipart upload handler matching the exact API spec.
- ZIP/folder bundle download for selected folders or very large multi-file downloads.
