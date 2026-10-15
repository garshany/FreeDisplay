# Verify a FreeDisplay download

FreeDisplay's source and release origin is https://github.com/garshany/FreeDisplay. The upstream
project is https://github.com/aquitaine/OpenDisplay (GPL-3.0); its release signing identity and update
key are not FreeDisplay's. There is no validated FreeDisplay Developer ID/Team ID asserted in this
branch. Until the owner publishes them with a validated release, use the source-build instructions
and do not treat an ad-hoc development signature as release authentication.

The built product is `FreeDisplay.app`. Archive names and final packaging belong to the parent
release process; an existing `OpenDisplay.zip` name may remain. Confirm its actual contents against
the release announcement rather than inferring the bundle from the archive filename. Internal
bundle IDs, settings locations, executable and `opendisplay` CLI retain compatibility identities.
A renamed icon is not proof of the publisher. Use the exact checksum and full expected Developer ID
authority/Team ID published by the fork owner for the exact release asset. Never copy BetterDisplay's
or upstream's identity. Publisher gates are in [Release checks](FreeDisplay-Release-Checks.md).

For an owner-validated release (commands are for the recipient; not run by this branch's agent):

```sh
# In the directory holding the downloaded zip and its trusted release checksum:
shasum -a 256 -c OpenDisplay.zip.sha256
# After extracting the app, with the path adjusted to its actual location:
codesign --verify --deep --strict --verbose=2 /path/to/FreeDisplay.app
codesign -dvv /path/to/FreeDisplay.app
xcrun stapler validate /path/to/FreeDisplay.app
syspolicy_check distribution /path/to/FreeDisplay.app
```

Compare **all 64** hex digest characters, `Authority` and `TeamIdentifier` against a separately trusted
release announcement. A zip and checksum modified together can agree; SHA-256 alone is integrity,
not publisher authentication. A valid signature by an unexpected identity is still the wrong signer.
Modified bundles must fail signature verification. The release publisher must also check nested code
and supported architectures; ordinary `codesign` success alone does not prove a release is notarized.

On systems without `syspolicy_check`, use `spctl -a -t exec -vvv /path/to/FreeDisplay.app` instead.
File-not-found, folder-access failure and Apple-service/network failure are different from a confirmed
signature mismatch; retain the exact error and retry from the trusted origin. Do not disable
Gatekeeper or remove quarantine as a troubleshooting shortcut.

The current fork's in-app updater remains off (`OpenDisplayLocalBuild = true`). Signed appcast
preparation is not proof of a release upgrade. See [the owner workflow](../scripts/sparkle-setup.md)
for the separate feed, signing, upgrade and rollback validation gates.

For support, copy Build Information from either About surface. Review diagnostic exports for names,
identifiers, paths and command values before sharing. Display arrangement protection does not
restore app windows/Spaces or Universal Control relationships. Refresh enumerates macOS displays;
logical reconnection handles displays FreeDisplay turned off; neither increases physical display
limits or guarantees redetection of an absent cable route. Reproduce direct/dock/KVM separately and
keep working mode/refresh evidence. A longer wake delay can postpone a layout change, not repair a
missing physical mode. Start with feature isolation and settings backup, not destructive system resets.
