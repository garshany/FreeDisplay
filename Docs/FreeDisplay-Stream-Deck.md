# Six explicit Shortcuts / Stream Deck actions

The full panel has six independent buttons: Bright, Dim, PC Input, Mac Input, Task Mode and Return
Mode. **Four are implementable now with existing FreeDisplay App Intents. PC/Mac native input
actions are gated on P2 FD-089.** Do not present the six-button native recipe as complete, assign
inactive input placeholders, or invent an input Intent/URL command. No custom Stream Deck plugin,
dial control or automatic hardware feedback is supplied.

## Prepare the target and return actions

Keep a working physical desktop and the monitor's physical input buttons accessible. First verify
manual control in FreeDisplay and inspect the exact target identity. Record original brightness,
complete original/task mode tuples (logical/backing dimensions, density, rate, depth) and actual
Mac/PC input destinations. IDs, mode IDs and audio/controller associations are installation-local.
Build and test the return choices before the outward choices. Do not assume unspecified fields
remember the old value or that an input list detects attached cables.

| Button | Current action and parameters | Check and explicit return |
|---|---|---|
| Bright | Shortcuts → FreeDisplay → Set Display Brightness; explicitly choose Display and your tested Brightness (%) | Inspect typed route/outcome/readback and the physical panel; check unrelated displays/group followers. Dim is a separate chosen level, not necessarily the original. Save an additional original-level shortcut if needed for cleanup. |
| Dim | A separate Set Display Brightness with the same explicit display and tested lower absolute level | Repeated runs target the same value. Return with Bright or the separately recorded original level. Leaving Display empty selects the built-in screen, not the external target. |
| PC Input | **Native action unavailable until FD-089** | Future recipe must select a controller-qualified explicit PC destination and verify the physical picture. Test Mac return first; retain physical input recovery. |
| Mac Input | **Native action unavailable until FD-089** | Future explicit/idempotent Mac destination, independently tested before PC. Inputs do not power the computer or switch USB/KVM routing. |
| Task Mode | Set Display Mode with explicit Display and an actually offered complete Mode | Leave Without confirmation **off** initially. Inspect settled mode/image/pointer and Keep, or Revert/let the countdown restore. An awaiting-confirmation result needs that UI decision. |
| Return Mode | Separate Set Display Mode with the recorded complete original tuple | Test first and after Task Mode. It is an absolute selection, not “previous mode”; it does not restore windows/Spaces or input/brightness. Keep/revert also applies here. |

The brightness Intent uses the configured route; it has no force-hardware/upscaling parameter.
Select software brightness in FreeDisplay for a public software test; DDC/native brightness routes
retain their build/device caveats. Public-only builds can use software brightness and public modes;
they do not enable private input transport. “Without confirmation” exists only on the mode Intent,
default off, and keeps a verified mode immediately when explicitly enabled. Treat this choice
separately from physical validation, especially for remote control.

## Test each layer separately

1. Run each available shortcut from its editor with Settings closed. Resolve Shortcuts/app access
   prompts and inspect the returned values, actual identity, physical state and unrelated screens.
   Native App Intents do not need CLI access, Run Shell Script permission or HTTP credentials.
2. Give each shortcut a distinct unused chord in Shortcuts Details. Test by typing it in normal
   foreground apps. Check conflicts with FreeDisplay Settings → Keyboard, system shortcuts and
   other apps. **⌃⌥⌘R remains reserved for recovery while enabled.** Shortcut-editor success alone
   does not prove keyboard delivery. Keep the app running and ready.
3. In Stream Deck use **System → Hotkey**, one button per action, matching that exact chord. Give
   each an explicit static title; put Return Mode/Mac Input where they are easy to find. Do not use
   Hotkey Switch to alternate hidden state. Allow **Stream Deck's own Accessibility permission**,
   relaunch it if requested and select the intended profile. Native media-key permission in
   FreeDisplay is separate and does not grant permission to Stream Deck.
4. Test editor → typed chord → deck in that order for every available action, allowing completion
   before the next request. A static title, deck animation, returned status or monitor readback
   alone is not proof of the physical picture/input/mode. Record permission, transport and physical
   checks separately. The two gated actions have no completed test until FD-089 lands.

## Existing CLI / URL alternatives and their boundary

The existing `opendisplay` CLI can list commands/capabilities and query modes; the running-app IPC
path supports brightness and mode changes with the same safety gate. Use its current `help` and
[transport contract](Integration-transports.md), explicit selectors and exact offered modes. It is
an alternative **script workflow**, with shell/CLI path/execution permissions and exit/JSON checks,
not a way to claim the native six-action recipe is complete. Existing raw DDC input commands or
Settings → Keyboard input bindings require manually qualified monitor inputs/private DDC and
physical return testing. They do not supply FD-089's stable controller-scoped App Intent catalog.
The `opendisplay://reconnect-all` URL is recovery-only; arbitrary brightness/mode/input URLs are
not admitted. Do not silently replace a gated native input action with an unsupported URL.

## Remove the panel

Let pending work finish or choose Revert. Restore original input, brightness, complete mode and any
paused automation explicitly, checking the physical monitor. Remove only added deck keys and
Shortcuts/chords, and revoke permissions only if no remaining workflow needs them. Deleting a
button/shortcut does not restore device state. Removing either input action without first returning
to the Mac can strand the visible desktop; retain the monitor's physical return controls.
