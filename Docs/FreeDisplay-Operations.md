# FreeDisplay privacy, deployment and language

Read the [privacy statement](../PRIVACY.md) and [help index](FreeDisplay-Help.md) for capability
boundaries. There is no account, license key, activation server or vendor firewall exception needed
to install/use FreeDisplay. GPL source/attribution obligations remain; this is not BetterDisplay's
commercial licensing model.

## Data and connections

| Feature | Destination or local state | Review and disable path |
|---|---|---|
| Settings, identities, recovery and audits | Intended user's `~/Library/Application Support/OpenDisplay`; existing UserDefaults domains retain their names | Export/preview settings through Application. Preserve recovery records until affected screens are restored. Do not delete the whole directory as a routine fix. |
| Diagnostic export and console | Local staged ZIP/text/JSON/plist evidence; system logs also use the macOS log service | Export is explicit and does not upload. Review every included file plus redaction/omission report. Clear retained console logs separately; it does not delete system/audit logs. |
| Updater | When admitted for a release: configured FreeDisplay HTTPS feed, notes and archive hosting | Source/local builds disable Sparkle; upstream feeds/keys are refused. Inspect About's actual updater state, not just a preference. Disable automatic checks separately from other integrations. Publisher has not been authenticated by this implementation run. |
| HTTP and CLI IPC | Explicitly enabled HTTP listener and Keychain credential; same-user CLI socket in the user's session | Loopback is default for HTTP, remote listening is separate. Disable the service to stop access; replacing its token revokes the old credential. IPC and URL recovery have different trust contracts; see [transports](Integration-transports.md). |
| Scripts, URLs, web requests and notifications | Exactly the executable/arguments, browser destination, HTTP endpoint or local notification configured in Actions & Hooks | External actions can transmit configured values. Preview first; pause/remove only the configured action/hook. Disabling update checks does not disable these. An accepted action may finish after cancellation; removal is not rollback. |
| TV controllers | User-configured local device hosts/ports; pairing credentials in Keychain | [TV guide](TV-control.md). Device discovery/confirmation, protocol and wake tests are separate. Disable the controller to stop app-owned work. |
| Clock Mode location | One-shot request only via Use current location; coordinates saved for local solar calculations | Enter coordinates manually instead; macOS owns permission and location-service traffic. Saved coordinates are sensitive. |
| Capture | Selected display/window image delivered to FreeDisplay's local preview | Stop in Screen Capture or close its preview. External recorders have independent permissions and destinations. Browser links use that browser's policy. |

Diagnostics perform structured redaction, including settings pre-pass and filename sanitization;
malformed/unsupported material can be omitted. This is **not anonymization**. Custom names, arbitrary
free text, paths, command results and combinations of otherwise harmless facts can still identify
someone. Serial/UUID/registry removal choices change content; inspect every artifact, including
copied reports, before voluntary sharing. No automatic analytics/crash uploader is implemented;
Apple's separate system diagnostic settings are outside this app's control.

## Managed installation

Install the owner-approved `FreeDisplay.app` in the chosen applications location after verifying
[the exact downloaded artifact](ReleaseVerification.md). The internal executable, bundle identifiers,
`opendisplay` CLI, `opendisplay://` scheme, Keychain services and existing OpenDisplay storage paths
retain compatibility names. Do not bulk-replace these identifiers or copy another user's Keychain,
recovery ledger or entire support directory. Display identifiers and native audio UIDs are local.

Configuration belongs to the intended logged-in user, not root. Defer per-user setup if there is no
normal logged-in session (root/loginwindow/setup users are not the target). Each user has separate
settings, permissions and app lifetime. Enable Launch at Login only for that account, check macOS
approval, and verify after login. FileVault unlock/pre-login/Recovery remain outside app scope.
No root display-control daemon is supplied or required.

Back up settings through Application before import/reset. Inspect the import preview and identity
matches, apply only intended changes, and keep the backup. Restore the selected backup if needed,
then verify the actual controls and recovery state; importing settings does not restore all physical
properties or windows. Privacy, Accessibility, Screen Recording, Location, Notifications and login-item
approval are separate OS decisions; an administrator installing the bundle does not grant them.

For automation use the exact installed CLI path and explicit selectors. `opendisplay help` and
`commands --json` describe supported commands without hardware writes. Shared engine exit codes:
0 = committed/no-op/accepted request, 1 = failure, 2 = usage, 3 = partial. Inspect typed outcome and
per-target verification: exit 0 alone is not physical proof. A running app normally owns mutable
state via same-user IPC; app-off standalone paths have explicit limitations, and uncertain/failed
IPC never silently retries a write standalone. See [transport rules](Integration-transports.md).
Mode/main changes retain their keep/revert UI. HTTP status and URL recovery have their own contract;
no URL input/mode recipe is implied. Do not expose tokens, full incoming URLs or shell tracing in
reports. Stop the added trigger/service and restore each changed value explicitly to undo setup.

## Language and contributions

Settings → Application offers System, English and Russian. A change applies to this app after
relaunch, leaving macOS's system language unchanged. System removes this app's override; macOS
Language & Region can also set per-application language. Do not claim other languages or complete
translation coverage from the presence of a string catalog.

For a correction, report the current English source key, current/proposed translation, UI location
and meaning to the FreeDisplay repository. Use a fresh source/Xcode localization export; review
context and accessibility labels. Preserve identifiers, markup and every format placeholder
(`%@`, `%lld`, `%lf`, positional specifiers), including their types and counts. Command names,
CLI flags, URLs, module names and persistence keys are protocol identities, not prose to translate.
Check long text, wrapping, VoiceOver meaning, English/Russian and System behavior after relaunch.
This P1 work submits translation JSON for central catalog merge; it does not edit concurrent
`Localizable.xcstrings` or assert that those translations already ship in the app.
