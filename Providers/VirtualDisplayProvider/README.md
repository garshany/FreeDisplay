# VirtualDisplayProvider

Labs-only macOS virtual endpoint implementation. Runtime Objective-C lookup keeps private
SPI out of the public-only build. The provider probes without creating endpoints. Creation
requires explicit opt-in, safe mode off, a visible recovery display, validated dimensions,
and at most four session endpoints. Creation is serialized with deletion and cancellation
releases failed endpoints. A retained runtime object owns each endpoint. Online/active
status and actual pixel dimensions are polled before reporting successful creation;
removal is verified against online status. Removing the last active surface or a mirror
source without another independent active surface is denied.

Definitions accept 640–8192 × 480–8192 physical pixels, 24–120 Hz and even dimensions for
HiDPI. They are Codable for export, but are deliberately never recreated automatically
on startup, resume or app crash. Disabling opt-in prevents new creation; existing endpoints
retain explicit Remove controls. Recovery controls and physical topology are untouched.

## Integration

The existing XcodeGen target sources includes both Swift and Objective-C bridge files.
No bridging header is required. The application settings can embed
`VirtualDisplaysSettingsView(safeMode: <actual app safe-mode state>)` under
`#if !PUBLIC_API_ONLY`. Its session persists as long as that SwiftUI view identity persists;
move session ownership to AppModel if endpoints must survive Settings window teardown.
Do not automatically create endpoints from persisted definitions.

## Provenance

Original GPL-3.0-or-later implementation, using only SPI names and signatures documented
in the open-source Chromium test helper (BSD-3-Clause):
https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm
No source was copied; no BetterDisplay binaries, reverse engineering or assets were used.
Objective-C exception handling and selector preflight report unsupported/rejected macOS
behavior rather than claiming success. Private API presence is not a compatibility promise.

## Acceptance gaps

No endpoint was created on the user's hardware during development. Apple Silicon/Intel,
OS-specific private ABI, HiDPI pixel readback, detach latency, sleep/wake, capture routing,
and user-visible desktop usability require opt-in hardware acceptance. This is not full
BetterDisplay parity. Sidecar/AirPlay hosting, persistent display topology, custom timings,
EDID overrides and window relocation are not supplied by this provider.
