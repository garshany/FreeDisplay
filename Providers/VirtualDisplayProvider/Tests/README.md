# No-hardware validation

`RuntimeRefusalTests.m` is a standalone Objective-C executable. It tests stable read-only
SPI probing, display-ID ABI against a fake NSObject, null-handle behavior and corrupt-input
rejection before WindowServer creation. Compile together with `../Sources/VirtualDisplayRuntime.m`
using clang ARC and Foundation/CoreGraphics. No valid virtual endpoint is requested.

`SessionGuardTests.swift` is a standalone async Swift executable compiled alongside the provider
Swift source and the bridge object, linking DisplayDomain and ProviderInterfaces. It checks
probe identity/capability/risk, opt-in refusal, safe-mode refusal, invalid definition refusal,
empty session state and idempotent removal of nonexistent IDs. It does not create displays.

The core suite's `VirtualDisplaySafetyPolicyTests` checks headless/owned-virtual/unknown-vendor
creation denial, built-in/vendor recovery evidence, last-screen removal denial, mirror-slave
removal denial and independent-active-surface acceptance. External vendor detection is an
explicit heuristic; a third-party virtual endpoint can advertise a vendor and is not proven
physical by public CoreGraphics alone.

Neither harness proves real successful create/applySettings/destroy, HiDPI physical/logical
readback, sleep/wake behavior, detach timeout or private ABI support on other macOS builds.
Those remain opt-in hardware acceptance requirements. No UI, display mode or physical topology
mutation is part of this test workflow.
