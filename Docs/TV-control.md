# FreeDisplay network TV control (FD-051 / FD-052)

The per-display **TV control** card provides a public-network LG webOS SSAP client and Samsung Tizen remote client. The same code ships in the full and PublicAPIOnly builds. No entitlement, private macOS transport, vendor signing certificate or new dependency is involved. This implementation has package/fake-transport and build verification only; no real TV, audible response, source switch, standby or wake was tested.

## Setup and lifetime

Everything starts disabled. Select a physical display, enable its controller, choose the family, enter the current host and WebSocket service port, and supply the pairing/network-inactivity deadline, command-response deadline and session lifetime explicitly. There are no chosen timing values, implicit polling loops, automatic retries, startup connections or automatic power actions. Save, then **Pair / Reconnect**. LG uses the TV prompt or an explicitly selected PIN flow. Samsung waits for its authorization event and retains a returned token when present. A saved endpoint alone does not authorize commands.

Optional discovery sends one SSDP search after the user supplies its discovery window and MX response delay. LG advertisements must identify its second-screen service; Samsung candidates must advertise Samsung in their service/server data. Discovery is an untrusted address hint: the descriptor port is not a WebSocket port, the advertised UUID is not authenticated, and candidates never silently select a display, pair, replace an endpoint or supply a MAC. Models without these advertisements can be configured manually. No descriptor URL is fetched. A discovery window without results does not establish absence.

Each session owns its socket and generation. Editing an endpoint disconnects it immediately. Saving a different Samsung endpoint deletes its local endpoint-bound token/pin. LG retains its key across an explicitly saved DHCP address change, subject to the same pinned TLS leaf when configured. Changing the family or LG pairing mode clears old credentials. Reconnect does not replay power, source or mute actions. A response deadline closes the old session and invalidates pending work; uncertainty is not retried. A session can be cancelled, disconnected, locally unpaired or disabled independently.

The platform request-inactivity and resource-lifetime settings are explicitly supplied from the card, as are pairing and response timers. A caller chooses suitable values for its network and TV; the implementation supplies no cadence or count. URLSession's native frame buffering and OS network/Keychain constraints still apply; no custom frame/body/result cap was introduced.

## TLS and secrets

Use the vendor's supported `wss` endpoint. Normal system certificate validation applies by default. For a self-signed device, the user must obtain and independently verify the exact SHA-256 fingerprint, enter it in the card and explicitly approve it. Only that leaf, host and port are accepted by that device's session. A mismatch fails closed. There is no global trust exception and no silent trust-on-first-use. Unencrypted `ws` is an explicit per-controller choice with a credential-exposure warning; the implementation never downgrades automatically. Automatic fingerprint retrieval is deliberately absent.

Keys/tokens and approved pins are stored in Keychain as a non-synchronizing, unlocked-this-device-only generic password keyed by controller UUID. They are excluded from Codable controller configuration and typed requests/results. Samsung requires a token in its protocol URL; its session rejects HTTP redirects and does not log URLs, frames, credentials or vendor error payloads. Deleting local pairing disconnects and removes the Keychain record; it does not revoke authorization in the TV's own settings. Removing a controller disables it while retaining configuration and credentials, and does not restore TV hardware state.

Configuration uses the additive `opendisplay.tvControllers.v1` UserDefaults key, keyed by stable display record ID. Existing settings keys and archive schemas are untouched. This separate controller configuration is not added to existing settings archives in this branch; a general settings backup is not a TV-credential backup. Remote expansion has its own per-display preference. Changing a video display selector never redirects a command to the first or main display.

## Commands and evidence

| Capability | LG webOS | Samsung Tizen | Result evidence |
|---|---|---|---|
| Relative volume up/down | SSAP volume request | One remote key | No fabricated percentage or loudness measurement |
| Mute toggle | Fresh mute-state read, then explicit inverse state | One `KEY_MUTE` | Unknown LG state refuses before writing; Samsung state remains unknown |
| TV power off | SSAP turn-off request | One `KEY_POWEROFF` | No DDC-off, picture blanking or guaranteed standby inference |
| Inputs | Refresh device-reported IDs/labels, then switch one known ID | Source/HDMI remote keys only | Requested input is separate from observed active input; no active checkmark |
| WOL | Independent magic packet | Independent magic packet | Submission only; no wake guarantee |

Power-off and LG direct input changes show a return-path confirmation. Samsung source/HDMI keys are explicitly model-dependent; keep the physical remote and a separate screen available. Denied LG operations fail individually without revoking a working session. A successful protocol acknowledgement means the TV accepted a request, not that its panel/audio/input physically changed. Samsung key submission has no command-level acknowledgement, so it always remains unconfirmed. Connection readiness and per-feature receipts are separate state.

The shared `AutomationRequestParser` recognizes `tvControl` with `display`, `action`, optional `input`, and `dryRun`. It uses the existing selectors and the existing `AutomationEngine`/`ResultEnvelope`/HTTP-status/exit/outcome mapping. It does not parse independent selectors or convert volume units. Its typed command is `.tvControl(TVAction)`, result field `tv` is additive, and primitives default to refusal. Only the in-app console surface is admitted in this branch (the card uses that app-owned engine path). HTTP, CLI, URL and App Intents do not acquire permission to operate a paired TV merely because they can parse the new command. Pairing and endpoint/secret changes are UI operations, not remote commands. WOL can resolve a remembered offline display; ordinary remote actions require a connected associated display and ready controller. Safe startup refuses TV commands and disables the card.

Supported actions: `volumeUp`, `volumeDown`, `muteToggle`, `powerOff`, `refreshInputs` (LG), `switchInput` with an exact LG-reported `input` ID, `source`/`hdmi` (Samsung), and `wake` (separately configured). Unknown actions, an input argument on another action, ambiguity, missing targets and unready capabilities refuse before sending. Dry run sends nothing. No action auto-pairs or auto-reconnects.

## Independent Wake-on-LAN

Enter the Ethernet or Wi-Fi interface MAC explicitly, plus a separate destination host/broadcast address and UDP port. DHCP endpoint edits never alter this MAC. The packet contains the standard six `ff` bytes followed by sixteen repetitions of the six-byte MAC. A selected MAC does not establish compatible network standby, broadcast/VPN reachability, Wi-Fi wake or the correct interface. No wake probe, ARP-derived MAC inference, delayed wake pass or repeated wake submission is inferred. Pending WOL submission is cancelled when its controller changes. Actual wake requires separate future observation.

## Remaining parity boundaries

LG signed/full manifests, picture/backlight/contrast/saturation writes, absolute volume, continuous subscriptions/polling, full keypad/navigation remotes and lifecycle-triggered power policies are not exposed. Samsung direct named-input lists, absolute volume and backlight are not simulated. Native volume-key controller precedence must be integrated with the separate keyboard/audio workstream; these sessions do not hijack native audio or DDC ownership. There are no automatic Samsung power toggles, so duplicated wake passes cannot reverse power; no selector for those advanced actions is advertised. Service menus, Philips, Yamaha and HDMI-CEC remain other clusters. Source-topic criteria covering these broader features remain partial in the handoff report.

Protocol compatibility, model-specific permissions, actual multicast/broadcast routing, TLS/Keychain prompts and physical effects require an explicitly authorized later hardware pass. The package fakes validate software behavior, not vendor firmware compatibility.

Protocol references: [LG-origin Connect SDK SSAP client](https://github.com/ConnectSDK/Connect-SDK-Android-Core/blob/master/src/com/connectsdk/service/webos/WebOSTVServiceSocketClient.java), [Connect SDK webOS commands](https://github.com/ConnectSDK/Connect-SDK-Android-Core/blob/master/src/com/connectsdk/service/WebOSTVService.java), [Samsung remote client implementation](https://github.com/vrachieru/samsung-tv-api/blob/master/samsungtv/remote.py), [Apple URLSessionWebSocketTask](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask), [Apple Network connection groups](https://developer.apple.com/documentation/network/nwconnectiongroup).

## Integration lifecycle and settings scope

Quit disconnects every TV session, cancels pending WOL and discovery, and rejects new TV work before display recovery begins, including the immediate-quit path. Shift safe startup still refuses all TV I/O. Shared-engine TV commands remain console/app-only: CLI IPC, HTTP, URL and Intents explicitly refuse them. Structured integration actions/hooks also refuse TV remote commands, preserving this branch's absence of automatic TV power policies.

TV configuration, local Keychain pairing and remote expansion remain device-bound on this Mac under their original IDs. They are deliberately excluded from app archives/import/reset, per-display Forget/Reset and FD-044 transfer/migration: a video-identity replacement cannot prove consent to a network endpoint/MAC, and a copied UUID must not silently reuse a Keychain association. Disable/remove a controller or delete local pairing explicitly in TV control. Removal retains configuration; local credential deletion never claims TV-side revocation. HTTP configuration/Keychain token likewise remain outside portable app archives/reset, retaining existing client credentials and stable port; change them explicitly in Automation.
