# LinkPress (Android)

Paste or share a video link, or pick videos from the phone, choose 1080p / 720p / 480p / 360p / 240p,
and the compressed MP4 lands in `Movies/LinkPress` (or `Download/LinkPress`), where the Samsung
Gallery shows it right away.

## Get the APK

**Easiest: GitHub Actions.** Push this folder to a GitHub repo. The workflow in
`.github/workflows/android-apk.yml` builds the APKs. Open the run under the Actions tab and download
`linkpress-apk`. On a Samsung Galaxy, install `app-arm64-v8a-release.apk` (or the universal `app-release.apk`).

**On your own PC:**

1. Install [Flutter](https://docs.flutter.dev/get-started/install) and Android Studio (it brings the Android SDK and JDK 17).
2. In this folder run:
   ```bash
   flutter pub get
   flutter test
   flutter build apk --release --split-per-abi
   ```
3. APKs are in `build/app/outputs/flutter-apk/`. Copy one to the phone and open it
   (allow "Install unknown apps" for My Files when Android asks), or with USB debugging on: `flutter install`.

The release build is signed with the debug key so it installs right away. Before publishing to the
Play Store, add your own signing key in `android/app/build.gradle.kts`.

## How it works

| Part | File |
|---|---|
| Resolution rules (upscale warning, size estimate), same numbers as the desktop app | `lib/core/resolution.dart` |
| Probe + compress with ffmpeg-kit (H.264/AAC, Lanczos scale, bitrate cap) | `lib/core/media.dart` |
| Batch queue (1 to 100+), probing ahead, cancel/retry, saved across restarts | `lib/core/queue.dart` |
| yt-dlp (youtubedl-android), share-to-app, file picker, MediaStore export | `android/app/src/main/kotlin/app/linkpress/mobile/MainActivity.kt` |
| Foreground service so batches keep going with the screen off | `android/app/src/main/kotlin/app/linkpress/mobile/KeepAliveService.kt` |
| Bento UI on the project design system | `lib/ui/` |

Large files: picked videos are read in place through their `content://` URI (no copy), and every
step streams storage to storage, so a 10 GB file uses no more RAM than a small one. It does need
free space for the compressed output; the app checks before starting each video.

Links: video and audio are downloaded as separate streams (the smallest ones that still cover your
target) and merged during compression, so there is only one encode.
