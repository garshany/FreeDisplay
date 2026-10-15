# FreeDisplay privacy

FreeDisplay is a GPL-3.0 fork of [aquitaine/OpenDisplay](https://github.com/aquitaine/OpenDisplay).
It has no automatic analytics or crash-report uploader. Apple may separately collect macOS diagnostics
according to the user's system settings; this document does not control that service.

Preferences, remembered display identities, recovery records and logs are stored locally. Display
identifiers, names, paths and command arguments may be sensitive. Diagnostic export is a deliberate
user action, writes a local file, and does not upload it. Review an exported bundle before sharing it.
Diagnostics can include display configuration, registry data and macOS display-related logs; they
are not raw HDMI traffic captures.

Optional network activity depends on the features you enable:

- Every current fork build has `OpenDisplayLocalBuild = true`. Sparkle is not started in these builds.
  A future owner-validated release may check the FreeDisplay update feed, download release notes
  and signed archives over HTTPS according to the user's update preferences. The hosting service
  sees ordinary request metadata such as the client's IP address. No upstream OpenDisplay update
  feed or upstream signing key is used by the fork.
- Configured network-display controllers communicate with the devices the user configures.
- The optional local HTTP control service accepts automation requests. Its authentication and
  configured listening scope are separate from the in-process CLI and URL scheme.
- Links opened in a browser follow that browser's privacy settings and the destination's policy.

Clock Mode requests a one-shot location only when the user chooses “Use current location”. The
coordinates are used for local sunrise/sunset calculations and saved with the app preferences;
manual coordinates are available instead. macOS owns the location permission and underlying
location-service data flows.

Screen capture requires macOS permission and runs only when requested. Accessibility access, when
granted for keys, does not establish a remote reporting service. FreeDisplay has no account,
purchase, activation or licensing-provider connection requirement.

Application/bundle IDs, the `opendisplay` CLI, URL scheme and existing settings locations retain
their OpenDisplay names for compatibility. That storage identity does not change the fork's
source repository: https://github.com/garshany/FreeDisplay.
