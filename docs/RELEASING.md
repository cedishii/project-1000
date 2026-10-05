# Releasing

## Versions

The version is in `pubspec.yaml`:

```yaml
version: 1.0.0+1   # <version name>+<build number>
```

For every release, raise the version name (1.0.0 → 1.0.1 for fixes,
1.1.0 for features) **and** the build number (+1 → +2). Android refuses
to install an update whose build number is not higher. Add an entry to
`CHANGELOG.md`.

## Source, development builds and release builds

| | What | Who it's for |
|---|---|---|
| Source code | This repository | Developers |
| Development build | `flutter run`, debug APKs (debug-signed, slower) | Testing only, never published |
| Release build | `flutter build … --release`, signed with the release key | Users |
| Distribution artifacts | APK/AAB files attached to a GitHub Release | Users |

## Android

### Release signing key (one time)

Every update of an installed app must be signed with **the same key**.
If the key is lost, existing installs cannot be updated; users would
have to uninstall (after exporting a backup) and reinstall.

The key lives **outside** the repository:

```text
C:\Users\cedri\dev\keys\project-1000-release.jks
```

and is referenced by `android/key.properties` (ignored by git):

```properties
storeFile=C:/Users/cedri/dev/keys/project-1000-release.jks
storePassword=…
keyAlias=project1000
keyPassword=…
```

**Back up the `.jks` file and its password** to a safe place, such as a
password manager plus an offline copy. Never commit either one.

To create a new key on another machine:

```bash
keytool -genkeypair -v -keystore project-1000-release.jks -storetype PKCS12 \
  -keyalg RSA -keysize 4096 -validity 36500 -alias project1000
```

### Build

```bash
flutter clean
flutter build apk --release --split-per-abi   # arm64-v8a, armeabi-v7a, x86_64
flutter build apk --release                   # universal APK (all phones, larger)
flutter build appbundle --release             # .aab for Google Play
```

Output:

```text
build/app/outputs/flutter-apk/app-arm64-v8a-release.apk   ← most phones
build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk ← older 32-bit phones
build/app/outputs/flutter-apk/app-release.apk             ← universal
build/app/outputs/bundle/release/app-release.aab          ← Google Play only
```

Check before publishing:

```bash
# Signed with the release key (not "Android Debug"):
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
# No internet permission:
aapt dump permissions build/app/outputs/flutter-apk/app-release.apk
```

### Publish on GitHub Releases

```bash
git tag v1.0.0
git push origin main --tags
gh release create v1.0.0 \
  dist/project-1000-v1.0.0-arm64-v8a.apk \
  dist/project-1000-v1.0.0-armeabi-v7a.apk \
  dist/project-1000-v1.0.0-universal.apk \
  --title "Project: 1000 v1.0.0" --notes-file dist/RELEASE_NOTES.md
```

(Copy and rename the APKs into `dist/` first. `dist/` is ignored by
git.)

**Installing from GitHub on a phone:** open the release page, download
the APK (`arm64-v8a` for almost all phones from the last several years,
`universal` if unsure), open it, and allow "Install unknown apps" for
your browser when Android asks.

## iOS

iOS builds need a **Mac with Xcode**. Apple does not allow freely
downloadable app files: an `.ipa` from GitHub **cannot** be installed on
an arbitrary iPhone. The realistic options are:

| Option | Requirements | Notes |
|---|---|---|
| Run on your own iPhone from Xcode | Mac + free Apple ID | Free-account installs expire after 7 days and must be re-installed |
| TestFlight | Apple Developer Program (US$99/year) | Up to 10,000 testers by invite link; builds expire after 90 days |
| App Store | Apple Developer Program + App Review | Normal public distribution |
| Ad Hoc | Apple Developer Program | Only for registered device IDs (up to 100 per device type per year) |

Steps on the Mac:

```bash
flutter pub get
cd ios && pod install && cd ..
open ios/Runner.xcworkspace   # set your Team under Signing & Capabilities
flutter build ipa --release
```

Then upload `build/ios/ipa/*.ipa` with Xcode's Organizer or the
Transporter app. The bundle ID is `io.github.cedishii.project1000`.
The photo-library and camera permission texts are already in
`ios/Runner/Info.plist`.

For the App Store privacy questionnaire: the app collects **no data**.
