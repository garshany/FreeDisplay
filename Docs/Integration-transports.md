# FreeDisplay local integration

FreeDisplay has its own protocol. BetterDisplay notification names, HTTP paths, query tokens and
Home Assistant recipes are not wire compatible.

## Running-app CLI and same-user IPC

`opendisplay help` and `commands` work locally without constructing providers. Typed commands
prefer same-user app IPC. When the endpoint is absent/refuses connection before sending any request
bytes and neither known app bundle ID is running, the original standalone shared-engine/provider
path is selected. The persisted managed-offline ledger and hardware are then authoritative, so
`opendisplay recover` works after an app crash. A reachable endpoint always wins. A running app with
unreachable IPC refuses rather than racing its state. Nothing launches the app automatically.

Timeout, cancellation, unsafe ownership/permissions, malformed/correlation-mismatched response,
not-ready response and every error after send never cause standalone retry. Accepted work may still
complete. Engine results retain the shared 0/1/2/3 exit mapping. Typed CLI JSON adds top-level
`servedBy: app|standalone` without replacing existing keys/schema versions. App-off `ready` reports
false and exits 1 without constructing providers.

Standalone retains w4's refusals for atomic offsets, software dimming, mode/main keep/revert and
ICC (including discovery). Hardware brightness and normalized ranged DDC contrast run through the
shared engine. Legacy read-only forms, including DDC reads, scene plans and registry-backed listing,
work while the app runs; their identity resolution uses a memory snapshot instead of saving registry
changes. Legacy writes to app-owned hardware/ledger/registry/settings/scenes still refuse while it
runs. Raw `ddc … contrast` is never reinterpreted as normalized contrast. See the complete
[verb → app running / app off table](../Tools/opendisplay/README.md#execution-table).

Examples (documentation only; choose a real explicit stable ID from discovery):

```sh
opendisplay ready --timeout 3
opendisplay list --json
opendisplay brightness id:RECORD '40%' --method hardware --json
opendisplay brightness id:RECORD --offset '+5%' --json
opendisplay contrast id:RECORD '40%' --json
opendisplay mode id:RECORD 1920x1080@60 --json
opendisplay command resetColorProfile display=id:RECORD --json
opendisplay recover --json
```

No timeout is imposed unless the caller passes `--timeout <finite-positive-seconds>`. The example
value is a caller choice, not a product default. A timeout or cancellation abandons the reply; accepted
work can still complete. There is no implicit retry and no claim of rollback on disconnect.

`group:<name>` absolute automatic brightness uses the app's existing group-base policy, including
learned offsets, live FaceLight/preset ownership and absent members. Group offsets/method overrides
refuse. Single-display writes retain the app's existing group synchronization and OSD funnel.
CLI mode/main requests retain the app's keep/revert confirmation; only a genuine App Intent may
use the existing explicit confirmation bypass. IPC never lets a client choose its surface.

The public POSIX Unix socket is at the user's Foundation Application Support directory followed by
`OpenDisplay/ipc/control.sock` (same non-sandboxed user directory for app and CLI). The IPC directory
must be owned by the effective UID, be a real directory and have mode 0700; socket mode is 0600.
Both peers verify the UID with `getpeereid`. A 0600 no-follow lock file, held with `flock`, protects
listener ownership and stale socket cleanup. The protocol grants the current user the CLI surface;
it is not an authorization boundary against another process already executing as that user.
Full/public-only builds share this endpoint; one owner binds it, and the other reports a bind failure.

One connection carries one compact Codable JSON request, followed by a write-half close (EOF).
The server returns one JSON response and closes. The protocol values live in
`AutomationSchema.LocalAutomationProtocol`. A request has `version: 1`, `id: UUID`, and an optional
`command: AutomationRequest`. Omitted command queries readiness. Responses echo the UUID and
carry exactly one of `readiness`, typed `AutomationResult`, or protocol `failure`. The JSON encoding
of associated-value enums is Swift Codable's synthesized representation; use the published Codable
types, not an invented flat command JSON. JSON dates on this socket use the default Foundation
Codable date strategy on both ends (HTTP/CLI presentation keeps its existing ISO-8601 encoder).

Readiness becomes `ready` after the app's startup-load/automation barrier. A starting/stopping
listener refuses commands with `notReady`; readiness queries do not execute display operations.
Malformed or unknown-version requests cannot reach the engine. Every request is correlated,
including protocol rejection of a decoded request. The server imposes no payload cap, timeout,
retry count or polling interval. Its byte-read chunk size is not a message-size limit; the socket
backlog uses the OS maximum rather than a product-selected connection cap. Resource use is subject
to OS limits. There is no required termination notification after a crash; a new owner clears the
stale socket only while holding the owner lock.

## Durable authenticated HTTP

Settings → Automation → Local HTTP control is explicitly off on a new installation. Once enabled,
the listener belongs to the application and continues after Settings closes. On subsequent launches
it starts only because the user previously enabled it. Quit stops both transports. HTTP readiness
is shown only after Network.framework reports a bound listener; the saved enabled preference alone
is not Running. A failure leaves enabled intent visible with Retry, without pretending a listener exists.

Loopback (`127.0.0.1`) is the default. Remote access is a separate setting requiring a warning
confirmation, and binds IPv4 `0.0.0.0`. HTTP is unencrypted: remote mode exposes credentials and
commands to anyone able to observe that traffic. Use a trusted network or authenticated TLS tunnel;
do not expose this listener to the public internet. This app does not provision TLS certificates,
firewall rules or remote Home Assistant configuration.

No fixed default port was invented. Blank asks the OS for a port once; on successful binding that
port is saved. Further launches reuse it and report a bind error if unavailable. Enter a chosen
1–65535 port to reconfigure deliberately. Applying unchanged configuration leaves clients alone;
changing listener configuration retires old connections/listener. The token is independent of the
port and unchanged by reconfiguration. Invalid port input leaves the current service intact.

The existing 32-random-byte bearer token is now stored only in a per-user generic-password Keychain
item (`local.personal.OpenDisplay.http`, account `integration-token`), with device-only access after
first unlock. A denied/locked/corrupt Keychain item fails closed; it is never silently replaced.
Copy HTTP Token explicitly copies the secret to the clipboard; treat the clipboard as private.
Replace HTTP Token is available with HTTP disabled and deliberately revokes the old token. Update
all clients afterwards. Disabling HTTP removes listener access and its in-memory credential; it
keeps the Keychain credential for the next deliberate enable. This stable-token requirement
supersedes the original guide acceptance wording about revoking the saved credential on every stop.
No token enters settings exports, URLs, logs or diagnostics. The new configuration uses a separate
versioned UserDefaults value, preserving existing settings/archive schemas; it is not currently
included in SettingsArchive export/import/reset.

Existing authenticated routes remain:

- `GET /v1/displays`: app-cache brightness with provenance/age; no physical-luminance claim.
- `GET /v1/commands`: the shared HTTP command catalog.
- `POST /v1/brightness`: legacy fields/response plus typed selector/value/offset/method support.
- `POST /v1/reconnect-all`: background accepted/no-op IDs; use discovery/audit for later results.
- `POST /v1/command`: flat named parameters through `AutomationRequestParser`, including
  `getContrast` / `setContrast` or the `contrast` alias (without/with `value`).

Mutations remain POST JSON with `Authorization: Bearer <token>`. No query-string tokens, GET
mutations, browser Origin requests or unauthenticated mode. Existing eight connections, five-second
connection lifetime, 8192-byte request and 256-byte body limits remain unchanged. A long operation
may outlive a connection; losing its reply is not a rollback or reason for automatic retry.
Statuses distinguish credentials (401), unknown identity/route (404), ambiguity/offline/busy (409),
invalid values (400), unavailable method/capability (422), unconfirmed/failed execution (502),
not ready (503), partial (207), and handled success (200). Machine outcomes/readback do not measure
physical luminance. Hardware-only brightness refuses a software-only route. Contrast is normalized
ranged hardware contrast, not software contrast or raw VCP units.

## Home Assistant example

Enable HTTP explicitly, retain the displayed chosen port/token, discover the stable display ID and
verify the hardware route manually before enabling an automation. For a remote HA host, `127.0.0.1`
means HA itself; use a deliberately configured trusted network or TLS tunnel to this Mac. Prefer
the tunnel with loopback HTTP retained. Merge a scoped entry into an existing `rest_command` mapping
and use HA's private secret storage. Do not replace unrelated commands or paste the token into logs:

```yaml
# secrets.yaml — private; replace placeholders locally
freedisplay_endpoint: "https://YOUR_AUTHENTICATED_TUNNEL/v1/command"
freedisplay_authorization: "Bearer YOUR_PRIVATE_TOKEN"

# configuration.yaml — merge under the existing mapping if present
rest_command:
  freedisplay_desk_brightness:
    url: !secret freedisplay_endpoint
    method: POST
    headers:
      authorization: !secret freedisplay_authorization
    content_type: application/json
    payload: '{"command":"brightness","display":"id:YOUR_RECORD_ID","value":"40%","method":"hardware"}'
```

HA/tunnel timeout policy belongs to that client's configuration; no timeout value is prescribed.
Reload only the affected HA configuration using the installed HA version's documented method.
Inspect HTTP status and result/readback before attaching triggers. Repeating an absolute target is
idempotent; repeating offsets intentionally moves it again. Remove only this automation/secret on
cleanup, retain shared server access for other clients, and disable HTTP if it has no remaining
clients. Cleanup never claims to reverse earlier display writes. HA reachability, TLS tunnel setup,
firewall behavior, Keychain prompts, runtime sockets and physical panel effects require separate
manual acceptance; this branch verifies builds and fake/unit logic only.
