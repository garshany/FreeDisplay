# opendisplay (CLI)

**macOS target** (`Tools/opendisplay/Sources/main.swift`; shared grammar and typed requests in
`Packages/AutomationSchema`). Shared-model commands use the **running FreeDisplay app** over a
same-user Unix socket. With the app off and the endpoint absent/refusing connections **before any
request bytes are sent**, the CLI uses its standalone shared `AutomationEngine`, on-disk ledger
and hardware providers. `opendisplay recover` therefore works after an app crash, including when
managed-offline displays are missing from OS enumeration. No command launches the app automatically.

A running app with an unreachable endpoint refuses; quit it or restore IPC. Unsafe endpoint
permissions/ownership, cancellation, timeouts, a lost/invalid reply, or any failure after sending
never fall back or retry standalone: the app may have accepted the operation. A reachable endpoint
always wins even if the app-presence snapshot missed it. See [transport lifecycle, security and
Home Assistant instructions](../../Docs/Integration-transports.md).

Shared-model JSON output adds `"servedBy": "app"` or `"servedBy": "standalone"` at the existing
object's top level, including brightness readings, result envelopes, dry-run previews and readiness.
Existing keys and schema versions remain intact; `list` retains this branch's typed
`AutomationResult` shape on both routes. Legacy JSON shapes are unchanged.

### Execution table

Here “standalone” means the existing direct-provider/persisted-state path; while the app runs,
legacy reads use a registry snapshot in memory so identity resolution does not save registry changes.
IPC requires a reachable app endpoint; an unreachable running app never grants standalone writes.

| Verb / form | App running | App not running, endpoint unavailable before send |
|---|---|---|
| `help`, `--help`, `commands` | Local help/catalog, no providers | Same |
| `ready` | IPC readiness, exit 0 only for ready | `ready: false`, exit 1; no providers |
| `list` | IPC live app discovery | Standalone hardware + managed-offline ledger discovery |
| `recover` | IPC app recovery funnel/live ledger | w4 ledger-based verified recovery; keeps failed entries |
| `disconnect` | IPC app safety/ledger funnel | w4 standalone gateway safety + ledger persistence |
| `disconnect --dry-run` | IPC app safety preview, typed result envelope | w4 standalone safety preview object; no display writes |
| `brightness` read / absolute value | IPC live route/group policy | w4 native/DDC shared-engine path; absolute group policy retained |
| `brightness --offset` | IPC atomic adjustment | Explicit refusal: requires app-owned atomic state |
| `brightness --method software` / software-preferred route | IPC app software state | Explicit refusal: unavailable in this process |
| `contrast` read / absolute value | IPC managed hardware contrast | Shared-engine ranged DDC contrast, normalized units and readback |
| `mode` discovery, `capabilities` | IPC app discovery | Standalone shared-engine discovery; capabilities report standalone refusals |
| `mode <mode>`, `main` | IPC app keep/revert funnel | Explicit refusal: requires the running app |
| `profile`, `profiles` (read or write) | IPC app ICC handling | w4 explicit refusal, including ICC discovery |
| `command <name>` (including `--dry-run`) | IPC shared parser/engine | Standalone shared parser/engine with the same app-owned refusals; dry runs never write |
| `diagnose` (including `--bundle`), `lux`, `lid`, `listen`, `edid` | Standalone reads/export/event subscription | Same |
| `ddc` feature read / `caps` / `vcp <code>` read | Standalone hardware read | Same |
| `ddc` writes, `reset`, `power` | Refuse: would bypass app-owned control/cache state | Existing raw DDC write path |
| `reconnect <selector>` | Refuse: would race the app-owned ledger; use `recover` | Existing single-display verified recovery |
| `scene list/show/plan` | Standalone read / dry plan | Same |
| `scene save/apply/delete` | Refuse: app owns scene library / display state | Existing standalone scene path |
| `alias`, `tag` (registry edits) | Refuse: app owns registry | Existing registry edits |
| `layout status`, `group list`, `favorite list` / `favourite list` | Standalone read | Same |
| `layout protect/unprotect`, `group create/delete/add/remove`, `favorite set/unset` | Refuse: app owns stored settings/favorites | Existing standalone edits |
| `_rotate-exp` (undocumented experimental verb) | Refuse: app owns arrangement | Existing experimental standalone path |

`--timeout` applies only to IPC and imposes no standalone operation deadline. App presence is a
snapshot; starting the app after standalone selection can still race the old standalone paths.

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
- **`recover`** uses the running app's live managed-offline ledger, or w4's standalone persisted-ledger
  recovery when the app is off. A disabled display does not need to appear in OS discovery.
- **`disconnect --dry-run`** uses app safety preflight via IPC, or the original standalone safety-preview
  object when the app is off. Neither path writes display state.
- Legacy-command sections below describe their standalone implementation; the execution table above
  identifies which forms also work while the app runs. Typed `contrast` uses normalized units;
  raw `ddc … contrast` remains a different monitor-unit interface.


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
