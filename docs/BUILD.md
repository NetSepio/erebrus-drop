# Building Erebrus Drop

## Mobile (Android / iOS)

```bash
flutter pub get
flutter run                    # Android debug (playstore flavor default)
flutter build appbundle --flavor playstore --release   # Google Play
flutter build apk --flavor dappstore --release         # Solana dApp Store
```

Signing: copy `android/key.properties.example` → `android/key.properties`.  
See [solana-dapp-store-release.md](solana-dapp-store-release.md) and [github-release.md](github-release.md).

## Desktop (macOS / Windows / Linux)

Erebrus Drop ships as a Flutter desktop app on all three platforms. The core
Drop Room server is pure Dart; native method channels fall back gracefully on
desktop where mobile-only APIs (hotspot, share sheet, Solana Mobile Wallet) are
unavailable.

### Prerequisites

| Platform | Requirements |
|----------|----------------|
| **macOS** | Flutter stable, Xcode command-line tools |
| **Windows** | Flutter stable, Visual Studio with C++ desktop workload |
| **Linux** | Flutter stable, `clang`, `cmake`, `ninja-build`, GTK 3 dev packages |

Run `flutter doctor` and enable the desktop platform you target.

### Dev

```bash
flutter pub get
flutter run -d macos      # or windows / linux
```

Shortcut on macOS:

```bash
./scripts/setup-macos-dev.sh
flutter run -d macos
```

### Release

```bash
./scripts/build-desktop.sh macos
./scripts/build-desktop.sh windows    # on Windows
./scripts/build-desktop.sh linux      # on Linux
./scripts/build-desktop.sh all        # macOS host; skips Win/Linux if unavailable
```

Artifacts land in `dist/`:

| Output | Contents |
|--------|----------|
| `erebrus-drop-macos-v*.zip` | `.app` bundle |
| `erebrus-drop-windows-v*.zip` | `Release/` folder with `.exe` |
| `erebrus-drop-linux-v*.tar.gz` | `bundle/` directory |

### Desktop notes

- **Hosting:** local HTTP server binds on the LAN; allow incoming connections in the OS firewall if prompted.
- **mDNS:** room discovery uses native bridges on mobile; desktop may need manual join via IP/QR until desktop mDNS is wired.
- **Folders:** use the in-app folder picker; paths are stored per platform.
- **Wallet:** Solana Mobile Wallet features are Android-only by design.

## Verify

```bash
flutter analyze
flutter test
```