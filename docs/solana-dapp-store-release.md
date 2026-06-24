# Solana dApp Store Release Guide

Reference for Erebrus Drop wallet integration and dual Android store publishing.

## Wallet (Solana phones only)

On Saga, Seeker, and other Solana Mobile devices, Settings shows an optional
**Connect wallet** card at the top. Normal iOS and Android phones see no wallet
UI. The wallet address is display-only and does not gate Drop Room features.

MWA identity:

- URI: `https://erebrus.io`
- Icon: relative `favicon.ico` (wallets resolve to `https://erebrus.io/favicon.ico`)
- Cluster: `mainnet-beta`

Wallet apps append the icon path to the identity URI (they do not resolve `../`).
Do not use parent-directory icon paths.

For the orange Erebrus Drop launcher icon instead of the site favicon, host
`assets/images/erebrus-flat.png` at `https://erebrus.io/mwa-icon.png` and set
`MWA_ICON_RELATIVE_URI` to `mwa-icon.png` in `SolanaWalletBridge.kt`.

Native identity verification (recommended): publish Digital Asset Links at
`https://erebrus.io/.well-known/assetlinks.json` for package `com.erebrus.drop`.
See `docs/hosting/assetlinks.json.example`.

## Android flavors

| Flavor | Output | Signing | Store |
|--------|--------|---------|-------|
| `playstore` | AAB | `playstore.*` in `key.properties` | Google Play |
| `dappstore` | APK | `dappstore.*` in `key.properties` | Solana dApp Store |

Debug builds default to `playstore`, so `flutter run` on Android works without
`--flavor`. iOS is unaffected.

Configure both signing blocks in a single file:

```text
android/key.properties
```

Template: `android/key.properties.example`

## Signing key commands

### Generate dApp Store keystore (separate key — required)

You cannot reuse the Google Play signing key for the Solana dApp Store.

```sh
keytool -genkeypair -v \
  -keystore android/release-keys/erebrus-drop-dappstore.jks \
  -alias erebrus-drop-dappstore \
  -keyalg RSA -keysize 4096 -validity 25000
```
Use these values when prompted:

```text
First and last name: NetSepio LLC
Organizational unit: Erebrus Drop
Organization: NetSepio LLC
City: Tbilisi
State: Tbilisi
Country code: GE
```
`Generating 4096-bit RSA key pair and self-signed certificate (SHA384withRSA) with a validity of 25,000 days
for: CN=NetSepio LLC, OU=Erebrus Drop, O=NetSepio LLC, L=Tbilisi, ST=Tbilisi, C=GE`

Fill the `dappstore.*` block in `android/key.properties`.

### Solana publisher wallet (portal / CLI)

Used when minting release NFTs and submitting to the
[Publisher Portal](https://publish.solanamobile.com):

### Inspect keystores

```sh
keytool -list -v -keystore android/release-keys/erebrus-drop-playstore.jks
keytool -list -v -keystore android/release-keys/erebrus-drop-dappstore.jks
```

## Build commands

```sh
# Debug Android (defaults to playstore)
flutter run

# Debug iOS (unchanged)
flutter run

# Google Play release
flutter build appbundle --flavor playstore --release

# Solana dApp Store release
flutter build apk --flavor dappstore --release
apksigner verify --print-certs build/app/outputs/flutter-apk/app-dappstore-release.apk
```

Expected outputs:

```text
build/app/outputs/bundle/playstoreRelease/app-playstore-release.aab
build/app/outputs/flutter-apk/app-dappstore-release.apk
```

## Submit a new app

1. Create publisher account at https://publish.solanamobile.com
2. Connect publisher wallet and complete KYC/KYB
3. Upload signed APK from the `dappstore` flavor build
4. Complete portal signing flow for Arweave upload and release NFT minting

Docs: https://docs.solanamobile.com/dapp-store/submit-new-app