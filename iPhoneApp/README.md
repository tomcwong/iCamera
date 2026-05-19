# iPhoneApp

iOS build outputs for iCamera.

## Build the IPA (via GitHub Actions)

Push to `main` branch or trigger manually:
- Go to https://github.com/tomcwong/iCamera/actions
- Run "iOS Build — iCamera" workflow
- Download artifact: `iCamera-iOS-unsigned`
- Sideload to iPhone with Sideloadly (free Apple ID)

## Build locally (requires macOS)

From the project root (`iCamera/`):

```bash
flutter build ios --release --no-codesign

# Package IPA
mkdir -p build/ios/ipa/Payload
cp -r build/ios/iphoneos/Runner.app build/ios/ipa/Payload/
cd build/ios/ipa && zip -r ../iCamera.ipa Payload/
```

Then copy the IPA here:
```bash
cp build/ios/iCamera.ipa iPhoneApp/builds/
```

## Source code location

The iOS platform code lives in `ios/` at the project root.
Flutter requires that folder to remain at the root — moving it breaks `flutter build ios`.

## Sideloading

1. Download `iCamera-iOS-unsigned` artifact from GitHub Actions
2. Open Sideloadly on your PC/Mac
3. Connect iPhone with USB
4. Drag the IPA into Sideloadly
5. Sign in with your Apple ID
6. Click "Start"
7. Trust the certificate on iPhone: Settings → General → VPN & Device Management
