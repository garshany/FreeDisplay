# FreeDisplay console and diagnostics

Open **Show Console…** from Tools, the status icon's right-click menu, or Settings → Diagnostics.
The console runs inside the existing app and needs neither HTTP nor a companion CLI. It never
launches a shell. The installed command catalog supplies general `help` and `help brightness`.

Examples (they change display state when actually submitted):

```
list
capabilities display=builtin
brightness display="alias:Desk" value=40% method=hardware
brightness --display "name:Рабочий стол" --offset -5%
listModes display=builtin
setMode display=builtin mode=1920x1080 --dry-run
```

Named parameters use `name=value`, `-name value`, or `--name value`; quotes preserve spaces and
backslash escapes the next character. An unfinished quote/backslash or an unknown/duplicate
parameter is rejected before execution. No positional selector or unit conversion is implemented
in the console: AutomationRequestParser, AutomationEngine and AppAutomation own those rules.
Modes and main-display changes retain the normal app keep/revert UI. `disconnect` is not admitted
from the console. Public-only builds retain the same engine/provider capability refusals; use
`capabilities display=<selector>` to inspect them. A catalog entry is not a hardware support promise.

Only the prompt is editable. Up/Down traverse session history, collapse consecutive duplicates,
and restore the draft after the newest entry. `clear` and the Clear button clear command output
and the retained diagnostic buffer, preserving history/settings. `exit`, Command-W and the window
close button close only the console. Frame and logging preference persist; history/output/logs are
memory-only. Logs and result output occupy separate selectable views so incoming diagnostics cannot
replace text being edited. Console results/history may contain identifiers; review excerpts.

Logging starts off. Enabling it retains new redacted diagnostic records independently of window
visibility. The system sink is independent of that preference. **Retention…** accepts nonnegative
entry counts separately for command history, transcript entries and diagnostic records; zero retains
nothing and blank has no configured bound. Limits are validated and saved only by Apply Retention.
There is deliberately no invented default cap, including no implicit 1000-command cap. Until the
owner chooses defaults or the user configures capacities, memory can grow until Clear or app quit.
A single transcript entry can contain an entire result; entry counts are not byte quotas.

## System and terminal diagnostics

The app and CLI write redacted info messages under subsystem `dev.opendisplay.diagnostics`,
category `automation`. In Apple's Console select the process and include Info messages, then
filter by those subsystem/category values. This is separate from the in-app Logging preference.
Messages describe command admission/result status and display lifecycle events, not physical effect.
Full incoming URLs and command parameter dictionaries are not logged.

CLI options (options are parsed before providers):

```
opendisplay list --json --log-output stderr
opendisplay list --json -v2e
opendisplay list --log-output stdout
```

`--log-output off|stdout|stderr` defaults to off; `-v` means stdout, `-v2e` means stderr. Additional
diagnostics never go to stdout when `--json` or the `listen` JSONL stream is requested: combining
those with explicit stdout logging is a usage error (exit 2), before provider/store creation.
Ordinary failures/warnings remain on stderr. Existing result JSON/exit contracts are unchanged.
No CLI invocation was used to verify this branch: package fake tests and builds are the evidence.

## Copy and local export privacy

Settings → Diagnostics offers separate serial, UUID and registry-path removal options (initially
on). The Tools export uses those same choices; CLI `diagnose --bundle` uses all removals on.
The display report's copy/export option removes all three and omits raw/decoded EDID sections,
which can encode additional serials. The report shown locally retains the original facts.

All included export artifacts are sanitized in a private staging directory before ZIP creation:
JSON/JSONL preserve their structural formats, plist (including binary plist) is decoded and rewritten
as XML, text is redacted, malformed structured files/unsupported binary and symbolic links are
omitted. `redaction.json` records selected options and omitted artifacts. Filenames also pass the
policy. Tokens/passwords/secrets/authorization fields, Bearer credentials and complete URLs are
always removed. Settings retain the earlier location/app-preset removal, with credential removal
added. Opaque plist data is always omitted. Serial/EDID fields are removed with identifier removal enabled; UUIDs
and registry paths are matched separately. Explicitly known serials can also be supplied to the
shared policy for report copies. Original support and system files are not modified.

This is redaction, not anonymization. Arbitrary free text, custom display names and unrelated file
paths can still identify someone. Inspect the archive before sharing. Export is user-triggered and
local, with no upload. Existing collection bounds (4 MiB per tool, 40 seconds per tool, 30 minutes
of display logs) were not changed. Hardware, live system logging retrieval and actual export of
real system artifacts have not been exercised under this task's build/unit-test-only rules.
