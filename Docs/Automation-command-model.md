# FreeDisplay automation foundation

FreeDisplay has its own command protocol. It is not compatible with BetterDisplay endpoints or command grammar.

`AutomationRequest` → `AutomationEngine` → `AutomationEnvironment` → `AutomationResult` is the shared pipeline. The engine owns selectors, unit validation, capability admission, method choice and settlement. Platform adapters supply observations and I/O. Requests and outcomes are Codable and do not carry sockets, UI objects, tokens or deadlines.

## Entry points

| Surface | Default, lifetime and authentication | Discovery and outcomes |
|---|---|---|
| Standalone `opendisplay` | One invocation, direct providers and persisted stores; no GUI IPC yet | `help`, `commands --json`, `capabilities <selector> --json`, `mode <selector> --json`; exit 0 success/sent/no-op, 1 failure, 2 usage, 3 partial |
| `opendisplay://` | OS URL handler; no credential; only recovery is admitted | Existing `reconnect-all`/`reconnectAll`/`recover` aliases remain. Disconnect links are refused visibly. Other typed commands are refused by surface admission. No callbacks are invoked. |
| Local HTTP | Explicit Start in Settings → Automation; loopback, session token and ephemeral port; stops on section departure or Stop | Bearer header; authenticated GET `/v1/displays`, GET `/v1/commands`; POST `/v1/brightness`, `/v1/reconnect-all`, `/v1/command`. Start is not readiness: use the displayed running endpoint. Stop invalidates the token. |
| App Intents | Runs inside the app; display actions require its live model and wait for startup; recovery has a persisted-ledger fallback | Typed display/mode/profile entities; typed values and outcomes; unavailable targets fail, never redirect. Saved built-in-only Set Brightness shortcuts retain their default target and percent parameter. |
| App console | Foundation only; UI is FD-040 | Uses the typed parser/engine, not a shell. |

HTTP keeps the existing authentication/framing limits, connection lifetime and session ownership. An expired connection does not roll back a dispatched display write. Recovery is an independent background operation; its legacy response reports requested IDs and the final outcome goes to the app's audit. There is no durable remote/LAN service here; FD-058 owns that work. Never put tokens in query strings or logs.

## Values, targets and safety

Brightness has one internal unit: a finite fraction 0–1 of the control span. `0.4` and `40%` are equivalent; bare `40` is refused. Offset is explicit, e.g. `+5%` or `-0.05`; any finite magnitude is accepted and only the resulting absolute level is clamped. DDC conversion uses the monitor's maximum. Raw VCP units retain their separate integer grammar and existing command schemas.

Selectors share `id:`, `alias:`, `tag:`, `name:`, `nameLike:`, `group:`, `main`, `builtin`, pointer where available, and transient CG display numbers. Missing, ambiguous, offline and unsupported selectors have distinct issues. A group absolute brightness command keeps the existing group-base/offset policy; it is not an arbitrary bulk setter. No matching rule selects the first ambiguous candidate. IDs and tags are local to this installation.

`automatic` uses the display's current route. `hardware` never uses software dimming. `native`, `ddc` and `software` are exact choices, accepted or refused; they do not override the app's configured route. Public-only builds refuse hardware routes. Capabilities distinguish surface/build admission from an actual device probe and a successful later operation.

A confirmed native/DDC readback is not measured luminance. Software dimming is an applied level, never display-confirmed. Continuous DDC writes use the app's existing 250 ms settle and ±1 monitor-unit tolerance from `DDCReadbackPolicy`; color presets retain the existing longer settle and exact matching. A failed transport is a failed write, unavailable readback is `sent`, and mismatching readback reports the actual value without claiming verification.

Mode selection matches one complete offered tuple, including framebuffer size, refresh, density and depth. No nearest-mode fallback is synthesized. App mode mutations retain the menu's verified keep/revert gate. The Set Display Mode Intent alone offers **Without confirmation**, default off; an explicit on keeps a verified mode immediately. Engine admission also rejects a serialized bypass flag from other surfaces. Main changes use the existing `AppModel.setMain` path; the orchestrator's separate keep/revert work must land for main changes to open that window. ICC writes resolve an installed profile, apply through the model, then verify the ColorSync assignment.

The standalone CLI cannot provide app-owned software dimming or atomic cross-process offsets. Those return capability refusals. Mode mutations, main changes and ICC commands requiring app-owned state are not admitted from the standalone CLI. FD-078 (owner decision #9) must wire app IPC before those become available. Direct CLI and the live app do not yet share mutable state.

## Examples (documentation only)

Use the actual absolute path to the built/installed `opendisplay` executable in unattended scripts:

```sh
"$FREEDISPLAY_CLI" commands --json
"$FREEDISPLAY_CLI" capabilities 'alias:Desk' --json
"$FREEDISPLAY_CLI" mode 'alias:Desk' --json
"$FREEDISPLAY_CLI" brightness 'alias:Desk' '40%' --method hardware --json
```

The legacy `brightness <selector> [0..1] --json` read/write shapes stay intact. `GET /v1/displays` retains its cached brightness fields and age; it is not a fresh physical read. `/v1/brightness` keeps `status`, `displayId`, `value`, `physicalEffectVerified` and adds route/readback/outcome fields. `/v1/command` returns the full typed result.

An original Home Assistant REST command, for a separately configured and authorized route to the loopback session, uses FreeDisplay's POST/header protocol:

```yaml
rest_command:
  freedisplay_desk_brightness:
    url: !secret freedisplay_command_url
    method: POST
    headers:
      Authorization: !secret freedisplay_authorization
    content_type: application/json
    payload: '{"command":"setBrightness","displayId":"cg:INSTALLATION_LOCAL_UUID","value":0.4,"method":"hardware"}'
```

Merge that entry into the existing mapping. The URL secret is the reachable endpoint ending in `/v1/command`; the authorization secret is `Bearer ` followed by the private current session token. A remote HA host cannot use its own localhost to reach the Mac. This recipe does not configure a bridge, persist a token, enable a LAN listener or supply a new timeout. Callers own their network deadline. Current session credentials and ports change after restarting the server.

Use HA's manual action first. Distinguish 401 authentication, 404 unknown identity/profile/route, 409 offline/inactive/ambiguous/busy, 422 unavailable method/capability, 502 failed/unconfirmed operation and 503 not-ready. Successful commands use 200; partial recovery uses 207 on the typed route. Inspect the JSON outcome and actual monitor separately. Repeating an absolute request is idempotent in state; a running sync policy may affect followers. Stop triggers and let accepted work finish before removing only the added configuration. Removing a trigger or stopping the server does not restore prior brightness.

Shortcuts discovery is installation/OS registration, separate from runtime display capability and keyboard/Stream Deck permissions. Public API builds expose software brightness and public mode/profile controls; they do not make private hardware routes available. No hardware, installed Shortcuts discovery, physical modes or HA reachability was exercised by this branch.
