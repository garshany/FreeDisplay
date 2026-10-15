# Verify a FreeDisplay download

Download `FreeDisplay.zip` and `FreeDisplay.zip.sha256` from the same intended release at
[garshany/FreeDisplay](https://github.com/garshany/FreeDisplay/releases). For the standalone CLI,
download `opendisplay.zip` and its matching checksum too.

```sh
shasum -a 256 -c FreeDisplay.zip.sha256
# Optional standalone CLI:
shasum -a 256 -c opendisplay.zip.sha256
# After extracting, inspect the app without running it:
codesign --verify --deep --strict --verbose=2 /path/to/FreeDisplay.app
codesign -dvv /path/to/FreeDisplay.app
```

A checksum verifies the archive's bytes, not its publisher: an attacker able to replace both files
could replace both. Use the intended GitHub repository and release. The current channel is ad-hoc
signed, with **no Developer ID and no notarization**; do not expect a TeamIdentifier, a notarization
ticket or a successful Gatekeeper distribution assessment. A modified app must fail signature
verification. Keep the standalone CLI next to the frameworks included in its extracted directory.

Move the app to Applications. For first launch, right-click → **Open**; macOS may additionally ask
for approval in **System Settings → Privacy & Security**. Do not disable Gatekeeper globally.
After an update, macOS may ask again for Accessibility permission. The app only reports new GitHub
releases and opens their download page; quit it and replace it manually. Source builds continue to
identify themselves as local builds and can also check GitHub.

For build and publication steps, see [Releasing](Releasing.md). For display recovery, see
[Recovering a stranded display](Recovering-a-stranded-display.md). Review diagnostic exports for
names, identifiers, paths and command values before sharing them.

Display arrangement protection does not
restore app windows/Spaces or Universal Control relationships. Refresh enumerates macOS displays;
logical reconnection handles displays FreeDisplay turned off; neither increases physical display
limits or guarantees redetection of an absent cable route. Reproduce direct/dock/KVM separately and
keep working mode/refresh evidence. A longer wake delay can postpone a layout change, not repair a
missing physical mode. Start with feature isolation and settings backup, not destructive system resets.
