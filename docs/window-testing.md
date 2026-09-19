# Testing

## Automated checks

```sh
swift test
swift test -c release
python3 -m unittest discover -s scripts/tests
scripts/check-release-diagnostics.sh
```

Swift tests cover input, geometry, scaling, appearance, native controls, captures
and recording. AppKit tests create local windows without booting a simulator.
Fullscreen uses AppKit's behind-window composition and never resolves or opens
the configured wallpaper URL, whether it points to a system or user file.
Script tests use temporary files and stubbed external tools; they do not build,
sign, notarize or publish an app. The diagnostics check builds Debug and Release
and inspects both binaries to ensure test hooks stay out of normal releases.

Default-app tests check URL routing, native settings controls, and association
changes through a fake workspace. They do not change the system's `devices://`
handler or launch Device Hub; macOS consent and the real association change must
be checked from the built app's Settings window.

See [Render benchmark](render-benchmark.md) for rendering performance and image
comparisons against a hardware-specific baseline.

## Real simulator interaction

To verify CoreSimulator notifications and the shutdown-on-window-close setting
with a temporary device, run:

```sh
SINIULATOR_TEST_RUNTIME=RUNTIME_IDENTIFIER SINIULATOR_TEST_DEVICE_TYPE=DEVICE_TYPE_IDENTIFIER swift test --filter DeviceMonitorIntegrationTests
```

This checks external create, rename, boot, shutdown and delete events, and closes
native simulator windows with shutdown enabled and disabled. It creates and deletes
only its own device. Without these environment variables, the test is skipped.

List installed runtime and device-type identifiers with `xcrun simctl list runtimes`
and `xcrun simctl list devicetypes`, then run:

```sh
scripts/test-integration.sh RUNTIME_IDENTIFIER DEVICE_TYPE_IDENTIFIER
```

This creates a temporary simulator, installs the interaction fixture, and checks
real UIKit touches, multitouch, rotation, screenshots, recording and shutdown.
It deletes the temporary simulator on exit. Results go to
`build/integration-results`; an optional third argument selects another directory.

## Window checks

Close Siniulator and unlock the macOS session before these checks. Scripts build
a Debug app and save logs and screenshots under ignored `build/` directories.
Diagnostic launches ignore saved window state for that process, so a previous
crash cannot block tests with AppKit's window-restoration dialog.
Pointer drivers need permission to post events. External Screen Recording access
enables WindowServer screenshots; without it, command checks still run and image
checks are skipped. AppKit snapshots alone cannot verify glass or desktop effects.

### Fullscreen

Leave a simulator booted and run:

```sh
scripts/check-fullscreen-chrome.sh 0 light
scripts/check-fullscreen-chrome.sh 0 dark
```

The optional display index follows `NSScreen.screens` (default `0`). Appearance
defaults to `system`; light/dark overrides affect only the test app. The backdrop
comes from WindowServer through `NSVisualEffectView`; the app does not load a
wallpaper image itself.

The test enters a native fullscreen Space, checks header/menu-bar hover, native
controls, live appearance changes and stable device geometry, then exits through
the original green button. It compares toolbar background captures with a maximum
RGB difference of 1/255. It uses the running guest without installing a fixture.
Split View geometry has unit coverage; arranging a real Split View pair remains
a manual check.

### Toolbar

```sh
CODE_SIGN_IDENTITY=- scripts/check-toolbar.sh
```

A local window with the production `NSToolbar` checks Home, Screenshot, both
rotations (including Option-click), Stop Recording and disabled finalization in
light/dark and wide/compact layouts. It uses no simulator. Inspect the idle,
hover and pressed screenshots in `build/native-toolbar.*`; they are not compared
against golden images.

### Rotation after resizing

Leave a simulator booted and run:

```sh
scripts/check-rotation.sh
```

The test checks that percentage scaling and manual resizing preserve the custom
scale through all orientations, with and without bezels. It restores the guest's
orientation, bezel preference and window frame without installing a fixture.

### Startup

Leave a simulator booted and run:

```sh
CODE_SIGN_IDENTITY=- scripts/build-app.sh debug
open -n -W build/Siniulator.app --args -ApplePersistenceIgnoreState YES --startup-smoke --output-dir build/startup-smoke
```

Checks that launch opens every running simulator and that loading devices show
an in-screen spinner without the retry button. Loading-canvas snapshots use
AppKit; composed screenshots require Screen Recording access for the Debug app.
