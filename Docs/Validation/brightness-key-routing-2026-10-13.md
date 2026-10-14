# Brightness and key routing review

Original implementation under GPL-3.0-or-later; no proprietary source or assets used.

A persisted per-display software override prevents successful DDC reads from selecting hardware brightness. This addresses monitors that acknowledge VCP writes without changing the picture. Software brightness uses the existing gamma/overlay/combined dimming composer, including warmth composition. Override selection persists, while dim level remains session-only and the existing quit recovery restores gamma/removes overlay.

Brightness Carbon shortcuts (Shift-F1 down, Shift-F2 up) and media keys share the configured target policy. External-only selects an active external or does nothing; it never falls back to the internal screen. Optional Shift gating passes unmodified native brightness events to macOS. Volume continues to follow the audio output. The emergency reconnect shortcut remains separate and unchanged.

Event-tap creation failure passes keys to macOS, reports actual capture status, and retries while enabled; disabling stops the tap and cancels retries. No new system permissions are requested unless media capture is enabled. Shortcut registration and TCC operation require runtime validation; core policy tests do not prove capture or physical brightness effect.

Validation: 32 focused core tests passed, including external-only behavior, Shift gating, legacy settings decode and roundtrip, existing key routing, and shortcut registry behavior. App compilation and real monitor/keyboard/TCC validation are separate acceptance gates.

## Expanded checks and Russian build

90 focused tests passed in isolated scratch directory `/tmp/opendisplay-brightness-deep-tests` (log `/tmp/opendisplay-brightness-deep.log`). Suites: BrightnessMonitor 4, Dimming 14, KeyboardShortcutRegistry 12, MediaKeyTargetPolicy 12, MediaKey 6, SettingsStore 33, XDRBrightnessPolicy 9.

Function evidence:

- `MediaKeyAction.from`, `isVolume`, `isBrightness`, `sign`, `signedDelta`, `acceptsModifiers`: mapping, direction/step, Shift gating, volume exemption.
- `MediaKeyTargetPolicy.target`: under-cursor, main, built-in, external-only, inactive/missing displays, audio routing and volume capability gating.
- `KeyboardShortcutRegistry`: default/override merge, binding lookup/mutation, conflict detection, input binding lifecycle.
- `DimmingComposer.split`: gamma floor, overlay cap, combined handoff, identity, clamping and monotonicity. New `application`: blackout suppresses physical dim application for every method/level; lifting blackout returns the latest desired composition.
- `SettingsStore` / `OpenDisplaySettings` decode/encode/load/save: existing corruption/backward compatibility plus new override, external-only and Shift preference persistence/legacy defaults.
- `BrightnessMonitor`: initial sample, external changes, own-write echoes, overlapping reads and invalid/failed readings.
- `XDRBrightnessPolicy`: boost/headroom limits and mapping.

AppModel integration source review: `setSoftwareDim`, software `setBrightness`, `applySilentBrightness`, method migration and replay funnel through guarded `applyDim`; desired values remain cached during blackout. `toggleBlackOut` removes blackout before restoring latest cached level. Software override refresh checks before and after asynchronous control reads prevent promotion by successful DDC read. DDC pending targets are cleared on override. Public-only builds exclude DDC task state.

Russian UI text updated in SettingsView, DisplayDetailView, AppModel human-facing labels/errors, InputHotkeysSettingsView and LaunchAtLogin. Settings section notification deep links preserve raw section IDs.

Remaining acceptance: these tests do not execute AppModel's macOS provider calls, actual event-tap callbacks, Carbon registration, TCC grant/revocation, login service changes, screen gamma/overlay painting or physical DDC effect. Root must validate app/public builds and perform authorized runtime/hardware checks; full feature acceptance cannot be inferred from 90 pure tests.
