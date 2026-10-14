# Session-only local HTTP automation

Original GPL-3.0-or-later implementation. Existing CLI, App Intents and URL commands remain the established automation surfaces. This module adds an explicit-start HTTP front door; construction and normal app launch bind no socket.

`LocalControlServer.start(gateway:handler:)` listens only on IPv4 127.0.0.1 at an OS-selected ephemeral port. Every session creates a 256-bit Security-framework random bearer token. The app must display port and token privately after listener readiness; token must not enter logs, URLs, preferences or telemetry. Stop invalidates token, listener, active connections and timeout tasks. Start failures leave the feature stopped. App integration should call stop on termination and expose a clear Stop button.

All requests require `Authorization: Bearer TOKEN` and Host. POST requires Content-Length and application/json; a body-less GET may omit Content-Length (treated as 0), as curl and browsers do. API v1:

- `GET /v1/displays`, zero-byte body: injected handler returns current display status JSON.
- `POST /v1/brightness`, body `{"displayId":"explicit-id","value":0.5}`: value must be a JSON number in 0...1. Handler resolves the exact currently known ID and invokes the normal validated app brightness route, reporting hardware/software/unsupported and verification honestly.
- `POST /v1/reconnect-all`, body `{}`: existing CommandGateway recovery route and ResultEnvelope.

No disconnect/layout/mode/shell/URL forwarding endpoint exists. Brightness and readback use a typed MainActor handler injection; caller must not interpret arbitrary command strings or report a queued operation as verified. Unsupported display IDs must return an explicit error JSON, never select a fallback display. Result envelopes retain their actual command outcome even when HTTP transport succeeds.

Threat and recovery review: loopback limits remote hosts, token authenticates local clients, Origin is rejected to constrain browser-driven requests, no CORS is emitted. Framing is strict (duplicate headers, Transfer-Encoding, body surplus/pipelining and unknown keys fail closed). Requests are capped at 8192 bytes, JSON bodies at 256, eight simultaneous connections, five-second lifetime. Local malware with process access remains outside this boundary. Connections time out independently; cancelling transport does not undo an accepted recovery operation. Existing emergency recovery remains available.

Integration: retain one LocalControlServer in AppModel. Start explicitly with the app's gateway; supply a handler switching only `.displays` and `.brightness(displayId:value:)`. Expose listener port after readiness, token and failure status through the app's observable state; server properties themselves are not Observation-backed. Actor `.httpAPI` is the audit provenance for reconnect requests.

Network TV/AVR and HDMI CEC remain unsupported in this implementation. Neither generic HTTP nor HDMI presence identifies a device protocol or CEC adapter. A future device provider requires explicit configured endpoint, a documented supported model/protocol and verification evidence; no discovery or LAN scanning is performed. CEC requires a compatible adapter/driver transport and is not implemented by CoreGraphics. No universal TV/AVR compatibility claim is made.

Tests cover authorization, allowlisted routing, numeric/boolean brightness validation, request fragmentation, duplicate framing, Origin rejection, oversized requests, pipelining and exact response byte length. No server or display mutation is exercised by parser tests.

## Verified loopback behavior (2026-10-13)

`Tests/Integration/run-local-control-loopback.sh` builds the parser unit tests and a native Network-framework harness. It uses `SimulatedDisplaySystem` with no real displays and only synthetic injected handlers. It never queries CoreGraphics or controls hardware. Run from the repository root on macOS; local socket binding may require the ordinary sandbox approval.

Live loopback assertions passed: construction binds nothing; explicit start becomes ready; duplicate start keeps session; wrong bearer returns 401 without dispatch; authenticated display list returns 200; validated brightness returns 200 and exact typed arguments; boolean/out-of-range brightness returns 400 without dispatch; reconnect-all reaches simulated gateway and returns 200/noOp; forbidden endpoint returns 404; Origin returns 400; body over 256 returns 400; request over 8192 returns 413; incomplete request closes by deadline; stop cancels an in-flight cooperative handler and closes connection; stop clears token/port; restart rotates token, rejects old token (401) and accepts new token (200); repeated stop is safe. Credentials are never printed.

Stop and deadlines cancel tracked command tasks as well as sockets. Cancellation is cooperative: a handler must honor cancellation when waiting; an operation already handed to a hardware provider cannot be assumed rolled back. Real hardware brightness/verification, CoreGraphics reconnect, eight-client saturation, listener startup failure injection, clipboard interaction, system notification delivery and Siri/Shortcuts invocation are not verified by this harness. No claim of every hardware function being verified follows from these tests.

The local panel, Shortcuts descriptions/dialogs and visible display notifications use Russian; HTTP field names, command IDs and status values remain stable English identifiers.
