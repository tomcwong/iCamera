# AndroidApp

Android build outputs for iCamera.

## Build the APK

From the project root (`iCamera/`):

```bash
# Debug APK
flutter build apk --debug
# Output: build/app/outputs/apk/debug/app-debug.apk

# Release APK
flutter build apk --release
# Output: build/app/outputs/apk/release/app-release.apk
```

Then copy the APK here:
```bash
copy build\app\outputs\apk\release\app-release.apk AndroidApp\builds\
```

## Source code location

The Android platform code lives in `android/` at the project root.
Flutter requires that folder to remain at the root — moving it breaks `flutter build apk`.

## Install to device

```bash
flutter install
# or
adb install builds\app-release.apk
```
