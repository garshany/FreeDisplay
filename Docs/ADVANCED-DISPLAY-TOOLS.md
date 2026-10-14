# Advanced display tools

Original clean-room OpenDisplay contribution, GPL-3.0-or-later.

`AdvancedDisplayToolsView(displayID:)` is a standalone settings section. It uses the
existing app's `TopologyCore` dependency. Place it in the selected-display detail
view; it needs a current CGDirectDisplayID, not a display index. All file operations
use user-selected Open/Save panels. It never installs display overrides.

Implemented: strict EDID block length/header/manufacturer/extension-count/checksum
validation; manufacturer, product, serial and display-name extraction; lossless
Apple display-override plist export; bounded 2× HiDPI planning JSON including recovery
steps; current and potential NSScreen EDR headroom reporting.

The EDID file is user supplied and is NOT asserted to belong to the selected monitor.
Extension data is preserved but its timings/HDR metadata are not decoded. Imported
identity must be checked independently before external installation. Exporting an
override does not prove that macOS will accept it. Privileged override installation,
custom physical timing injection and hardware HDR switching are unsupported here.
EDR headroom is a rendering-path measurement, not proof of HDR link signaling.

ICC selection and factory reset already exist in `ColorProfileService` through public
ColorSync APIs. Keep those existing controls. Its Boolean result represents ColorSync
acceptance; it does not independently prove a changed monitor color response. Existing
XDR brightness also remains experimental and depends on actual available EDR headroom.

Rollback for external configuration: save the current mode and exact prior override
files first; use a known-good screen or Safe Mode if video fails; restore the exact
backup (or remove only the newly added override), reboot and verify original output.
The exported HiDPI plan includes these steps. OpenDisplay makes no privileged change.
