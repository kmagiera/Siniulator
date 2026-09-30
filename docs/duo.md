# Duo integration and regression checks

Siniulator communicates directly with simulator services. The Apple Device Hub
process need not be running and is not automated or queried by the application.

- `SICoreSimulator` loads CoreSimulator and SimulatorKit dynamically. `SIDisplay`
  enumerates screens and observes their IOSurfaces.
- `SimulatorInput` sends digitizer and vendor-defined HID over XPC. Fold and
  orientation messages identify the Virtualization provider and its
  `hinge-slider-control` / `orientation-picker-control` sources.
- SceneKit loads the selected Xcode's DeviceKit model and mode icons at runtime.
  Ordinary bezel artwork comes from `/Library/Developer/DeviceKit/Chrome`.
  No Apple artwork is copied into the repository or app bundle. Missing or
  unsupported models use the framebuffer renderer; missing icons use SF Symbols.

Runtime selection uses `DEVELOPER_DIR`, otherwise the newest Xcode in
`/Applications` (preferring the selected Xcode for equal versions), then
`xcode-select`. Build tools follow their own developer-directory environment.
Do not pin `DEVELOPER_DIR` for ordinary launches; use it deliberately for
compatibility testing. Recording and simulator commands use the selected runtime
directory. Duo recordings explicitly select the connected screen ID.

## Highest-risk boundaries

1. Private screen selectors, screen IDs, digitizer targets, service names and
   HID payloads can change. Unit tests cannot establish compatibility with a new
   runtime; run native integration checks for each supported Xcode/runtime pair.
2. Initial connections may have no surface, and the runtime can replace or clear
   surfaces later. Observe both panels, keep separate material bindings, and
   freeze the departing panel before HID. A missing inactive surface must not
   clear the other material. Queued callbacks retain their connection's panel
   metadata; input is disabled while changing digitizers. Tests inject delayed,
   replaced and cleared surfaces and inspect rendered colors.
3. Node names, joint tracks and animation times describe the installed model,
   not a public schema. The skeleton and CPU UV hit mesh share logical transforms.
   UV mapping preserves independent indices and native panel rotation. Projection,
   sweep bounds and touch mapping share validated vertex, bone and weight decoding.
   Tests compare hits with an x/y-encoded rendered framebuffer, including drags outside
   the screen and Option-drag markers. Malformed mesh data must remain validated.
4. AppKit layout and pointer ownership are separate from the square rendering
   surface. Normal windows crop to hardware with a stable toolbar anchor; clear
   margins pass through to other apps. Frame-only resize uses the same predicate
   for mouse-down and cursor selection. Local/global pointer monitors are needed
   for entry from an ignored margin; a frontmost-window check protects other
   apps' cursors. Fullscreen owns its rectangular region. Duo cannot hide bezels;
   ordinary phones retain their bezel-free presentation.
5. One display-link follower drives preset and gesture motion, preserving
   velocity on reversal. Legal pinch targets skip the automatic camera turn.
   Delayed native display cancellation requires checking held targets after a
   dwell, not just immediate surface availability. The current legal boundaries
   are 40° and 110°; details are in [duo-fixed-stage.md](duo-fixed-stage.md).
   Preset selection updates immediately. Trackpad haptics retain their handoff
   hysteresis; unit tests verify trigger policy, not the physical sensation.

## Repeatable checks

```sh
swift test
swift test --configuration release
scripts/check-duo.sh
python3 -m unittest discover -s scripts/tests

# Deliberately pin Xcode for a compatibility run.
DEVELOPER_DIR=/Applications/Xcode-27-beta.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode-26.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode-27-beta.app/Contents/Developer swift test --sanitize thread --filter ScreenEnumerationTests

# Requires an already booted Duo and an unlocked home screen.
DUO_LIVE_UDID="your-duo-udid" DUO_LIVE_ARTIFACTS=/tmp/duo-live swift test --filter DuoLiveTests
DUO_HANDOFF_UDID="your-duo-udid" DUO_HANDOFF_ARTIFACTS=/tmp/duo-handoff swift test --filter DuoHandoffLiveTests.testHeldPinchTargetsKeepTheVisiblePanelActive
```

The smoke script temporarily changes the device's pose/orientation, then restores
its state. It checks presets, rotations, continuous hinge samples, corner drags,
Save/Copy Screen and recording dimensions (allowing H.264's one-pixel trim to
even dimensions). Artifacts stay in ignored `build/duo.*` output, not app resources.

The ordinary rotation and presentation smoke scripts select only booted
non-foldable devices; use `check-duo.sh` for the foldable geometry and bezel policy.

Render tests use locally installed Apple assets and skip when unavailable. Native
window tests deliver resize events for all four corners in each preset and
orientation. Enumeration timeout tests use a stub service, including concurrent
callbacks; these are not real simulator boot tests.

Tests that use diagnostic motion/capture hooks run only in Debug. Release still
exercises the production mesh decoder, render geometry, motion and toolbar sizing.

`DuoLiveTests` uses the production display link for presets, immediate button
selection, mid-turn pinch reversal and four orientation changes. Its timing
report measures CPU pose updates and callback intervals. It also exports
deterministic SceneKit frames with real panel textures; this is not a wall-clock
screen recording and does not prove GPU presentation cadence.

`DuoHandoffLiveTests` checks held targets and repeated boundary reversals, waiting
for native transitions to settle before inspecting active display IDs and image
brightness. Run it on an unlocked home screen. Its calibration test is opt-in
and may intentionally probe failing angles inside the excluded turn range.

Finish with real fullscreen entry/exit, physical pinch and mouse dragging on an
unlocked Mac. Neither hidden-window snapshots nor synthetic resize events replace
that check. See [toolbar.md](toolbar.md) for native widget and sizing ownership.
