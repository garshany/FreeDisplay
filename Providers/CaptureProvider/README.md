# CaptureProvider

Original GPL-3.0-or-later implementation using public Apple ScreenCaptureKit and Core Image.
The provider's capability probe stays unknown; it does not request access at startup.
`CapturePanel` (app module) owns opt-in PIP sessions and `CubeLUT` provides a bounded parser.

Integration: place `CapturePanel()` in a settings section. Existing Xcode source-directory
and CaptureProvider dependencies pick up the new files automatically.

The user presses **Load sources** (macOS may request Screen Recording permission), chooses
one display or another application's window, and presses **Start PIP**. Display capture
excludes this process's application windows to prevent feedback. Audio is disabled. Frames
remain in memory; there is no recording, network, automatic startup or saved source ID.
The floating preview supports crop/zoom, horizontal flip, 90-degree rotation and standard
0...1-domain 3D `.cube` LUTs (2...64 dimensions, 16 MB limit). Nonstandard domains, 1D LUTs,
nonfinite/out-of-range samples and inconsistent sample counts are rejected.

Close/Stop/section disappearance stops capture. The stream delegate reports system failures;
a two-second source-presence check stops streams whose source disappears. Permission errors
are shown with a System Settings/relaunch hint. No permission is silently granted.

Validation:
```
xcrun swiftc -module-cache-path /tmp/opendisplay-capture-cache Providers/CaptureProvider/Sources/CubeLUT.swift Providers/CaptureProvider/Tests/CubeLUTChecks.swift -o /tmp/opendisplay-cube-checks
/tmp/opendisplay-cube-checks
```
Standalone Swift 6 app-file typecheck and parser checks passed. Actual TCC grant, window/display
stream delivery, unplug/close behavior, protected video and HDR/color fidelity remain unverified.
Capture is SDR BGRA, capped at 1920 on the longest edge and 30 fps. Transformations affect this
preview, not physical display output. It is not a virtual-display creation or calibrated HDR path.

Public API references:
- https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
- https://developer.apple.com/documentation/screencapturekit/sccontentfilter
- https://developer.apple.com/documentation/coreimage/cifilter/1437975-init

## Synthetic rendering validation (2026-10-13)

All capture controls/status/errors supplied by the app now use Russian text. Underlying macOS
error descriptions and application/window titles retain the system/user's original language.

The production preview calls `CaptureImageTransform.apply`, which the synthetic harness exercises:
```
xcrun swiftc -module-cache-path /tmp/opendisplay-capture-cache Providers/CaptureProvider/Sources/CubeLUT.swift Providers/CaptureProvider/Sources/CaptureImageTransform.swift Providers/CaptureProvider/Tests/CaptureTransformChecks.swift -o /tmp/opendisplay-transform-checks
/tmp/opendisplay-transform-checks
```
Verified on generated pixels: identity, horizontal reflection and double reflection, all three
quarter-turn dimension changes and inverse rotations, crop geometry, crop clamp/NaN handling,
identity LUT pixel preservation and inversion LUT red-to-cyan pixels. Uses software Core Image
rendering and checks that the input contains real nonzero pixels. In the restricted shell sandbox,
Core Image returned zeros; the render harness must run with ordinary local rendering access.
An authorized unsandboxed synthetic run passed. It never invokes a screen capture API.
Quarter-turn transforms use exact integer matrices to avoid floating-point edge drift.

Lifecycle was reviewed and tightened: Stop invalidates in-flight startup generations; late source
checks and errors validate the original generation; old stream callbacks check stream identity;
old window-close callbacks check panel identity; deinit cancels watchdog and requests stream stop;
old async stop completion cannot overwrite a newer session's status. These are code-review and
strict Swift 6 compile results, not a live TCC/source-loss/close/deinit runtime test. Those still
require the user's capture permission and root's explicit UI acceptance session.
