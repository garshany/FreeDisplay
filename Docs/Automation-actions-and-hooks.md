# FreeDisplay actions, readback and hooks

Settings → **Actions & Hooks** creates paused per-display configurations. The editor is a structured JSON editor; it displays saved targets and hook phases, previews expanded requests locally, and offers ranged, Boolean and command buttons. **Review & save** keeps everything paused unless the explicit review checkbox is selected. Editing/preview never sends a request. Enabled periodic reads start only after the configured interval has elapsed. Adding a configuration creates no-op actions; it changes no native brightness/audio controller ownership.

The file is `integration-actions.json` beside `settings.json`. Missing means no actions. Invalid files produce a visible error and are not silently replaced. Settings archives include this file's definitions; import/reset uses the existing backup/rollback mechanism and pauses all imported controllers, controls and hooks. Local trusted configurations retain their flags across ordinary launches. Shift safe startup suppresses action execution and automatic reads for the entire session. There is no startup write/read replay policy.

## Configuration

Start from **Add paused configuration**, then edit the generated JSON. Identifiers and enum spellings are stable machine fields, not localized labels. `enabled` is independent at controller, control and hook levels. Disabling/deleting a controller or control cancels its queued/running work and polls; definitions remain when merely disabled. No action is automatically restored on removal.

Actions use Swift Codable tagged objects:

| Action | JSON shape / contract |
|---|---|
| Do nothing | `{"none":{}}` |
| Dynamic ranged brightness | `{"brightness":{"_0":"hardware"}}` uses the shared `AutomationLevel` directly, then the shared brightness route/engine/readback. Other methods use their existing shared spellings. |
| Fixed typed command | `{"command":{"_0": … }}` contains an `AutomationCommand` from the shared command schema. Target is always the configuration's resolved stable display; commands cannot change connections, recursively feed controls, or bypass mode confirmation. |
| Process | `{"process":{"executable":"/absolute/tool","arguments":["--name","[*:DEVICE_NAME:*]"],"budget":…}}` |
| HTTP GET | `{"http":{"url":"https://your-peer/path?name=[*:DEVICE_NAME:*]","budget":…}}` |
| App URL | `{"openURL":{"_0":"your-app://path?name=[*:DEVICE_NAME:*]"}}` opens through NSWorkspace and has no response body. HTTP uses the HTTP adapter instead. File URLs and recursive FreeDisplay URLs are refused. |
| Distributed notification | `{"notification":{"name":"your.literal.name","payload":"[*:EVENT_HOOK:*]"}}` sends a local distributed message, not a notification banner; no acknowledgement is implied. Empty payload does no I/O. |

A process/HTTP `budget` requires **both** `timeoutSeconds` and `maximumOutputBytes`, chosen explicitly by the owner. There are no defaults. An interpreter is an explicit executable such as `/bin/bash` or `/bin/zsh`, followed by an absolute literal script-file path and argument array. Inline `-c`/`-e` interpreter code and interpreter options before the script are refused. Metadata is never concatenated into a shell program. A configured user script can still interpret its own arguments; its contents and side effects remain the user's responsibility.

Parameters are `{ "name": "Identifier", "value": "Content" }` rows. Identifiers are case sensitive, distinct, nonempty, and cannot use reserved names. Built-ins: `DEVICE_NAME`, `DEVICE_DESCRIPTION` (the current display label), `STABLE_ID`, `DISPLAY_ID`, and, only for hooks, `EVENT_HOOK`. Control actions also receive `VALUE`. Tokens are `[*:Identifier:*]`; expansion is a **single pass over source tokens**, so inserted metadata is never expanded recursively. Unknown tokens fail. An absent display has an empty `DISPLAY_ID`, even if a recovery ledger remembers an old number. The stable id remains present. URL substitutions are percent encoded and cannot replace scheme/authority. Notification names and executable paths are literal.

`kind` is `{"ranged":{"multiplier":…,"decimalPlaces":…}}`, `{"boolean":{}}`, or `{"command":{}}`. Ranged input is the existing canonical normalized 0…1 level; multiplication and decimal formatting apply only to outgoing text. Zero/nonfinite multipliers, negative precision and mismatched values fail before execution. Boolean OFF uses `offAction`, ON uses `action`. Command text is data for the `VALUE` token. Fixed typed commands remain fixed; choose the dynamic `brightness` action when the requested level should drive the shared brightness command. Independent controls keep independent queues; requests in a slot run serially and retain their final value. Poll reads skip busy slots; hooks run independently. There is no implicit throttle/redundancy interval or cross-control coalescer.

## Readback, polling and feed

`readAction` is separate from setters and must return process or HTTP text. `readback` can be:

- `{"ranged":{"multiplier":…,"regex":…,"capture":…}}`: no regex means the entire trimmed response is one finite number. A regex must match exactly once; `capture` explicitly selects the whole match (0) or a capture group. Divide by the nonzero configured multiplier and validate with `AutomationLevel`; never clamp malformed replies to zero. No-match, multiple matches, invalid regex, missing capture, nonfinite/out-of-range and multiple-number replies fail.
- `{"boolean":{"on":"ON\n","off":"OFF\n","regex":false}}`: exact responses preserve whitespace/newlines. Regex mode accepts exactly one of ON/OFF; collision is an error, with no ON precedence.

Polling requires an enabled controller/control, a read action/parser, `pollingSeconds`, and an explicit `pollingFailurePolicy` (`stop` or `continuePolling`). No interval/range/default/retry count is chosen by FreeDisplay. Only clock-representable positive durations are accepted. `stop` exposes the error and leaves the poll stopped until configuration is reviewed/saved; `continuePolling` explicitly permits another read after the configured interval, including after uncertain failures. The owner must account for a timed-out process that may still exist. There is never more than one awaited poll per control, and a poll does not start while that slot has pending I/O. Hiding/removing the parser stops polling even if read-action text is retained. Disconnect, deletion, controller-off, sleep, app exit and safe startup cancel polling. Sleep/wake resumes configured polling with a full interval, without catch-up/replay.

Samples have `value`, timestamp and `source` (`readback` or `feed`), and never imply measured physical brightness. `freshnessSeconds` is owner supplied; absent means freshness is unknown/stale. The UI shows sample time and freshness **at render**, without inventing a refresh timer. Reads/feed update the displayed sample and ranged input without calling setters. A newer feed/write/cancellation invalidates an older asynchronous read completion and its error.

The existing authenticated HTTP command endpoint accepts the **shared** parser/engine command:

```json
{"command":"feedIntegration","displayId":"YOUR_STABLE_DISPLAY_ID","control":"YOUR_CONFIGURED_CONTROL_UUID","response":"ON\n"}
```

Send this flat JSON body to `POST /v1/command` with the existing Bearer token and JSON content type. No `parameters` wrapper is used. Alias `feed` is accepted. `response` is exact text, not a normalized value shortcut. The command resolves one connected display and one configured parser, returns `integrationSample` with `source=feed`, and performs zero setter calls. Existing HTTP authentication, POST admission and request framing remain in force. URL links, App Intents and standalone CLI cannot feed controls. Settings' Feed button uses the same command. FD-078 owns standalone CLI ↔ app transport; no new transport is added here.

## Hook phases and readiness

| Phase | Emission |
|---|---|
| `softDisconnect` | After the app's disconnect attempt returns, even if refused/failed. It is not observed loss. |
| `softReconnect` | After identity safety checks, before requesting reconnect of a ledger or coordinator-managed display. Dispatch is asynchronous and does not block recovery. |
| `hardDisconnect` | One connected → absent edge. This is not evidence of cable removal. |
| `hardReconnect` | An observed-absent remembered identity returns, after app topology/registry setup. Unknown first discovery and repeated configuration notifications do not fire it. |
| `systemSleep` | One sleep transition, for currently connected displays. Cancels delayed wake/polls. |
| `systemWakeImmediate` | Once after that sleep, before wake convergence. |
| `systemWake` | Once after the **per-display configured** `wakeDelaySeconds`, only if no new sleep/disconnect has invalidated that generation. Nil disables this phase. Explicit zero uses the next task turn. |

Deduplication is by semantic edges, explicit attempt correlation and wake generation, not a hidden time window. Events/receipts show target and transition ids. Readiness means known identity and app configuration; hardware/network readiness is not asserted. Late readiness may produce an honest shared-command/transport refusal, with no hook retry. Delayed user hooks do not hold up safety recovery or the app's configuration convergence. Independent hooks may overlap, and soft/hard callbacks may interleave; phase names describe their observation/attempt points, not external completion order. Only the explicit event target receives a hook dispatch. Existing user group synchronization can still cause follower changes through the shared app brightness funnel.

## Outcomes and cancellation

Logs distinguish event emission, dispatch, process exit, HTTP status and the shared command result (including its readback/settlement). Process text is stdout followed by stderr for parsing, while both streams remain separate in the receipt. Zero process exit/HTTP 2xx plus valid UTF-8 permit parsing; neither proves device effects. An opened app URL or distributed notification is dispatch only. HTTP redirects are not followed automatically.

Cancellation/deadline/output-budget exhaustion request termination of the **direct** process or cancellation of the URLSession task. They do not wait indefinitely for SIGTERM, kill a process tree, undo prior changes, or prove the remote side stopped. A receipt includes `processMayBeRunning`. A later manually requested operation is an explicit new request; inspect uncertain external state before retrying. Changing definitions/deleting/sleep/quit invalidates stale completions; it cannot restore external effects. In-flight results and diagnostics are session-local, with no invented log cap or retention period.

Only builds and fake/simulator unit tests verified this implementation. No app/CLI launch, external process execution, HTTP request, distributed notification, device change, installed UI or physical monitor effect was exercised. The central localization catalog must receive `l10n-r2-actions.json` separately.

## Identity and settings lifecycle

Actions and hooks are authored rules, like input hotkeys and app presets. Per-display Forget, Reset, transfer and migration retain their original identifiers and literal executable arguments/URLs; they never reinterpret or retarget those rules. Review, pause or remove them in Actions & Hooks. General app settings reset clears the integration configuration. Archives include definitions and reference their original identities; importing pauses every controller, control and hook until explicit review. Feed also requires an enabled controller/control and parser, even after import. During Shift safe startup a feed may update only its local sample; actions, polls and hooks remain vetoed. Quit stops the session even when no display reversion is needed.

The shared console exposes `feedIntegration`/`feed`, contrast and the existing display commands. Outgoing process/URL/notification definitions and event delivery are configured in Actions & Hooks rather than accepted as arbitrary inbound command payloads. HTTP admits feed; CLI IPC retains the branch's explicit feed refusal. Clock Mode uses the shared brightness engine with its lifecycle guard, rather than adding a second schedule command implementation.
