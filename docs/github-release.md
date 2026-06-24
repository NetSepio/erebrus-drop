# GitHub Releases (sideload builds)

CI verifies the repo on every PR and `main` push. Releases are created manually
from GitHub Actions — no local tagging and no repository secrets required.

## What runs automatically

| Workflow | Trigger | Does |
|----------|---------|------|
| CI | PR, push to `main` | `flutter analyze`, `flutter test` |
| Release | Manual **Actions → Release → Run workflow** | verify → build APKs → tag → GitHub Release |

## Create a release

1. Ensure `version:` in `pubspec.yaml` is correct (e.g. `1.0.5+5`).
   The Git tag is derived from the semver only: `v1.0.5`.
2. Commit and push to `main`.
3. Open **GitHub → Actions → Release → Run workflow**.
4. Download APKs from **GitHub → Releases** when the run finishes.

Re-running the workflow for the same `pubspec` version moves the `v1.0.5` tag
to the latest commit and refreshes the release assets.

## APK outputs

| File | Use |
|------|-----|
| `erebrus-drop-playstore-v*.apk` | General Android testing |
| `erebrus-drop-dappstore-v*.apk` | Solana Mobile / Seeker testing |

These are release-mode builds signed with an ephemeral CI key. They are for
sideloading and QA only — not for Google Play or Solana dApp Store submission.

Store publishing stays manual; see `docs/solana-dapp-store-release.md`.