# XDR

A native Mac menu-bar app for display brightness, MacBook XDR boost and Night Vision.

## Controls

- Built-in XDR displays retain their native brightness and boost controls.
- The identified Tern 16-inch 4K IPS monitor uses a hardware brightness slider over USB-C DDC. It does not use gamma dimming or simulate XDR boost.
- Other unsupported external displays retain the software-dimming route.
- Night Vision provides a red viewing mode. Boost and Night Vision change appearance; neither is a colour-calibration tool.

The Tern slider updates its saved reconnect preset after the monitor confirms the value. The optional local reconnect helper is independent of this app; configuring it is not required to use the slider. Its saved preset is stored in `~/Library/Application Support/Tern Controls/defaults.json`.

## Build

Requires macOS 14 or later, Xcode and XcodeGen. Tern hardware control currently targets Apple Silicon Macs and the explicitly identified monitor.

```sh
./scripts/build-ddc.sh
xcodegen generate
xcodebuild -project XDR.xcodeproj -scheme XDR -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build
```

The DDC helper is built from the MIT-licensed source in `Vendor/m1ddc`; its executable is generated, not committed. KeyboardShortcuts and LaunchAtLogin are resolved through Swift Package Manager.

## Verify

The fast DDC scheduler regression uses a fake monitor process, so it can run without a physical display.

```sh
./tools/test-tern-ddc.sh
./scripts/build-ddc.sh
xcodegen generate
xcodebuild -project XDR.xcodeproj -scheme XDR -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO test
```

Automated tests do not establish physical brightness, speaker playback, colour accuracy or persistence after a monitor loses power. Hardware changes should be checked against monitor readback and the actual display.
