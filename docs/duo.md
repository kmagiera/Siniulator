# Duo integration and regression checks

Siniulator does not communicate with the Device Hub process, automate its UI,
or require it to be running. It talks to the simulator services directly:

- `SICoreSimulator` loads the local CoreSimulator and SimulatorKit frameworks
  dynamically. `SIDisplay` enumerates screens and observes their IOSurfaces.
- `SimulatorInput` sends digitizer and vendor-defined HID messages over XPC to
  the simulator. Hinge and orientation events identify the Virtualization
  provider and its `hinge-slider-control` / `orientation-picker-control` sources.
- SceneKit renders the model loaded from the selected local Xcode's DeviceKit
  plug-in. The app reads its mode icons there too; ordinary bezel artwork comes
  from `/Library/Developer/DeviceKit/Chrome`. No Apple artwork or model is copied
  into the repository or app bundle. Missing model resources use the ordinary
  framebuffer renderer; missing icons use system symbols.

The runtime selection is `DEVELOPER_DIR`, otherwise the newest Xcode found in
`/Applications` (with the selected Xcode preferred for equal versions), then
the `xcode-select` link as fallback. This is not simply the current SDK selected
by `xcode-select`. Build tools follow their own `DEVELOPER_DIR` / `xcode-select`
environment. Use an explicit `DEVELOPER_DIR` for compatibility testing.
Video recording passes the same selected developer directory to `xcrun` as
the command runner and dynamically loaded simulator frameworks. On a foldable
it also passes the currently connected screen ID, instead of relying on
`simctl` to guess between the cover and inner displays.

## Highest-risk boundaries

1. **Private simulator protocols.** Screen enumeration selectors, screen IDs,
   digitizer targets, vendor HID payloads and service names are not stable public
   APIs. Unit tests cannot prove that a new runtime still accepts them. Run the
   live smoke test for every supported Xcode/runtime pair.
2. **Framebuffer lifetime and panel switching.** A successful connection can
   initially have no surface; the runtime can replace it later. Surface callbacks
   must refresh the 3D material independently of the hidden 2D Metal drawable.
   Subscribe to both Duo panels up front and keep their textures alive during
   the camera orbit. Only input and screenshots change active sources at the
   handoff; the model keeps a stable unfolded viewport. An inactive panel with
   no surface must not erase the other panel. Tests inject late/replaced surfaces
   and stale queued callbacks, then inspect rendered colors, including the cover
   before handoff. The 2D renderer is suspended and transparent behind the model.
   Initial asynchronous connections retain their requested panel metadata;
   pose changes during startup are reconciled after that connection completes.
   Input is disabled while replacing a panel, with contacts released before
   handoff and before restoring the digitizer.
3. **Model schema, animation and hit testing.** Node names, fallback dimensions
   and animation times describe the currently installed V68 asset, not a public
   model contract. SceneKit mesh hit tests locate resize corners, cached by pose,
   orientation and viewport size. Pixel-derived reference corners independently
   verify the targets for all three presets, four orientations and two sizes.
   Touch input uses the display's posed triangles and UVs: the imported
   skinner's native SceneKit hit test misses visible pixels. `DuoScreenHitMesh`
   skins only the display vertices using presented bone transforms, caches an
   unchanged pose and intersects both windings. It preserves independent USD
   position/UV indices and does not add anything to the rendered scene. Metal
   texture coordinates are already top-origin; do not flip V again. Regression
   tests compare hit coordinates against an x/y-encoded framebuffer rendered
   in all three presets and four rotations. Synthetic mesh tests need no Apple
   assets and cover polygon/index formats, misses and changed bone transforms.
   Drags outside the screen clamp to its projected mesh boundary, with
   perspective-correct UV interpolation. Option-drag uses the same native UV
   coordinates; its markers are projected back onto the model in a separate
   non-interactive overlay so hiding the flat renderer does not hide them.
   Regression tests exercise Option-drag in all presets/rotations, ordinary
   iPhones with/without bezels, and Duo without bezels. The pending-connection
   test uses a suspended fake display opener, not a real simulator boot.
4. **AppKit layout.** Toolbar compactness, native window buttons, custom resize,
   screen rotation and retained window size interact. Test shrinking through the
   compact-toolbar threshold as well as repeated drags in all four corners.
   Measure traffic-light and native-action insets against the visible pill,
   including while it narrows. The right inset is a titlebar accessory, not an
   extra toolbar item (which adds an unwanted group gap).
   The stable unfolded SceneKit viewport is larger than the closed hardware.
   Its clear pixels are not an interactive window rectangle: `DeviceHostWindow`
   uses AppKit mouse-event passthrough outside the actual hardware, toolbar and
   four resize targets. Local/global mouse movement monitors restore input when
   returning from another app; a held drag or magnification keeps its owner.
   Fullscreen and bezel-free windows retain their ordinary rectangular region.
   Tests compare the region with rendered alpha and deliver resize event
   sequences directly to a test window for all 48 pose/orientation/corner pairs.
   The pill cannot become narrower than its closed-device width in the current
   orientation. Its single-row minimum reserves the measured title width to
   the left of the centered mode selector; below that window width it uses two
   rows. The compact window minimum keeps the selector clear of native actions.
   Test the entire closing sweep for non-increasing width, not just its presets,
   and check native buttons after AppKit's deferred layout as well as ours.
   The complete requirements and ownership boundaries are in [toolbar.md](toolbar.md).
5. **Pose selection and animation.** The native segmented control selects the
   middle item at every non-endpoint angle, independently of the 15° display
   handoff. Clicking that selected item still requests the 120° preset. One
   eased angle timeline drives HID, the model and selection; pinch input stays
   direct. Retargeting starts from the currently visible angle, and Reduce
   Motion applies the endpoint immediately.
   The camera begins turning at 140° closed (40° hinge opening), ahead of the
   inner panel dimming. It still crosses 45° at the 15°-open input handoff and
   finishes square-on at a fully closed hinge.
   Pinching across the 15° display handoff requests one native trackpad haptic
   synchronized with drawing. It rearms after moving 3° away from the handoff,
   preventing repeated pulses from jitter. Ending/cancelling a pinch and preset
   animations do not request haptics. AppKit decides whether the current device
   and user preferences permit feedback; verify the physical sensation manually
   with a Force Touch trackpad (unit tests only verify the trigger policy).

## Repeatable checks

```sh
DEVELOPER_DIR=/Applications/Xcode-27-beta.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode-27-beta.app/Contents/Developer scripts/check-duo.sh
DEVELOPER_DIR=/Applications/Xcode-26.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode-27-beta.app/Contents/Developer swift test --sanitize thread --filter ScreenEnumerationTests
python3 -m unittest discover -s scripts/tests
```

The live check requires a booted Duo and temporarily changes its pose/orientation,
then restores the saved window state. Artifacts go to `build/duo.*`, not app
resources. It exercises three modes, four rotations, hinge steps, queued corner
drags, Save/Copy Screen, and a recording whose dimensions must match the active
panel (allowing H.264's one-pixel trim to even dimensions). Render tests use only locally installed Apple assets
and skip when absent. Enumeration timeout tests use a stub adapter, not Apple
services, including 1,000 callbacks racing a zero-length deadline under Thread
Sanitizer. Synthetic resize events do not replace a final physical trackpad and
mouse check on an unlocked Mac.

The slow-close pass samples every degree from 40° to 0°, checks viewport and
2D-layer stability, and saves intermediate model frames every two degrees for
inspection. It also logs both framebuffer subscriptions. Unit tests cover
one-degree closing/opening steps in all four orientations. These checks do not
claim to capture every WindowServer-composited frame of a physical pinch.
The live test also checks selection throughout preset transitions, the selected
middle button from 60°, and retargeting an in-flight close without a pose jump.
