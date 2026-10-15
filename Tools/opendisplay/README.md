# opendisplay (CLI)

**macOS target** (`Tools/opendisplay/Sources/main.swift`; shared grammar and typed requests in
`Packages/AutomationSchema`). Shared-model commands now control the **running FreeDisplay app**
over a same-user Unix socket: readiness, discovery, brightness/offsets, managed hardware contrast,
recovery/disconnect, mode/main and ICC. The app owns the live state and managed-offline ledger.
These commands refuse if the app is unavailable and never fall back/retry through direct providers.
Help/catalog work without it. Other legacy verbs retain their direct-provider implementation only
while the app is off, and explicitly refuse while it runs. See [transport lifecycle, security,
compatibility and Home Assistant instructions](../../Docs/Integration-transports.md).

These are the commands it implements — `opendisplay --help` prints the same list:

```
opendisplay list [--json]
opendisplay diagnose [--json]
opendisplay diagnose --bundle [directory]
opendisplay lux [--json]
opendisplay lid [--json]
opendisplay listen
opendisplay alias <selector> <name>
opendisplay tag <selector> <tag>
opendisplay disconnect <selector> [--dry-run] [--json]
opendisplay reconnect <selector> [--json]
opendisplay recover [--json]
opendisplay scene <list|save|show|plan|apply|delete> [name] [--json]
opendisplay layout <protect|unprotect|status> [--json]
opendisplay group <list|create|delete> [name] [--json]
opendisplay group <add|remove> <name> <selector>
opendisplay brightness <selector> [0..1|N%] [--method automatic|hardware|native|ddc|software] [--json]
opendisplay brightness <selector> --offset <delta> [--json]
opendisplay contrast <selector> [0..1|N%] [--json]
opendisplay ready [--json]
opendisplay mode <selector> [mode] [--json]
opendisplay main <selector> [--json]
opendisplay profile <selector> [profile] [--json]
opendisplay profiles [--json]
opendisplay capabilities <selector> [--json]
opendisplay commands [--json]
opendisplay command <name> [parameter=value ...] [--dry-run] [--json]
opendisplay ddc <selector> <brightness|contrast|volume|input|colour|sharpness|red|green|blue|mute|power|caps> [value] [--json]
opendisplay ddc <selector> reset
opendisplay ddc <selector> vcp <0xNN> [value] [--json]
opendisplay edid <selector> [--out <path.bin>]
opendisplay favorite <list|set|unset> <selector> [WxH[@Hz][@2x]]
opendisplay help | --help | -h
```

The PRD's generic `get`/`set`/`connect`/`blackout` grammar (PRD §12.2) is **not** implemented.

- **Options are per command.** An option a command doesn't list is an error (exit 2) rather than
  ignored — in particular `--dry-run` exists for `disconnect` and typed `command`, and nowhere else does it
  silently perform the real write. Shared-model IPC commands accept optional caller-supplied
  `--timeout <seconds>`; without it no client deadline is imposed. `--help`/`-h` anywhere prints help and touches nothing.
- **Results say what is known.** A write is `verified` only when reading the value back shows
  exactly what was written; `sent` means the display accepted it but nothing confirmed it took
  (no read-back, or one that disagreed — DDC panels ACK writes they then ignore). With `--json`,
  mutating commands print a `ResultEnvelope` whose operations carry an `outcome`
  (`verified`, `sent`, `alreadySatisfied`, `skipped`, `unsupported`, `failed`). Failures go to
  stderr.
- **`scene apply`** writes positions and modes only, then checks every field against the
  arrangement read afterwards: fields it doesn't execute (on/off, rotation, brightness, colour
  profile, HDR, relative placement) are reported as skipped, and a missing *required* member blocks
  the whole apply.
- **`recover`** reconnects through the running app's live managed-offline ledger and verification
  funnel. It refuses without the app. No standalone copy races the running app's ledger.
- **`disconnect --dry-run`** now uses the shared typed result/envelope and app safety preflight;
  its output replaces the old standalone safety-preview object. No display write occurs.
- Legacy-command sections below describe their **app-off standalone** implementation. New typed
  `contrast` uses normalized units; raw `ddc … contrast` remains a different monitor-unit interface.


Exit status:

| Code | Meaning |
|---|---|
| 0 | Success, including "nothing to do" and writes reported as `sent` |
| 1 | Failed — nothing requested was achieved, or a read was impossible |
| 2 | Usage error (unknown command/option, bad argument); nothing ran |
| 3 | Partly done — some displays/fields applied, others failed or were skipped |

## Sensor + streaming commands (Issue #34)

```
opendisplay lux [--json]      # current ambient-light reading, in lux
opendisplay lid [--json]      # lid open/closed state
opendisplay listen            # stream brightness/config events as line-delimited JSON
```

`lux` reads the built-in ambient light sensor directly (the same best-effort IOKit path Adaptive
Display's ambient mode falls back to — see `AmbientLight.swift`). `lid` derives open/closed from the
same two signals Adaptive Display already senses (`LidStatePolicy`): an active built-in panel, or a
readable ambient sensor, both mean the lid is open; neither means closed, best-effort. Both exit
non-zero with a message on stderr when the reading/state is unavailable (no sensor on this Mac, no
built-in panel to reason about, etc.) — nothing is printed to stdout in that case.

### `listen`

Streams one JSON object per line to stdout until interrupted with Ctrl-C (clean exit, no stack
trace). Output is line-buffered, so a piped consumer (`opendisplay listen | jq .` or `| tail -f`)
sees each event as it happens rather than batched at exit.

Two event kinds share one envelope (`ListenEvent` in `AutomationSchema`), distinguished by `event`.
`version` and `event` are on every line; the remaining keys are present only when that event kind
sets them (a `config` line has no brightness keys and vice versa):

```jsonc
// A live brightness change. `level` is normalized; `maxValue` (1) is the top of its scale.
{"version":1,"event":"brightness","timestamp":1737482921.5,"displayId":"cg:abc",
 "displayName":"Studio Display","level":0.62,"maxValue":1,"source":"mediaKey"}

// The display topology changed: hotplug, mode/resolution, rotation, mirror, or main display.
{"version":1,"event":"config","timestamp":1737482925.0,
 "displays":[{"id":"cg:abc","active":true,"main":true,"mode":"3840x2160@60"}]}
```

`source` is one of `menu` (a slider in the menu-bar panel or Settings), `mediaKey`, `hotkey`, `http`
(the local HTTP server), `cli` (another `opendisplay brightness` run), `appIntent` (Shortcuts) or
`app` (OpenDisplay's own automation: FaceLight, presets, restoring a level); consumers must tolerate
others. Each change is published exactly once, whether or not OpenDisplay drew its own HUD for it —
sliders, HTTP, CLI and Intent changes draw none but are still published. Not published: the
follower writes a Display Group fans out (they carry no new user intent, and a HUD receiver would
show the wrong display), and brightness changes made outside OpenDisplay (macOS keys, System
Settings, auto-brightness) — nothing observes those generally.

`brightness` events require **Broadcast OSD events** enabled in OpenDisplay's Settings (default
off) — `listen` prints a one-time note to stderr on startup when it's off, so brightness stays
silent but visibly explained rather than silently empty. `config` events need no setting; they come
from the same `CGDisplayRegisterReconfigurationCallback` source the app itself watches.

Out of scope for this pass: volume/mute OSD events (the `OSDBroadcast` channel carries them, but
`listen` only forwards `brightness` today — a natural follow-up `event` kind, not a schema change).

## Protected layout (Issue #38)

```
opendisplay layout protect      # keep the arrangement this display set has right now
opendisplay layout unprotect    # forget this display set's protected arrangement
opendisplay layout status [--json]
```

Protection is keyed by the **display set** on the desk — the sorted record ids of the displays
present — so "laptop alone" and "laptop + Desk" each keep their own protected arrangement instead
of overwriting one another. `protect` captures origins, mode, rotation, mirror state, main, and
active state; re-protecting the same set replaces its entry.

The writes route through `CommandGateway`, so they land in the audit trail like every other
mutating command, and they share `settings.json` with the app — the CLI and the Arrange tab are
looking at the same layouts. Automatic restore itself is the app's job: `status` prints whether
the master toggle (Settings → Arrange → "Put my arrangement back when it changes") is on, one line
per stored layout, and the last automatic restore with its outcome.
## Display groups (Issue #39)

```
opendisplay group list [--json]
opendisplay group create <name>
opendisplay group delete <name>
opendisplay group add|remove <name> <selector>
opendisplay brightness group:<name> <0..1>
```

A group is a user-defined set of displays whose brightness moves together, each member at its own
learned offset. `group:<name>` is a selector like `alias:`/`tag:`, so it also reaches the verbs that
want exactly one display — those report the group as ambiguous rather than picking a member.

`brightness group:<name> <level>` targets the group itself: `level` becomes the group's base and
every present member is written at `clamp01(level + offset)` through the same `GroupSyncPolicy` the
app fans out with — including the precedence ladder, so a member FaceLight or an app preset is
currently holding is skipped rather than overwritten. Absent and skipped members are listed by name.

A display belongs to at most one group — `group add` moves it out of whichever group held it and
says so. Groups live in the app's `settings.json`, so a group mutation made while OpenDisplay is
running is overwritten the next time the app saves its settings: quit the app first, or make the
change in Settings → Displays → Groups.
