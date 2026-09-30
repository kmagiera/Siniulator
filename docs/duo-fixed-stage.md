# Duo presentation

## Motion

Presets and pinch input retarget the same critically damped follower. One
display-link sample supplies hinge angle, camera orbit and device orientation
to rendering; the same angle drives native HID. Retargeting preserves position
and velocity. No delayed task or sleep starts the animation. Reduce Motion
applies the target immediately.

Pinch targets cover 0–40° and inner 110–180° hinge opening. The follower crosses
the excluded range continuously, but a gesture cannot stop halfway through the
camera turn. The 110° boundary includes a small margin above the successful
108° held/reversed transition measured on iOS 27.1. Recheck it for new runtimes;
it is not a public API guarantee. Preset buttons select their target immediately,
not the intermediate rendered pose.

`DuoPoseClip` reads the locally installed model's joint keyframes once and
samples their position, scale and quaternion tracks. Skeleton, projection and
touch hit testing use the same logical pose, not asynchronous presentation bones.
Cover and inner materials retain separate native texture transforms. The
departing panel is frozen once before HID can clear its live surface; both
panels remain textured while depth occlusion handles the visible handoff.

## Geometry and resizing

The rendering viewport is square on desktop and in fullscreen. Camera distance
fits the complete animated sweep once and does not depend on the cropped window.
Fullscreen centers a square in its safe available area and preserves the saved
desktop scale. Duo does not offer a bezel-free mode. Missing or unsupported model
resources use the ordinary framebuffer fallback, not a second 3D geometry path.

On desktop, projection translation and the skeleton share a SceneKit transaction.
The visible hardware stays 20 points below the toolbar. The window crops unused
rendering space, with 16-point outside/bottom margins. A 16-point internal backing
guard is removed from the visible layout; it is not additional window padding.
The precomputed skinned silhouette has a one-point interpolation/antialiasing
guard at the 700-point reference viewport, scaled with the device.

The toolbar uses `(2 * coverWidth + openWidth) / 3` in a fixed reference
orientation, clamped to the measured single-row control minimum. Only manual
device scaling changes its width; folding, rolling and panel switching do not.

All four visible frame corners resize proportionally. Resize excludes the
touchscreen, even within the 44-point corner candidate regions, and accepts only
a thin frame/outside-edge band. Handles are disabled during motion. Transparent
margins pass mouse events to other apps; entering the frame from outside restores
input and the cursor immediately. In-flight gestures retain their owner.

Cropping preserves a persistent toolbar anchor and uses even native window
widths to avoid cumulative AppKit rounding drift. Placement is constrained at
startup, manual resize and fullscreen exit, not on each animation frame. A phone
placed near a display edge may extend beyond it during a turn.

## Verification

`DuoStageTests` compare actual SceneKit pixels with the projected envelope,
including continuous folds, intermediate rolls and combined motion.
`DuoWindowGeometryTests` check anchor stability, saved bezel-free preferences and
one camera update per pose despite repeated layout. `DuoWindowRegionTests` check
frame-only ownership and deliver mouse-down/drag/up for all 48
preset/orientation/corner combinations. `DuoToolbarTests` verify the authored
weighted width across scales, folds and rolls.

See [duo.md](duo.md) for native integration checks and their limits, and
[toolbar.md](toolbar.md) for the toolbar ownership contract. Deterministic
snapshot exports verify pixels and geometry, not wall-clock presentation cadence.
