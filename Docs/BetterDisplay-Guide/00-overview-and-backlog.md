# BetterDisplay guide — overview and consolidated backlog

## 1. Overview

This consolidates all nine studies of the official BetterDisplay guide: interface/settings references, integration and licensing, technical reference, FAQs and task tutorials. All nine Markdown files were read in full. Their detailed Topics retain the behavior, repository `file:line` evidence, implementation notes and acceptance criteria; this file provides the cross-part roadmap.

**Scope:** FreeDisplay on Apple silicon/macOS 14+, using the studies' **2026-10-14 static code snapshot**. This consolidation does not refresh the code audit or establish build, UI, hardware, sleep/wake or installation success. Guide references to newer macOS releases require availability checks, not a raised minimum OS. BetterDisplay tiers describe that product only; no paid gates are proposed for FreeDisplay.

### Coverage

Counts below come from each Coverage table, numbered Topics and Backlog rows. Pages include indexes/landing pages; topics and backlog rows overlap across parts and are not unique feature counts.

| Part / source | ID prefix | Pages / entries | Topics | Backlog | P0 / P1 / P2 / P3 |
|---|---|---:|---:|---:|---|
| [01 — App menu](01-app-menu.md) | AM | 32/32 | 28 | 50 | 10 / 10 / 23 / 7 |
| [02 — Display settings](02-settings-displays.md) | SD | 30/30 | 28 | 46 | 7 / 14 / 19 / 6 |
| [03 — Other settings](03-settings-other.md) | SO | 23/23 | 25 | 40 | 4 / 23 / 10 / 3 |
| [04 — Integration & licensing](04-integration-licensing.md) | IN | 18/18 | 24 | 31 | 5 / 13 / 9 / 4 |
| [05 — Technical reference](05-technical-reference.md) | TR | 109/109 | 39 | 47 | 9 / 11 / 20 / 7 |
| [06 — FAQ A](06-faq-a.md) | FA | 112/112 | 51 | 50 | 8 / 15 / 21 / 6 |
| [07 — FAQ B](07-faq-b.md) | FB | 139/139 | 70 | 54 | 8 / 9 / 31 / 6 |
| [08 — Tutorials A](08-tutorials-a.md) | TA | 19/19 | 18 | 36 | 3 / 6 / 23 / 4 |
| [09 — Tutorials B](09-tutorials-b.md) | TB | 19/19 | 19 | 38 | 4 / 9 / 22 / 3 |
| **Total** | | **501/501** | **302** | **392** | **58 / 110 / 178 / 46** |

Part 08 counts **18 readable pages plus one fully read corrupted MP4-to-text copy**. Its parent caption was checked by that study, but the video was not visually decoded. Thus 501 is manifest coverage, not a claim of 501 prose pages or complete visual-media verification.

### Reading statuses and tiers

- **✅ Implemented:** the narrowly named code path exists; hardware acceptance remains outstanding.
- **🟡 Partial:** a useful subset exists, or an existing path has a documented correctness/reporting defect.
- **⬜ Missing:** the required path was not found within the studied UI/model/provider boundaries.
- **➖ Not applicable:** commercial policy, external-product responsibility or a platform/hardware limit; not an unimplemented promise.

Free/Pro classifications follow the detailed source topics; “mixed” separates constituent operations, and “unspecified” avoids inventing a tier. Broad comparison-table labels do not override more specific behavior. Basic combined dimming is labeled Free in part 04, while the tutorials attach Pro requirements to floor/calibration workflows; those scopes remain explicit below.

**Reconciliation:** the part-04 comparison calls the resolution slider missing, but parts 01/03/07 identify its implemented tray path; it is **partial**, with preservation/filtering defects. Similarly, implemented DDC commands, capture, virtual creation or schema fields do not establish complete workflows. The studies differ in wording about custom-profile gamma-guard scope; FD-017 must resolve the policy explicitly. Preserve FreeDisplay's timed mode rollback, ambiguity rejection and authenticated POST/header-token HTTP rather than copying less safe guide behavior.

## 2. Feature parity summary

Backlog IDs below are the consolidated **FD** clusters in section 3. Follow their source IDs to the linked part above for detailed evidence and acceptance. “—” means no additional cluster for that narrowly scoped row.

### Brightness & dimming

| Capability | BetterDisplay tier | FreeDisplay status (✅/🟡/⬜/➖) | Backlog IDs |
|---|---|---|---|
| Native/DDC/software brightness and basic dimming | Free | 🟡 Existing routes; floor, gamma and delivery defects | FD-004, FD-017, FD-006, FD-053 |
| Hardware/software combined range and hardware floor | Free basic combination; Pro floor/calibration; see tier caveat | ⬜ Existing “combined” means gamma + overlay | FD-104 |
| Nits labels and anchors; luminance matching | Free anchors/labels; Pro sync | ⬜ No explicit provenance/range model | FD-046, FD-119 |
| Native automatic brightness, startup/wake and lock policies | Mixed; basic restore Free | 🟡 Observation/adaptive loop exists; ownership/restore incomplete | FD-124, FD-123, FD-115, FD-122 |

### XDR/HDR

| Capability | BetterDisplay tier | FreeDisplay status (✅/🟡/⬜/➖) | Backlog IDs |
|---|---|---|---|
| Software built-in XDR boost | Pro | 🟡 Experimental gamma + small EDR trigger; not full-desktop Metal | FD-114, FD-017 |
| External HDR upscaling, calibration and neutral readiness | Pro | ⬜ No qualified external/calibrated workflow | FD-114, FD-104 |
| Actual HDR enable/encoding, Apple presets and direct XDR | Pro; availability-dependent | ⬜ EDR information is not an HDR switch/direct nits controller | FD-025, FD-127, FD-091 |
| Legacy native XDR | Pro; older supported OS only | ⬜ Deferred compatibility work | FD-161 |

### Resolutions/HiDPI/scaling

| Capability | BetterDisplay tier | FreeDisplay status (✅/🟡/⬜/➖) | Backlog IDs |
|---|---|---|---|
| Enumerate/select offered complete modes with timed revert | Free | ✅ Explicit mode selection and recovery path exist | — |
| Size slider, exact favorites, filters and physical-size bounds | Free; some advanced options Pro/unspecified | 🟡 Slider/favorites exist; identities and variant preservation need repair | FD-003, FD-012, FD-033, FD-105 |
| Native flexible scaling and model-wide custom modes | Free individual/custom metadata; Pro flexible generation | 🟡 Export-only plans; no installer or activation | FD-116, FD-117 |
| Match physical UI size using existing modes | Pro | ⬜ No watched/affected mode-matching policy | FD-100 |
| Notch, native underscan and expert CRT modes | Feature/OS-dependent; tier unspecified where unstated | ⬜ No complete qualified workflow | FD-145, FD-146, FD-157 |

### Refresh/colour depth/colour mode

| Capability | BetterDisplay tier | FreeDisplay status (✅/🟡/⬜/➖) | Backlog IDs |
|---|---|---|---|
| Desktop-mode refresh selection | Free | 🟡 Offered modes exist; preserve fractional rates and density | FD-003, FD-012, FD-033 |
| Software timing reporter versus connection rates/VRR | Free where available | ⬜ Separate timing reporter/link-rate controls absent | FD-034, FD-082 |
| Link RGB/YCbCr, chroma, range and depth | Free same encoding; Pro encoding changes | ⬜ DDC color presets and ICC do not set link formats | FD-024, FD-081 |
| GPU dithering, uniformity and framebuffer appearance | Free where supported; some tiers unspecified | ⬜ No qualified framebuffer controls | FD-126, FD-125 |
| Intel-only framebuffer-depth branch | Platform-specific | ➖ Outside Apple-silicon target | — |

### Colour profiles & image adjustments

| Capability | BetterDisplay tier | FreeDisplay status (✅/🟡/⬜/➖) | Backlog IDs |
|---|---|---|---|
| ICC selection and user-profile inspection/management | Free | 🟡 Assignment exists; identity/errors and management incomplete | FD-008, FD-036 |
| Temperature, software contrast, suspension and scoped reset | Pro adjustments; basic dimming Free | 🟡 Gamma temperature/dimming exist; no complete composed control model | FD-039, FD-053 |
| Preview filters and shared ordered SDR LUT library | Pro setup/assignment; Free cleanup/export | 🟡 Flip/rotation/central crop and one bounded preview LUT only | FD-086, FD-112 |
| Whole-display compositor, filter windows and HDR LUTs | Pro | ⬜ Preview processing is not display-wide filtering | FD-090, FD-101, FD-113 |
| Night Shift/True Tone and HDR interlock | Mixed; HDR interlock Pro | 🟡 Read-only Night Shift observation; setters/interlock absent | FD-103 |
| Protected/factory profile removal | Privileged; tier varies by operation | ⬜ Separate expert cleanup | FD-141 |

### DDC & device control

| Capability | BetterDisplay tier | FreeDisplay status (✅/🟡/⬜/➖) | Backlog IDs |
|---|---|---|---|
| Predefined brightness/contrast/RGB gains/sharpness/raw VCP | Free | 🟡 Existing private DDC; routing, results and legacy eligibility gaps | FD-006, FD-026, FD-015, FD-031 |
| Capability/configuration, ranges, timing and write-only controls | Free predefined; Pro custom features | 🟡 Fixed controls/diagnostic scans; no full compatibility editor | FD-088, FD-108, FD-111 |
| Monitor power/reset, stateful mute and SCS | Free where supported; SCS source has a no-op caveat | 🟡 Best-effort commands and volume-zero fallback need honest semantics | FD-005, FD-007, FD-030, FD-107, FD-155 |
| DisplayLink manager hardware bridge | Mixed; discovery/configuration restrictions vary | ⬜ Generic enumeration is not driver control | FD-110 |
| CEC and network TV/AVR controllers | Free ordinary controllers; specialist actions vary | ⬜ CEC, LG, Samsung, Philips and Yamaha absent | FD-109, FD-051, FD-052, FD-139, FD-142, FD-143 |
| Model-specific/PBP support | Hardware-dependent; tier unspecified | ⬜ No qualified device-specific adapters | FD-147, FD-156 |

### Input/audio/volume keys

| Capability | BetterDisplay tier | FreeDisplay status (✅/🟡/⬜/➖) | Backlog IDs |
|---|---|---|---|
| DDC input switching and explicit return actions | Free predefined; Pro custom slots/features | 🟡 Fixed inputs exist; optimistic current-state checkmark | FD-006, FD-089 |
| Native audio association and output-following routing | Free | 🟡 Name-based matching; no explicit UID binding or native association | FD-049 |
| Capability-correct volume interception and mute | Free | 🟡 Unknown capability can swallow keys; zero is not guaranteed mute | FD-029, FD-030 |
| Separate engagement, recipient, OS mute passthrough and sequences | Free; advanced sync Pro | ⬜ Policy/editor coverage incomplete | FD-060, FD-049, FD-107 |

### Virtual screens

| Capability | BetterDisplay tier | FreeDisplay status (✅/🟡/⬜/➖) | Backlog IDs |
|---|---|---|---|
| Create preset/custom virtual endpoints | Free presets; Pro custom geometry/configuration | 🟡 Up to four session-only endpoints; no saved disconnected definitions | FD-094, FD-096 |
| Persistent/headless lifecycle, bulk actions and sleep/lock policies | Free basic lifecycle; Pro advanced association/customization | ⬜ No stable saved identity or launch restoration | FD-094, FD-097 |
| Match/associate, orientation-follow and KVM continuity | Pro | ⬜ Connection and presentation policies absent | FD-095 |
| HDR virtual modes and generated rates | Pro custom configuration | ⬜ One requested mode is not a generated qualified range | FD-096, FD-113 |
| Pre-login/FileVault or extra native hardware outputs | OS/hardware limitation | ➖ User-session virtual screens cannot supply these guarantees | — |

### Mirroring/streaming/PiP

| Capability | BetterDisplay tier | FreeDisplay status (✅/🟡/⬜/➖) | Backlog IDs |
|---|---|---|---|
| Native mirroring | Free through macOS; Pro app-managed setup | 🟡 Mirror-to-main only; exact restore/arbitrary source missing | FD-011, FD-083 |
| Single display/window floating preview | Pro start/preferences; Free stop | 🟡 Real SDR capture; editor lifetime and source-context defects | FD-009 |
| Persistent multiple PiP/window/region configurations and picker | Pro setup; Free cleanup | ⬜ One session is not multi-PiP; native picker/recovery absent | FD-085, FD-102, FD-160 |
| Fullscreen target streams; pause/hide/stop and restart ownership | Pro start/pause/preferences; Free stop | ⬜ No receiver manager or independent presentation state | FD-084, FD-129 |
| Geometry, sampling/FPS, pointer mapping and exclusion | Pro | 🟡 Basic preview transforms only | FD-130, FD-131, FD-132, FD-152 |
| Portrait Sidecar, intact-panel area and lock/Spaces workflows | Pro; platform-qualified | ⬜ Missing composed workflows | FD-137, FD-138, FD-133, FD-158 |
| External recorder/network video/HDCP bypass | External product or platform limitation | ➖ No recorder/server/bypass requirement inferred | FD-074 |

### Arrangement/layout & configuration protection

| Capability | BetterDisplay tier | FreeDisplay status (✅/🟡/⬜/➖) | Backlog IDs |
|---|---|---|---|
| Set main display by reanchoring origins | Free | ✅ Public main-display path exists | — |
| Free-drag arrangement and scene restore | Free arrangement; Pro protection | 🟡 Existing canvas/snapshots; mirror eligibility and partial results need repair | FD-010, FD-037, FD-022 |
| Per-property mode/rate/rotation/main/ICC/HDR protection | Pro | 🟡 Bounded topology snapshots; rotation skipped and fields incomplete | FD-028, FD-092 |
| Relative layout anchors, orientation and group-main precedence | Pro | ⬜ Absolute snapshots do not implement relational rules | FD-099 |
| Identical-display identity/transfer/swap | Free identity methods; advanced swap tier unspecified | 🟡 Registry/aliases exist; collision and migration controls incomplete | FD-014, FD-044, FD-106 |

### Groups & sync

| Capability | BetterDisplay tier | FreeDisplay status (✅/🟡/⬜/➖) | Backlog IDs |
|---|---|---|---|
| Named groups, membership, brightness/contrast offsets | Pro custom groups; Free Default Group brightness | 🟡 Persistent groups/observation exist; single-owner membership | FD-038 |
| Default-group absolute/delta/range and operation bypass | Free | ⬜ No equivalent explicit policy/UI | FD-038 |
| Activation/exclusivity/priority and directional typed sync | Pro advanced/custom rules | ⬜ No activation reasons or explicit source/receiver model | FD-098, FD-118 |
| Estimated-nits and physical UI-scale matching | Pro | ⬜ Missing range/scale solvers | FD-119, FD-100 |

### Connection management & recovery

| Capability | BetterDisplay tier | FreeDisplay status (✅/🟡/⬜/➖) | Backlog IDs |
|---|---|---|---|
| Logical disconnect/reconnect, blackout and last-screen rescue | Pro management; recovery remains available | 🟡 Private lifecycle plus public fallback; safety classification/reporting gaps | FD-002, FD-001, FD-016 |
| Selective auto-disconnect and guarded laptop/desk presets | Pro | 🟡 Arrival-edge automation only; exceptions/suspension/presets absent | FD-080, FD-136 |
| Retained offline records, reset/forget and identity continuity | Free record management | 🟡 Ledger/registry exist; full retention and transfer UI absent | FD-043, FD-044 |
| Sleep assertion ownership and safe startup | Free global policy; per-device tier varies | 🟡 Global assertion/limited safe-mode foundations only | FD-073, FD-072 |
| EDID-based reinitialization and adapter/system reset | Free supported reinit; specialist operations vary | ⬜ Redetect is enumeration, not link/adapter reset | FD-128, FD-144, FD-148 |

### Keyboard/shortcuts/OSD

| Capability | BetterDisplay tier | FreeDisplay status (✅/🟡/⬜/➖) | Backlog IDs |
|---|---|---|---|
| Native media keys, modifiers, target sets and logical steps | Free | 🟡 Event tap/basic targeting exist; takeover/eligibility and steps differ | FD-029, FD-060, FD-061, FD-035 |
| Binding persistence, general recorder and shortcut families | Free ordinary actions; advanced families Pro | 🟡 Defaults can reappear; fixed input chords and incomplete catalog | FD-018, FD-062, FD-063, FD-105, FD-120 |
| Custom OSD, independent broadcasts and receiver handshake | Free basic feedback; some extras Pro | 🟡 App-drawn OSD; external-only/event-origin gaps | FD-024, FD-020, FD-064 |
| System keyboard illumination | Free where supported | ⬜ No qualified implementation | FD-140 |

### Menu/UI customisation

| Capability | BetterDisplay tier | FreeDisplay status (✅/🟡/⬜/➖) | Backlog IDs |
|---|---|---|---|
| Device naming and visual identification | Free | ✅ Alias/identify paths exist | — |
| Visibility, icon/order, contents placement and expansion | Free preferences; exposed operations retain tier | 🟡 Fixed inline sections and limited collapse persistence | FD-045, FD-032, FD-077 |
| Detached movable menu and opacity | Pro | 🟡 Pin prevents closure; it is not detachment | FD-079 |
| Resolution/brightness labels and values | Free basic labels; optional styling varies | 🟡 Incomplete labels, steps, nits and metadata policy | FD-035, FD-046, FD-033 |
| Newer-OS Sidebar/cosmetic variants | Platform-dependent; tier unspecified | ⬜ Investigate without raising the macOS 14 baseline | FD-151, FD-145 |

### Automation: CLI/URL/HTTP/Shortcuts/events

| Capability | BetterDisplay tier | FreeDisplay status (✅/🟡/⬜/➖) | Backlog IDs |
|---|---|---|---|
| CLI discovery, typed commands, results and public adapters | Free interface; underlying features retain tier | 🟡 Broad direct CLI; help, exit/result and shared-state gaps | FD-021, FD-022, FD-066 |
| Custom URL confirmation and durable authenticated HTTP | Free interface | 🟡 Disconnect URL is a no-op; loopback HTTP is pane/session-bound | FD-019, FD-023, FD-058 |
| Stable display App Entities and native action catalog | Free interface; underlying features retain tier | 🟡 Only built-in brightness and reconnect-all Intents | FD-067, FD-134, FD-120, FD-059 |
| Outgoing actions, readback/feed and seven event hooks | Free predefined/events; Pro custom controls | ⬜ No configurable shared runner/event model | FD-050, FD-068, FD-069, FD-111 |
| Console, unified logging and DNC request/response | Free | 🟡 Diagnostic logs/broadcast building blocks; console/protocol absent | FD-040, FD-070, FD-078 |
| Per-display schedules, Stream Deck and HA recipes | Free integration; underlying advanced controls vary | 🟡 Clock Mode exists for eligible external DDC; full recipes absent | FD-075, FD-076, FD-058, FD-066 |
| MQTT | Not built into BetterDisplay | ➖ Optional external extension, not a parity gap | FD-162 |

### App settings/updates/notifications

| Capability | BetterDisplay tier | FreeDisplay status (✅/🟡/⬜/➖) | Backlog IDs |
|---|---|---|---|
| Launch on login and system/English/Russian language choice | Free | ✅ Existing ServiceManagement and localization paths | — |
| Settings geometry, backup/import/reset and privacy/help | Free | 🟡 Settings/help fragments exist; full recovery/configuration workflow absent | FD-042, FD-054, FD-071, FD-065 |
| Notification authorization/styles and Dock policy | Free | 🟡 Limited notifications; fixed menu-bar app behavior | FD-055, FD-056 |
| Owned signed updates, lifecycle and release channels | Free update infrastructure | 🟡 Sparkle guarded for local builds; no validated fork distribution | FD-027, FD-041, FD-057, FD-150 |
| Trial, purchases, activation and business-license gates | BetterDisplay commercial policy | ➖ Do not reproduce in free GPL FreeDisplay | — |

### EDID

| Capability | BetterDisplay tier | FreeDisplay status (✅/🟡/⬜/➖) | Backlog IDs |
|---|---|---|---|
| Exact-display read, decode, validate and export | Free | 🟡 CLI/parser/export foundations; ambiguous binding and GUI/DisplayID gaps | FD-013, FD-048 |
| Imported custom blob versus temporary live apply | Pro custom override; Free factory reinit | 🟡 Import/export only; no runtime apply/unapply | FD-093, FD-128 |
| Installed model override versus device-memory writing | Pro software override; expert hardware write tier unspecified | ⬜ Separate privileged/private mechanisms absent | FD-116, FD-149 |
| Intel-only override workflow | Legacy platform-specific | ➖ Deferred outside current Apple-silicon scope | FD-159 |

## 3. Deduplicated backlog

**162 clusters: P0 31 · P1 47 · P2 62 · P3 22.** Every one of the **392 distinct source IDs** is mapped. Repeated descriptions across parts are merged by deliverable, not by keyword alone. Composite source rows appear in more than one cluster only for the distinct scopes named in the descriptions: for example, AM-03 contributes slider correctness and brightness-floor reporting; SD-17 contributes outgoing actions and event hooks. Repeated source references are not additional source items.

**Priority is the highest urgency of the listed sources** (P0 before P1 before P2 before P3), without averaging. Thus capture lifetime becomes P0, DisplayID decoding P1, Philips control P2 and keyboard illumination P2 despite lower-priority mentions elsewhere. A source priority is not a release promise or permission to bypass platform safeguards.

**Effort:** S = localized change; M = substantial bounded feature; L = multiple components/new subsystem or extensive compatibility work. These are consolidated scope estimates, not durations. **API risk:** Public = documented APIs/policy, still subject to permissions and device/protocol qualification; Private = private SPI or hardware/driver transport; Mixed = public orchestration with private dependencies; Privileged/private = authorized system installation plus undocumented/OS-specific behavior. Existing native brightness/DDC/virtual providers do not become public APIs because a new UI or Intent calls them.

Dependencies are FD cluster prerequisites, not the source numbering order. For a composite feature, dependencies apply to the relevant slice: public protection fields can precede private HDR/rotation support. P0 findings are static defects; their physical consequences have not been reproduced by this study.

### P0 — 31 clusters

| ID | Source IDs | Priority | Effort | API risk | Description | Dependencies |
|---|---|---|---|---|---|---|
| FD-001 | AM-01, FA-04 | P0 | M | Mixed | Distinguish true disconnection, mirror fallback, blackout and monitor standby in every result and label. | FD-002 |
| FD-002 | AM-02, SD-07, FB-01, TA-01, TA-16 | P0 | L | Mixed | Unify physical endpoint eligibility, affected-model refusals and last-usable-screen recovery safety. | — |
| FD-003 | AM-03, SO-02, FB-03 | P0 | M | Public | Keep size-slider changes within the exact current rate/density/depth and retain the current stop. | FD-012 |
| FD-004 | AM-03, TR-02 | P0 | M | Public | Report effective software dimming limits instead of an unattainable cached brightness. | — |
| FD-005 | AM-04, SD-03 | P0 | M | Private | Confirm DDC power actions and report delivery, uncertainty and recovery separately. | FD-002, FD-006 |
| FD-006 | AM-05, FA-02, FB-06, TA-03, TB-01 | P0 | M | Private | Separate requested, delivered and observed DDC state; never mark an unverified input current. | — |
| FD-007 | AM-06, FA-03 | P0 | M | Private | Separate app resets from monitor reset commands and retain failed hardware outcomes. | FD-006 |
| FD-008 | AM-07, FB-07 | P0 | M | Public | Preserve distinct ICC identities, propagate assignment errors and refresh actual selection. | — |
| FD-009 | AM-08, TA-02, FB-42 | P0 | M | Public | Own capture outside Settings, bind the intended source and handle stop/source-loss races explicitly. | — |
| FD-010 | AM-09 | P0 | M | Public | Exclude mirror receivers from independent arrangement and distinguish source/receiver roles. | — |
| FD-011 | TR-04 | P0 | M | Public | Save and restore the exact mirror source/receiver relationship rather than a Boolean. | FD-010 |
| FD-012 | AM-10, FB-02 | P0 | M | Public | Persist complete favorite mode identities including fractional refresh, density and depth. | — |
| FD-013 | SD-01, TR-05, FB-05 | P0 | M | Public | Bind EDID reads/exports to the selected display and reject ambiguous matches without losing extensions. | FD-014 |
| FD-014 | SD-02, TR-09 | P0 | M | Public | Prevent remembered-display collisions and preserve distinct physical identities. | — |
| FD-015 | SD-04 | P0 | M | Private | Make relaxed DDC checksum handling an explicit compatibility choice, never silent acceptance. | — |
| FD-016 | SD-05 | P0 | M | Mixed | Retain unresolved disconnect intent when reconnect-on-quit fails. | FD-002 |
| FD-017 | SD-06, SD-20, FB-04 | P0 | M | Public | Honor overlay-only gamma bypass, custom-profile safety and write failures with recoverable fallback. | FD-008 |
| FD-018 | SO-01 | P0 | S | Public | Persist explicit shortcut disablement so defaults do not resurrect cleared bindings. | — |
| FD-019 | SO-03, IN-03 | P0 | M | Mixed | Complete the visible URL disconnect review or reject it explicitly instead of silently activating the app. | FD-002, FD-001 |
| FD-020 | SO-04, IN-04, FA-06 | P0 | M | Public | Publish control events independently of local HUD rendering and make external-only delivery state truthful. | — |
| FD-021 | IN-01 | P0 | S | Public | Repair help dispatch and document only implemented CLI verbs. | — |
| FD-022 | IN-02, TB-04 | P0 | M | Mixed | Return structured partial/failure results and exit codes for scene, brightness and device operations. | — |
| FD-023 | IN-05 | P0 | S | Public | Label cached/default brightness and freshness; preserve unknown values. | — |
| FD-024 | TR-01, TR-07, FA-05 | P0 | S | Public | Correct native-resolution, DDC preset and app-drawn OSD labels so they do not imply unsupported controls. | — |
| FD-025 | TR-03 | P0 | S | Public | Keep unknown HDR state unknown instead of treating absence as confirmed SDR. | — |
| FD-026 | TR-06 | P0 | M | Private | Reject ambiguous IOAVService routing so DDC cannot silently target another monitor. | FD-014 |
| FD-027 | TR-08 | P0 | M | Public | Fail release verification on signing/Gatekeeper errors and require the intended signing identity. | — |
| FD-028 | FA-01 | P0 | M | Mixed | Stop reporting/retrying a protected rotation restore that the scene executor skips. | FD-022 |
| FD-029 | FA-07, TB-02 | P0 | M | Mixed | Consume native volume keys only for a usable capability; unknown routes retain native handling. | — |
| FD-030 | FA-08, TB-03 | P0 | M | Private | Unify GUI/CLI mute semantics, distinguish minimum volume from silence and never invent restore levels. | FD-006 |
| FD-031 | FB-08 | P0 | M | Private | Refuse unsafe legacy Apple DDC probing by default and isolate any expert override. | FD-002, FD-026 |

### P1 — 47 clusters

| ID | Source IDs | Priority | Effort | API risk | Description | Dependencies |
|---|---|---|---|---|---|---|
| FD-032 | AM-11, SO-19, SO-23, FA-14, FA-15, TR-45, FA-49 | P1 | L | Public | Add capability-driven menu visibility/placement, symbol picker, icon/favorite precedence and a recovery entry point. | — |
| FD-033 | AM-12, SD-12, SO-24, TR-12, FB-09, TA-05 | P1 | M | Public | Unify complete-mode filters, resolution bounds and editable physical-size metadata without inventing modes. | FD-003, FD-012 |
| FD-034 | AM-13 | P1 | M | Public | Report nominal and software-measured refresh separately from physical panel/link timing. | — |
| FD-035 | AM-14, SO-29, FA-19 | P1 | M | Public | Unify standard/fine steps, snapping, scroll and release behavior with truthful effective values. | FD-004, FD-003 |
| FD-036 | AM-15, TR-11, FB-11 | P1 | M | Public | Inspect profiles, explain calibration and manage user-owned copies with stable identity and targeted undo. | FD-008 |
| FD-037 | AM-16 | P1 | M | Public | Provide one robust free-drag arrangement canvas with main-display changes and rollback. | FD-010, FD-011 |
| FD-038 | AM-17, SO-05, TR-15, TB-14, TA-18 | P1 | M | Mixed | Add an explicit Default Group and basic absolute/delta/range/external-change sync with Shift bypass. | FD-004 |
| FD-039 | AM-18, IN-17, TR-14 | P1 | M | Public | Compose software contrast with dimming/temperature and add scoped suspension/reset and normalized controls. | FD-017, FD-004 |
| FD-040 | AM-19, IN-14 | P1 | M | Public | Provide an app-owned command console with help, history and bounded output, separate from a shell. | FD-066, FD-021 |
| FD-041 | AM-20, SO-14 | P1 | M | Public | Expose update errors, compatibility, cancellation, stale offers and restart states coherently. | FD-027 |
| FD-042 | SD-08, SO-10 | P1 | M | Public | Restore Settings pane/window geometry and expose bounded timing, privacy and motion preferences. | — |
| FD-043 | SD-09, FB-13 | P1 | M | Public | Browse retained offline records and distinguish confirmed forgetting from reset or disconnection. | FD-014, FD-016 |
| FD-044 | SD-10, FA-11, TB-09 | P1 | L | Public | Explain identity matching and retention, preview settings transfer and migrate durable per-device preferences. | FD-014, FD-043 |
| FD-045 | SD-11, FA-12 | P1 | M | Public | Persist device names, icons, ordering, menu visibility and keyboard eligibility independently. | FD-014 |
| FD-046 | SD-13, TR-13, TB-13 | P1 | M | Public | Store reported/estimated/manual luminance anchors and label calculated nits with provenance, not measurement. | FD-025 |
| FD-047 | SD-14, TR-10 | P1 | M | Public | Export reproducible display reports with logical/backing/link distinctions, units and unknown fields. | FD-014, FD-025 |
| FD-048 | SD-15, FB-20, TR-46 | P1 | M | Public | Add selected-display EDID GUI read/export, complete-block validation and DisplayID/tile decoding. | FD-013 |
| FD-049 | SD-16, SO-28, TA-06, TB-08, TR-16, FA-26 | P1 | L | Mixed | Bind actual CoreAudio name/UID identities and separate native audio association, key engagement, target and fallback. | FD-029, FD-030 |
| FD-050 | SD-17, IN-11, TA-08, TR-18 | P1 | L | Public | Run explicitly targeted predefined actions via structured process/URL/notification adapters with honest cancellation. | FD-066 |
| FD-051 | SD-18, TR-19, FA-45, FB-34, TB-31, AM-44, IN-28 | P1 | L | Public | Add paired LG control on a shared network-controller foundation and independently qualified Wake-on-LAN. | FD-066 |
| FD-052 | SD-19, FB-35, TB-31, AM-44, IN-28 | P1 | L | Public | Add a paired Samsung remote with relative-volume capabilities and honest reconnect/input outcomes. | FD-051 |
| FD-053 | SD-21 | P1 | M | Public | Restore owned software appearance safely on disable, failure, exit and topology changes. | FD-017 |
| FD-054 | SO-11, FA-10 | P1 | L | Public | Add versioned settings export/import/reset with replacement preview, validation, remapping and restart semantics. | FD-014 |
| FD-055 | SO-12, FA-16 | P1 | M | Public | Separate notification intent from OS permission and expose styles and protection-only filters. | — |
| FD-056 | SO-13, FB-15, FA-15 | P1 | M | Public | Implement Dock/window visibility policies without tying presentation lifetime to Settings. | FD-009 |
| FD-057 | SO-15 | P1 | L | Public | Prepare FreeDisplay-owned signed update metadata/feed and retain the local-build guard until release validation. | FD-027, FD-041 |
| FD-058 | SO-17, IN-09, FA-21, TB-35 | P1 | L | Public | Make authenticated integration app-owned and explicitly opt-in, with stable credentials/port and loopback default. | FD-066, FD-023, FD-019 |
| FD-059 | SO-18 | P1 | S | Public | Expose available App Intents and open Shortcuts from Settings with accurate target/capability guidance. | — |
| FD-060 | SO-25, SO-26, FA-19, FA-20, TA-06 | P1 | M | Public | Separate brightness/audio listening, permissions, modifiers, F14/F15, mute passthrough and release feedback. | FD-029, FD-035 |
| FD-061 | SO-27, FA-19 | P1 | M | Public | Resolve pointer/focus/all target sets with eligibility, relationship deduplication and no unrelated fallback. | FD-002, FD-045 |
| FD-062 | SO-30 | P1 | M | Public | Add a general shortcut recorder with clear/cancel, conflict detection and registration status. | FD-018 |
| FD-063 | SO-31, SO-38 | P1 | M | Public | Add public software/CoreAudio and app menu/console/quit/restart actions through shared bindings. | FD-062, FD-039, FD-049, FD-040 |
| FD-064 | SO-35, IN-16, TR-17 | P1 | L | Public | Extend app-drawn OSD placement, values, interaction and receiver handshake while avoiding duplicate feedback. | FD-020, FD-035 |
| FD-065 | SO-40, FA-17 | P1 | S | Public | Unify fork identity, copyable build metadata, attribution and GPL/privacy/source/release links. | — |
| FD-066 | IN-06, FA-22, TB-36, TA-08, FA-44 | P1 | L | Mixed | Share typed selectors, capabilities, units, method choice and outcomes across CLI/URL/HTTP, including hardware-only requests. | FD-022, FD-023, FD-014 |
| FD-067 | IN-07, IN-08, TB-05, TB-06, FB-14, FA-18 | P1 | L | Mixed | Expose stable display entities and mode/main/ICC/read/brightness actions with shared validation and settlement. | FD-066, FD-012, FD-008 |
| FD-068 | IN-12, TR-18 | P1 | M | Public | Add opt-in bounded polling/feed parsing for integration controls with freshness, cancellation and visible failures. | FD-050 |
| FD-069 | IN-13, FA-43, TA-07, SD-17 | P1 | M | Public | Persist initially inactive per-display connection/sleep/wake hooks with phase, readiness and deduplication semantics. | FD-050, FD-002 |
| FD-070 | IN-15 | P1 | M | Public | Unify redacted bounded diagnostics and explicit stdout/stderr logging without corrupting machine output. | FD-022 |
| FD-071 | IN-18, FB-10, TA-04, FA-17, FA-23, TR-20 | P1 | M | Public | Add original capability-based help, verification/undo, privacy/deployment guidance and release-check documentation. | FD-047, FD-065 |
| FD-072 | FA-09 | P1 | M | Mixed | Add app-wide Shift safe startup that suppresses restoration, automatic controls and virtual reconnection. | — |
| FD-073 | FB-12, AM-42 | P1 | M | Public | Make display-sleep assertion policy, ownership and topology cleanup explicit without promising system/lid sleep control. | FD-002 |
| FD-074 | FB-16, TA-09 | P1 | S | Public | Document independent recorder/share source, permissions and output checks without claiming a video server. | FD-071, FD-009 |
| FD-075 | TB-33, FA-38 | P1 | M | Mixed | Extend Clock Mode to explicit per-display values/routes with timezone/resume semantics and manual Restore. | FD-066, FD-038 |
| FD-076 | TB-34 | P1 | S | Public | Document six explicit Shortcuts/Stream Deck actions with return paths and separate permission checks. | FD-067, FD-089, FD-059 |
| FD-077 | SO-20, FA-13 | P1 | M | Public | Expose portable menu appearance, expansion retention, auto-tidy, labels and motion preferences. | FD-032 |
| FD-078 | IN-10 | P1 | M | Public | Add a FreeDisplay-specific bounded DNC request/response/readiness protocol with correlation and timeouts. | FD-066 |

### P2 — 62 clusters

| ID | Source IDs | Priority | Effort | API risk | Description | Dependencies |
|---|---|---|---|---|---|---|
| FD-079 | AM-21, SO-21 | P2 | M | Public | Implement true movable detach/reattach with independent opacity and edit commit/cancel. | — |
| FD-080 | AM-22, SD-22, TR-38, FB-36, TA-17 | P2 | L | Mixed | Add selective auto-disconnect, exceptions, manual suspension and explicit startup/wake/quit ownership. | FD-002, FD-001, FD-016, FD-072 |
| FD-081 | AM-23, TR-24, FB-21, TA-20, TB-21 | P2 | L | Private | Inspect/select complete Apple-silicon link encoding/chroma/range/depth tuples with actual/preferred separation. | FD-025, FD-047 |
| FD-082 | AM-24, TR-40, FB-21, TA-21 | P2 | L | Private | Inspect nominal/current/VRR connection timing and select only supported rates with recovery. | FD-081, FD-034 |
| FD-083 | AM-25, FA-34, TB-24 | P2 | L | Public | Persist arbitrary source-to-receiver mirroring with precise receiver removal and conflict recovery. | FD-011, FD-002 |
| FD-084 | AM-26, TR-29, FA-34, FB-44, TA-27, TB-25 | P2 | L | Public | Add target-selected fullscreen streams with ownership arbitration, main/mode restoration and stop-all recovery. | FD-009, FD-002 |
| FD-085 | AM-27, FA-36, FB-43, TA-26, TA-29, TB-28, IN-22, SO-34 | P2 | L | Public | Persist multiple independent PiP/region configurations, arbitrary crops, geometry, locks and output placement. | FD-009 |
| FD-086 | AM-28, TR-32, FA-37, TB-22 | P2 | M | Public | Compose per-output effects, blending, quantization/grayscale and ordered LUTs with independent reset. | FD-112, FD-009 |
| FD-087 | AM-29, SO-32 | P2 | M | Private | Gate physical rotation by real device capability and expose safe mode/main/favorite/rotation bindings. | FD-028, FD-062 |
| FD-088 | AM-30, SD-23, TR-26, FA-24, FB-32, TA-23, TA-24 | P2 | L | Private | Configure predefined DDC codes/ranges, write-only support, queue/timing policies and opt-in capability discovery. | FD-006, FD-026, FD-015, FD-031 |
| FD-089 | AM-30, FA-25, TB-07, SO-36, FB-32, IN-19 | P2 | L | Private | Add stable controller-scoped input destinations, validated alternate transports and configurable key/Intent actions. | FD-088, FD-062, FD-066 |
| FD-090 | AM-31, TR-32, TA-32 | P2 | L | Mixed | Implement persistent color-managed whole-display effects with explicit compositor/gamma scope and reversible ownership. | FD-039, FD-053, FD-112 |
| FD-091 | AM-32, SD-37, TR-23, FB-30, TB-18 | P2 | L | Private | Add qualified Apple presets/direct built-in XDR with exclusive methods and saved preset/auto-brightness restoration. | FD-025, FD-053 |
| FD-092 | AM-33, FA-31, TR-37, FB-23, TA-22, TB-11, IN-24 | P2 | L | Mixed | Protect individual supported properties with captured targets, precedence and bounded restores; defer unavailable private fields. | FD-022, FD-028, FD-072 |
| FD-093 | AM-34, SD-40, FB-19, IN-25 | P2 | L | Private | Apply/unapply temporary EDID with exact identity, factory fallback and explicit recovery. | FD-048, FD-002, FD-072 |
| FD-094 | AM-35, SD-31, TR-27, FA-33, FB-38, TA-14, TB-23, SO-33, IN-23 | P2 | L | Private | Persist stable virtual definitions separately from runtime handles and connect/disconnect/delete intent. | FD-002, FD-072 |
| FD-095 | AM-35, SD-34, TR-28, FA-33, FB-39, TA-13, TB-24, IN-23 | P2 | L | Mixed | Separate virtual connection and presentation associations, orientation following and KVM continuity. | FD-094, FD-083, FD-084 |
| FD-096 | SD-32, FB-40, TA-15, IN-23 | P2 | L | Private | Add preset/custom virtual geometry, generated mode/rate lists and qualified HiDPI/HDR metadata. | FD-094, FD-033 |
| FD-097 | SD-33, SO-33, TA-15 | P2 | M | Private | Add explicit virtual bulk, sleep/lock and reconnect policies while retaining definitions and recovery. | FD-094, FD-002 |
| FD-098 | AM-36, SO-06, TR-35, FA-30, TB-12, IN-24 | P2 | L | Public | Support overlapping group membership, activation reasons, priority/exclusivity and distinct feature participants. | FD-038, FD-014 |
| FD-099 | AM-36, SO-08, TR-37, FA-30, TB-12 | P2 | L | Public | Add relative anchors/orientation rules and group-main precedence alongside snapshot recovery. | FD-098, FD-037, FD-092 |
| FD-100 | AM-36, SO-09, TR-36, TB-16, IN-24 | P2 | L | Public | Match physical UI size using existing modes, tolerance, watched/affected sets and conflict/protection exclusions. | FD-098, FD-033 |
| FD-101 | AM-26, AM-37, FB-54 | P2 | L | Private | Investigate compositor self-stream and movable filter windows as a separate backend with recursion/latency limits. | FD-090 |
| FD-102 | AM-38, TA-26 | P2 | M | Public | Add a version-gated native content picker, saved multi-window selections and conservative source recovery. | FD-009, FD-085 |
| FD-103 | AM-39, TR-33, FA-42, SO-37, TA-32 | P2 | L | Private | Control supported Night Shift/True Tone/system appearance and restore prior state after HDR/calibration. | FD-053, FD-025 |
| FD-104 | AM-40, SD-35, TR-21, FB-24, TB-20, IN-27 | P2 | L | Mixed | Compose hardware and software brightness with calibrated bounds, hardware floors and a clear neutral interval. | FD-006, FD-004, FD-017 |
| FD-105 | AM-41, SO-32 | P2 | M | Public | Add five exact favorite slots, alignment/main shortcuts and last-mode recovery through shared bindings. | FD-012, FD-062, FD-037 |
| FD-106 | AM-43 | P2 | M | Public | Preview and transactionally swap indistinguishable display assignments without losing settings. | FD-044, FD-054 |
| FD-107 | SD-24, FA-28, TA-25 | P2 | M | Private | Implement independent atomic mute/unmute ordering, volume curves and zero-volume policies with partial-failure recovery. | FD-030, FD-088 |
| FD-108 | SD-25 | P2 | L | Mixed | Make controller capability/ownership explicit and isolate Apple native brightness/HDR policies. | FD-006, FD-049 |
| FD-109 | SD-26, AM-46, TR-47, TB-30, IN-26 | P2 | L | Private | Add qualified HDMI-CEC addressing, relative controls, inputs and separate automatic/direct power semantics. | FD-108, FD-002 |
| FD-110 | SD-27, TB-29 | P2 | L | Private | Detect DisplayLink paths and isolate version-qualified manager brightness/contrast control and manual assignment. | FD-108, FD-002 |
| FD-111 | SD-28, IN-20, FA-25 | P2 | M | Mixed | Persist reusable typed custom controls with menu assignments, validated mappings and readback. | FD-108, FD-050, FD-068 |
| FD-112 | SD-29, TR-31, TA-31 | P2 | M | Public | Manage persistent SDR LUTs, metadata, original export, ordering and shared assignment/edit/delete effects. | — |
| FD-113 | SD-30, FB-41, TA-35 | P2 | L | Mixed | Qualify HDR virtual/capture/LUT pipelines with precision, transfer/color metadata and macOS-version gates. | FD-096, FD-084, FD-112 |
| FD-114 | SD-36, TR-22, FB-29, TB-17, IN-27 | P2 | L | Mixed | Qualify software XDR/external HDR upscaling, calibration, neutral boundaries and readiness without direct-mode claims. | FD-104, FD-127, FD-053 |
| FD-115 | SD-38 | P2 | M | Mixed | Add reversible lock dimming and non-main backlight-off ownership without hiding the recovery screen. | FD-002, FD-053 |
| FD-116 | SD-39, TR-39, FB-17, TA-10, TA-11 | P2 | L | Privileged/private | Stage model-wide role/name/native/default/custom-mode overrides with scoped authorized Apply/Undo and activation. | FD-048, FD-054, FD-072 |
| FD-117 | SD-39, FB-18, TA-11 | P2 | L | Privileged/private | Generate bounded flexible HiDPI ranges with explicit requested-versus-offered modes and unsupported-path exclusions. | FD-116, FD-033 |
| FD-118 | SO-07, TR-35, FA-27, TB-15, TA-18 | P2 | L | Mixed | Add typed directional control sync, source/receiver filters, external-only rules and origin/echo precedence. | FD-038, FD-098, FD-108 |
| FD-119 | SO-07, FB-27, TB-13, TA-19, IN-27 | P2 | L | Mixed | Match estimated luminance across qualified controller ranges with saturation and explicit provenance. | FD-046, FD-118, FD-104 |
| FD-120 | IN-21, SO-33 | P2 | L | Private | Expose only qualified lifecycle/power/rotation/HDR/virtual action adapters through shared automation and recovery. | FD-066, FD-002 |
| FD-121 | IN-26, TR-44 | P2 | L | Private | Expose capability-gated read-only DPCD/DSC/CEC/Apple brightness/link diagnostics with unknown-state handling. | FD-047 |
| FD-122 | TR-34, AM-50 | P2 | M | Private | Report ambient readings with sensor provenance/aggregation rather than equating them to observed brightness. | FD-047 |
| FD-123 | FB-25, TB-10, SD-23 | P2 | L | Mixed | Keep desired versus observed state separate for startup/wake replay, bounded delays and user-intent cancellation. | FD-088, FD-053, FD-069 |
| FD-124 | FA-41, FB-26, SD-25 | P2 | M | Private | Manage native auto-brightness explicitly and separate OS state from group source/receiver roles. | FD-108, FD-118 |
| FD-125 | FA-40, TB-22 | P2 | M | Private | Gate framebuffer grayscale/standard appearance independently from preview effects and reset each scope. | — |
| FD-126 | TR-25, FB-31, TB-21 | P2 | L | Private | Read/control supported GPU dithering and uniformity per active port without claiming panel FRC is disabled. | FD-081 |
| FD-127 | FB-22, TR-22, FA-39 | P2 | L | Private | Expose qualified HDR status/encoding and optional forced HDR with complete known-working tuple restoration. | FD-081, FD-025, FD-002 |
| FD-128 | FA-32, FB-37, TA-12, TB-37, SD-44, SO-39, AM-34 | P2 | L | Private | Qualify manual external framebuffer reinitialization before default-off wake/unlock automation and factory fallback. | FD-093, FD-002 |
| FD-129 | FB-45, TA-27, SO-34, FA-35 | P2 | M | Public | Separate pause, hide, stop and automatic restart with scoped all-presentation actions and no late resurrection. | FD-084, FD-085 |
| FD-130 | FB-46, TA-30, TR-30, TR-29 | P2 | M | Public | Expose target/delivered FPS, sampling and actual pixel ratios without hidden downscaling or integer-scale claims. | FD-084, FD-085 |
| FD-131 | TA-28, FA-35, TR-30 | P2 | M | Public | Add vertical flip, fit/zoom/underscan/alignment and inverse source-coordinate pointer mapping with safe return. | FD-084, FD-085 |
| FD-132 | FB-47 | P2 | M | Public | Expose per-output capture exclusion with driver-qualified behavior and no external-recorder guarantee. | FD-085, FD-110 |
| FD-133 | FB-48, TA-33 | P2 | L | Mixed | Add opt-in session-lock/Spaces presentation and cursor exclusion with recoverable reconnect sets. | FD-129, FD-097 |
| FD-134 | FB-28, FA-38 | P2 | M | Mixed | Expose idempotent effect activation/suspension/LUT/preset actions with explicit owned-state restoration. | FD-067, FD-090 |
| FD-135 | FB-33 | P2 | M | Private | Add managed hardware-contrast actions distinct from raw VCP writes and software contrast. | FD-066, FD-088 |
| FD-136 | FA-29, TB-32 | P2 | L | Private | Build explicit laptop/desk connection recipes with connect-before-off, readiness cancellation and per-step outcomes. | FD-080, FD-120 |
| FD-137 | TB-26 | P2 | M | Mixed | Compose matched portrait geometry and transformed output with correct pointer mapping over OS-owned Sidecar. | FD-095, FD-131 |
| FD-138 | TB-27 | P2 | M | Mixed | Present into an intact destination rectangle with black remainder, exact geometry and recovery-first main switching. | FD-096, FD-131 |
| FD-139 | SD-41, FB-35, AM-44, IN-28 | P2 | L | Public | Add paired Philips remote control with model-specific keys and source-navigation limits. | FD-051 |
| FD-140 | SO-37, FA-47 | P2 | L | Private | Gate Apple keyboard illumination actions on actual supported hardware and restore behavior. | FD-062 |

### P3 — 22 clusters

| ID | Source IDs | Priority | Effort | API risk | Description | Dependencies |
|---|---|---|---|---|---|---|
| FD-141 | AM-45 | P3 | L | Privileged/private | Consider separately authorized protected/factory ICC cleanup with backups and targeted recovery. | FD-036, FD-054 |
| FD-142 | SD-42, AM-44, IN-28 | P3 | L | Public | Add Yamaha zone-aware input/volume/power control with explicit device and zone ownership. | FD-051 |
| FD-143 | AM-47, FB-52 | P3 | M | Public | Gate model-specific TV service commands behind a ready paired target and explicit expert access. | FD-051 |
| FD-144 | AM-48, SD-44, SO-39, FA-46, IN-30 | P3 | L | Private | Detect and qualify VMM7100 adapter reset separately from framebuffer reinitialization. | FD-002, FD-121 |
| FD-145 | AM-49 | P3 | M | Mixed | Offer cosmetic corner overlays and a capability-gated notch-mode toggle without claiming changed panel geometry. | FD-033 |
| FD-146 | AM-50, FA-50 | P3 | L | Private | Investigate force-attempt native underscan only on qualified hardware with recoverable prior settings. | FD-002 |
| FD-147 | SD-43 | P3 | L | Private | Version explicit Monduo/SOTSU/FlipGo adaptations and retain per-model compatibility evidence. | FD-108 |
| FD-148 | SD-45, TR-43, FA-50 | P3 | L | Privileged/private | Separate system display reset from optional NVRAM reset with explicit scope, backups and recovery. | FD-054, FD-002 |
| FD-149 | SD-46, TR-43, FB-51 | P3 | L | Private | Defer physical EDID-memory writing to a separately guarded expert tool with exact backup and durability checks. | FD-048 |
| FD-150 | SO-16, FA-48 | P3 | M | Public | Add opt-in prerelease/internal channels and validate skip/critical/informational update offers. | FD-057 |
| FD-151 | SO-22 | P3 | L | Mixed | Investigate newer-OS Sidebar presentation only where supported while retaining the macOS 14 layout. | FD-077 |
| FD-152 | IN-29 | P3 | M | Public | Add optional auto-warp/return, pointer halo and resize increments with drag suppression and exclusions. | FD-131 |
| FD-153 | IN-30 | P3 | L | Private | Investigate separate opt-ins for Sidecar, arbitrary framebuffer and remote-key extensions without blanket support. | FD-120 |
| FD-154 | IN-31 | P3 | M | Public | Consider advanced presentation/RTL localization and typed settings CLI access without editing live files. | FD-066, FD-077, FD-054 |
| FD-155 | TR-41 | P3 | M | Private | Implement real optional DDC SCS persistence only after device qualification, never a no-op preference. | FD-088 |
| FD-156 | TR-42, FB-50 | P3 | M | Mixed | Provide model-specific PBP/tiled/KVM diagnostics without claiming virtual crops create hardware inputs or synchronized tiles. | FD-047, FD-089 |
| FD-157 | FB-49 | P3 | L | Private | Defer expert CRT timing selection and 1:1 placement until general connection controls are qualified. | FD-082, FD-131 |
| FD-158 | FB-53 | P3 | M | Public | Document portrait/remote-client coordinate diagnostics with exact geometry and a recoverable known-good layout. | FD-047, FD-131 |
| FD-159 | TA-34 | P3 | L | Privileged/private | Retain only a deferred Intel EDID migration design outside the current Apple-silicon implementation scope. | FD-116 |
| FD-160 | TA-36 | P3 | M | Public | Add conditional selected-window title/background/source-shadow controls with explicit restart semantics. | FD-102, FD-085 |
| FD-161 | TB-19 | P3 | L | Private | Assess legacy native XDR only for eligible older systems and omit controls on unsupported versions. | FD-091 |
| FD-162 | TB-38 | P3 | M | Public | Keep an optional external MQTT bridge separate from core BetterDisplay parity and dependent on authenticated REST. | FD-058 |

## 4. Recommended P1 implementation waves

Resolve the applicable P0 prerequisites before enabling the corresponding P1 feature. These six waves cover **all 47 P1 clusters**, with **5–10 clusters per wave**. Prioritize usable public-API paths; where a cluster is Mixed, first accept the public policy/software/CoreAudio path and qualify existing private hardware adapters separately. Do not add new private transports to claim completion of a public-only wave.

### Wave 1 — Everyday display controls (10 clusters)

**Clusters:** FD-033, FD-035, FD-037, FD-036, FD-039, FD-053, FD-045, FD-032, FD-077, FD-038.

Improve the controls users touch daily: legible modes, predictable brightness, arrangement, profiles and a configurable menu. Use public software brightness for initial sync acceptance; existing native/DDC routes remain separately qualified.

### Wave 2 — Keyboard, audio and feedback (8 clusters)

**Clusters:** FD-049, FD-060, FD-061, FD-062, FD-064, FD-055, FD-056, FD-059.

Make brightness/volume keys reliable and targeted, expose shortcut failures, and keep visible feedback and recovery windows available. Public CoreAudio/software sinks provide the initial acceptance paths.

### Wave 3 — Identity, diagnostics and recovery (8 clusters)

**Clusters:** FD-043, FD-044, FD-047, FD-048, FD-054, FD-072, FD-034, FD-046.

Make reconnect problems explainable and settings recoverable before richer automation. Build public record/report/backup policy; safe mode suppresses existing private operations rather than adding a private transport.

### Wave 4 — Shared automation and actions (9 clusters)

**Clusters:** FD-066, FD-067, FD-040, FD-050, FD-068, FD-069, FD-070, FD-063, FD-078.

One typed command/result model unlocks CLI, Shortcuts, console and event actions without divergent selection or units. Ship public mode/main/ICC/software actions first; expose existing hardware adapters only with honest capability/outcome reporting.

### Wave 5 — Durable daily automation and app management (6 clusters)

**Clusters:** FD-058, FD-075, FD-073, FD-042, FD-065, FD-071.

Make the app useful with Settings closed: durable authenticated control, explicit schedules, owned sleep assertions and understandable app configuration. Keep HTTP loopback by default; optional remote access is a separate deliberate configuration.

### Wave 6 — Distribution and narrower integrations (6 clusters)

**Clusters:** FD-041, FD-057, FD-074, FD-051, FD-052, FD-076.

Finish owned updates and original recording/control recipes, then qualify TV integrations using public networking APIs. Vendor pairing/protocol behavior still needs real-device acceptance. The complete six-action recipe is conditional on P2 input actions; it is not a public-only completion claim.

**Dependency boundaries:** FD-076's complete six-action Stream Deck recipe requires P2 FD-089; keep that recipe gated until input actions are available. FD-074 documents current recording prerequisites and limitations; persistent virtual/PiP recipes additionally require FD-094/FD-085. FD-057 needs a FreeDisplay-owned signing/feed/release process before automatic updates are enabled. LG/Samsung use public networking, but device protocol and wake behavior still require separate acceptance.

**Acceptance for each wave:** use the detailed source criteria, verify actual selected identities and settled state, and distinguish request acceptance, transport completion, readback and physical effect. Public code-path completion is not monitor or audio certification. Retain unsupported/unknown states and explicit recovery throughout.

