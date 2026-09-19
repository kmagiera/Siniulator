# Simulator toolbar contract

This contract applies to ordinary devices and Duo. A new toolbar requirement
should change the sizing model or the AppKit adapter, not add geometry to the
window controller, renderer or gesture handler.

## User-visible requirements

- Keep real system close/minimize/zoom buttons and real `NSToolbarItem` actions.
  Preserve their targets, accessibility, hit testing, group hover and appearance.
- Home, Screenshot/Stop Recording and Rotate stay on the right in a wide bar.
  Option-Rotate reverses rotation. Finishing a recording disables its action.
- Duo alone gets a separate native segmented control, exactly at the bar's
  horizontal center. Both endpoints select their respective item; every other
  angle selects the middle item. Clicking that selected item still requests the
  partially open preset. The toolbar does not own the hinge animation.
  In fullscreen the same selector is hosted by a centered native toolbar item,
  above the content window, and returns to the custom pill on exit. Do not leave
  it beneath the native titlebar or create a second, independently selected copy.
- An inset Duo pill contracts symmetrically around the same center. It cannot
  be narrower than its closed-device width in the current orientation, or its
  single-row content minimum (unless the window itself is narrower).
- Reserve the measured title/runtime width before the centered group. Prefer a
  pill wider than small hardware over overlapping text. When the window cannot
  fit a single row, put the combined title above the controls. The compact
  window minimum keeps the centered modes and right actions disjoint.
- A pose change alone must not change the number of toolbar rows, resize the
  host window, change device scale or add space above the device.
- Ordinary narrow toolbars keep their native actions centered in the second
  row. Devices without Duo support retain normal simulator multitouch.
- Fullscreen and bezel-free presentation use the full available width, not an
  inset pill. Fullscreen retains native window/menu reveal, safe-area insets,
  opaque matching titlebar background and a stationary device canvas.
- Respect light/dark appearance and Reduce Motion. Load Duo icons from the
  selected local Xcode, with SF Symbol fallbacks; do not bundle Apple artwork.
- Blank toolbar space drags the window; its double-click retains window zoom.
  Native controls and the centered segmented control must not become drag zones.

## Ownership

| Component | Responsibility | Must not do |
| --- | --- | --- |
| `SimulatorToolbarMetrics` / `SimulatorControlBarLayout` | Pure sizing, content reservations, row threshold and pill-width policy | Read views, mutate windows, retain gesture history |
| `SimulatorControlBar` | Measure labels/selector, draw the surface/title, apply computed custom-view rectangles, dispatch presets | Reposition native widgets or calculate separate resize thresholds |
| `SimulatorToolbar` | Native action items and capture-action state/validation | Calculate pill size or manipulate titlebar accessories |
| `NativeToolbarHost` | Attach/detach native toolbar, apply row style and trailing inset, reconcile inset traffic lights and their hover region | Reparent window buttons, replace native actions, send synthetic hover events |
| `FullScreenChrome` | Observe native reveal and match fullscreen background/title appearance | Recalculate toolbar width or mutate accessory size from geometry observations |
| `DevicePresentationView` / `DeviceResizeSession` | Consume the same metrics for canvas placement, sizing and resize | Invent their own toolbar-content width |

`buttons` in the pure layout is the native action **reservation**. AppKit owns
the actual frames. `modes` is the actual custom-view rectangle, so centering is
not recalculated by the view. There is no combined pseudo-width for actions
plus Duo modes.

## The AppKit boundary

AppKit positions standard window buttons relative to the whole window. An
inset pill therefore needs a horizontal translation. The adapter captures
native offsets after toolbar installation, keeps the existing parent/targets,
and reconciles again after AppKit's deferred frame changes.

AppKit caches the group-hover region separately from the button frames. The
adapter translates that region using public tracking-area APIs while retaining
its native owner, options and userInfo. It restores the original region and
button positions on detach or fullscreen entry. Repeated layout must leave
exactly one group-hover region, not accumulate copies or translations.

This is the most OS-sensitive part. It is deliberately isolated and covered by
native-window tests; replacing the widgets with lookalike buttons is not an
acceptable fallback. The trailing accessory reserves only the pill's actual
inset; there is no extra correction added to AppKit's trailing margin.

## Verification

- `ToolbarLayoutContractTests`: content non-overlap across title lengths and
  widths; centered modes; closed-width floor; history-independent sizing;
  pose changes cannot change row count; attached/fullscreen styles.
- `NativeWindowChromeTests`: actual native parents, actions, hit testing and
  group-hover regions after deferred layout, compact transitions, fullscreen
  handoff, detach and idempotent reattachment. Also selection and capture state.
  The fullscreen Duo regression checks each segment's hit target, native toolbar
  ownership, centering and identity across repeated fullscreen/normal handoffs.
- `ControlBarTests`, `ResizeTests`, `PresentationTests`, `AppearanceTests`:
  resize thresholds, canvas gap/scale, title reveal and appearance.
- `DuoModelTests` / `scripts/check-duo.sh`: every pose and rotation, continuous
  folding, no width rebound, native controls inside the pill, corner resizing,
  framebuffer stability and Save/Copy Screen.
- Run unit tests with both the current beta and an older Xcode without Duo.
  Finally check real fullscreen entry/exit and native clicks on an unlocked Mac;
  a synchronous geometry assertion alone is not sufficient.
