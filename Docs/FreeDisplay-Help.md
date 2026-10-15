# FreeDisplay help

FreeDisplay is an independent GPL-3.0 fork of OpenDisplay by aquitaine. There is no account,
trial, purchase or business-use gate. This guide describes the current Apple-silicon/macOS 14+
implementation. “Available in code” does not certify your monitor, dock, audio output or OS version.
Use About → Build Information to record the actual version, build, API surface and channel.

## Choose a task

| Task | Start here | Prerequisite, check and return path |
|---|---|---|
| Brightness and image adjustments | Menu → selected display; Settings → Displays | Verify the selected identity and method first. Compare the visible panel with the requested value and readback. Record the original level; restore that level explicitly. Software contrast/warmth affect the image, not the monitor's OSD contrast. Suspend retains non-brightness adjustments while brightness stays active; Reset Software Adjustments clears values including software dimming, preserving the suspension switch and boost. Neither is a factory monitor reset. |
| Keyboard, audio and feedback | Settings → Keyboard; On-screen display | Bind only after the control works manually. See [shortcut behavior](#keyboard-shortcuts). Inspect conflicts and registration failures; test another foreground app. Remove only your added chord to undo it. Restore Defaults also changes your other custom bindings. |
| Mode, refresh, HiDPI and favorites | Menu → selected display → resolution controls; Settings → Displays | Record the complete original logical/backing size, density, refresh and depth. Choose an actually offered tuple, inspect the result, and Keep only if the image and pointer work; otherwise Revert or allow the existing countdown. Favorites select offered modes; they cannot create an absent cable mode. Restore the original tuple explicitly later. |
| Display position and main display | Settings → Arrange | Retain a usable independent screen and record the original arrangement/main display. Verify pointer travel across edges and the keep/revert result. Restore the recorded positions/main display. Display geometry restoration does not restore app windows, Spaces or Universal Control device relationships. |
| ICC profiles | Selected display's color-profile controls | Note the exact current profile. Verify the assignment and visible colors after selection; restore that profile to undo. Factory reset is a separate explicit choice. Custom-profile gamma protection may block warmth/contrast; do not disable it just to make a shortcut work. |
| Missing/offline display, wake or panic | Settings → Diagnostics; menu recovery cards | Read [recovery and diagnosis](#recovery-and-diagnosis). Preserve a working access path before any disruptive action. |
| Automation, console, HTTP and external actions | Settings → Automation, Actions & Hooks; Tools → Show Console… | Inspect target and capabilities before mutation. [Command model](Automation-command-model.md), [transports](Integration-transports.md), [console](Console-and-diagnostics.md), [actions/hooks](Automation-actions-and-hooks.md). Disable the specific trigger/service and restore the original property; deleting a trigger does not undo a completed write. |
| Virtual workspace, capture and external recording | Settings → Virtual Displays; Screen Capture | [Independent recording workspace](FreeDisplay-Recording.md). Virtual creation is experimental/private and unavailable in public-only builds; ordinary capture is a public ScreenCaptureKit path. Keep a physical recovery screen. |
| TV controllers and input switching | Settings → Actions & Hooks → network controllers; existing per-display input controls | [TV controls](TV-control.md) documents currently qualified protocol paths and device checks. A network transport being public does not certify a TV. CEC, arbitrary input actions and unsupported vendor/device features are not implied. [Six-button recipe](FreeDisplay-Stream-Deck.md) explicitly gates FD-089 inputs. |
| Settings, deployment and languages | Settings → Application; About | [Privacy, deployment and translations](FreeDisplay-Operations.md). Export a settings backup before import/reset, inspect the preview, and retain the backup for targeted restoration. Settings backups are not monitor firmware or system-display backups. |
| Install or verify a build | About; trusted FreeDisplay release announcement | [Download verification](ReleaseVerification.md), [publisher checklist](FreeDisplay-Release-Checks.md). Source/ad-hoc builds and signed distribution have separate acceptance. |

## Keyboard shortcuts

Settings → Keyboard uses one shared recorder and registry for brightness standard/fine,
software contrast standard/fine, warmer/cooler, software reset/suspend, CoreAudio volume
standard/fine, toggle mute, explicit mute/unmute, menu, console, Settings, Quit and Restart,
as well as the existing recovery/display actions and input bindings. New families start unbound.
The recovery chord **⌃⌥⌘R** cannot be assigned to another action while recovery is enabled.
Conflicts are visible; only one owner registers a chord. Registration means macOS accepted it,
not that another application's keyboard listener cannot intercept it.

Standard/fine actions use the common Adjustment steps, independently of “fine by default” for
native media keys. Contrast uses its existing 50–150% span; warmth uses its existing kelvin span.
Held level actions follow system repeat events. Toggles, Quit and Restart execute once per press;
Quit/Restart act directly and run the ordinary teardown/recovery path. Choose deliberate chords.
The console shortcut toggles the same owned console window; closing it preserves session history.

Image actions select the brightness-key targets. Suspension retains contrast/warmth and leaves
brightness active; changing a suspended value updates what Resume will apply. CoreAudio shortcuts
select the configured audio targets and the separately enabled native fallback, independently of
native-key engagement and “leave mute to macOS”. They require writable, readable native controls;
a DDC-only or unresolved target is reported unavailable and is never silently replaced by another
output. Explicit Mute/Unmute are idempotent and never become volume-zero emulation or a toggle.
A native volume device may quantize the common requested step to its supported increments.
Volume completion sound follows its preference once on release, rather than on every repeat.

Carbon custom shortcuts need no Accessibility permission. Native media-key interception/focused-window
targeting and external Stream Deck hotkey injection have their own permission requirements.
Gamma-exponent, inversion, Night Shift/True Tone, keyboard backlight and HDR/upscaling action
families have no qualified shared binding here; the catalog does not promise them or invent success.
DDC input bindings remain a separate existing hardware path, not FD-089's future native input actions.

## Recovery and diagnosis

1. Copy build information and record the exact action/time, selected identity, mode tuple, route,
   cable/dock/KVM, HDR state and unrelated screens. Save settings before changing policies.
2. Refresh enumerates what macOS currently reports. Reconnect All restores displays FreeDisplay
   logically disconnected. Neither requests a new physical output slot nor guarantees physical
   redetection of a cable/adapter absent from macOS. Virtual screens and disabling the built-in
   panel do not raise the Mac chip's native display limit; check that exact Mac's specifications.
3. For missing modes, compare the same display directly connected and through the dock/KVM,
   preserving HDR/rate and monitor picture settings. If a mode is no longer offered, protection
   cannot manufacture it. Inspect the reported failure before another disruptive attempt.
4. For text clarity, distinguish logical points, backing pixels and physical panel/transport data.
   HiDPI normally renders 2× per axis: 1920×1080 points can use 3840×2160 backing pixels. A 5K
   screenshot on a 4K panel is not proof of a 5K cable signal. Unreported link timing stays unknown.
   Compare equal logical sizes at different density, application zoom and panel processing settings.
5. For load or lag, record source/mode/dimensions, capture on/off, equivalent workload, CPU and GPU
   separately, menu/Settings visibility, and duration. Compare smaller HiDPI rendering and recorder
   settings one variable at a time. Nominal refresh, delivered frames, repeated frames and input
   latency are different measurements; no benchmark or improvement is asserted by this guide.
6. A bright hardware cursor under overlay dimming differs from a mini-LED optical halo. Check the
   active dimming method; neither gamma nor an overlay creates more physical backlight zones.
7. For wake window movement, isolate virtual screens, capture, mirroring and layout protection one
   at a time, recording which restoration action preceded the event in Diagnostics. A longer delay
   can postpone movement. For DCP/Crossbar panics, preserve the full panic locally and distinguish
   observations from hypotheses; subsystem names do not prove FreeDisplay caused the failure.
   Compare a direct-display baseline with the app quit. Sleep prevention is a mitigation, not a fix.
8. Use Tools → Show Console… / Diagnostics logging for a local reproduction, then export diagnostics.
   Clear Console clears transcript/retained logs, not settings/history. Startup diagnostic modes and
   retention are described in [console help](Console-and-diagnostics.md). Review every included
   artifact and `redaction.json` before sharing. Reports/screenshots are not raw HDMI packet traces.

FreeDisplay runs after login. Neither its login item, virtual screens, modes nor export-only EDID
plans fix FileVault preboot or Recovery display resolution. Keep a known usable unlock screen.
Sidecar is an OS-owned Mac display; Universal Control connects devices running their own apps.
FreeDisplay does not manage Universal Control relationships. EDID/custom HiDPI plans are export-only,
not installed overrides. Public-only builds exclude private DDC/native/virtual/lifecycle adapters;
permissions cannot enable a feature removed from that build. No destructive system reset is the
first troubleshooting step.

Protected video can be black because of capture protection, but not every black frame is DRM.
Virtual displays do not provide HDCP or bypass service requirements; use a supported physical route.
Check the source and permission independently. macOS notification settings for mirroring/sharing
have global scope across sharing applications; change them deliberately and inspect the recipient
preview. A separate virtual desktop alone does not protect private notifications.

## Support routing

About links to FreeDisplay's [source](https://github.com/garshany/FreeDisplay),
[releases](https://github.com/garshany/FreeDisplay/releases),
[issues](https://github.com/garshany/FreeDisplay/issues), license and privacy information.
File fork behavior with the FreeDisplay maintainer, including build, reproduction and reviewed
artifacts. Upstream OpenDisplay is credited separately; it is not the fork's support/update channel.
Experimental/source builds are not validated stable releases. No separate internal-build feed,
chat community or translation portal is asserted. Translation contributions use the fork's source
review process, described in [operations](FreeDisplay-Operations.md).
