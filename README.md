<p align="right"><b>English</b> · <a href="README.ru.md">Русский</a></p>

<p align="center">
  <img src="Docs/images/freedisplay/icon.png" width="128" alt="FreeDisplay app icon: a glowing monitor outline with a power symbol">
</p>

<h1 align="center">FreeDisplay</h1>

<p align="center">
  <b>Free, open-source display control for Apple Silicon Macs.</b><br>
  Hardware brightness over DDC/CI, HiDPI modes, arrangement, scenes, virtual displays and automation,<br>
  all from the menu bar, with an interface in English and Russian.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="License: GPL-3.0"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon-only-555" alt="Apple Silicon only">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <a href="#interface-language"><img src="https://img.shields.io/badge/UI-English%20%7C%20%D0%A0%D1%83%D1%81%D1%81%D0%BA%D0%B8%D0%B9-0a7d8c" alt="UI: English | Русский"></a>
  <img src="https://img.shields.io/badge/releases-none%20yet-orange" alt="No releases yet">
</p>

<p align="center">
  <img src="Docs/images/freedisplay/hero-en.png" width="900" alt="FreeDisplay: the Settings window open on the Displays section (mode, colour temperature, software dimming), with the menu-bar panel in front showing the built-in display card, brightness and a resolution slider">
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#gallery">Gallery</a> ·
  <a href="#freedisplay-vs-betterdisplay">vs BetterDisplay</a> ·
  <a href="#interface-language">Language</a> ·
  <a href="#build-from-source">Build</a> ·
  <a href="#automation-examples">Automation</a> ·
  <a href="#project-structure">Structure</a> ·
  <a href="#license">License</a>
</p>

> [!NOTE]
> **Status: early, private fork, no releases.** FreeDisplay is built from source only. There are no
> signed or notarized FreeDisplay builds yet, and the app's built-in updater is switched off for this
> fork. The app bundle, the CLI and the URL scheme still carry the upstream name: **OpenDisplay.app**,
> `opendisplay`, `opendisplay://`.

## What is FreeDisplay?

FreeDisplay is a fork of [**OpenDisplay**](https://github.com/aquitaine/OpenDisplay) by aquitaine,
a free GPL-3.0 menu-bar app that controls your monitors' real hardware and keeps your display setup
safe to change. FreeDisplay builds on OpenDisplay 0.11.5 and adds:

- a redesigned **menu-bar panel** and grouped Settings window;
- **virtual displays** for the current session (experimental);
- **screen capture with a picture-in-picture preview** (experimental);
- a **local HTTP API** for scripts, bound to 127.0.0.1 and protected by a token;
- **EDID and HiDPI tools** (validate and export, never install) and an EDR headroom readout;
- a full **Russian translation** with an in-app language switch;
- fixes for Reconnect All, Black Out and display names;
- a page-by-page [study of the BetterDisplay guide](Docs/BetterDisplay-Guide/) that tracks what is
  still missing.

**Not affiliated with BetterDisplay.** FreeDisplay is an independent project. It isn't affiliated
with, endorsed by or connected to BetterDisplay or its developer. "BetterDisplay" is a trademark of
its owner. The work is clean-room: BetterDisplay's public documentation is used only as a list of
*capabilities* to compare against. FreeDisplay contains no BetterDisplay code, assets, UI or text.

## Features

How to read the **Status** column:
**Core** is always available. Where the note says *full build*, the feature needs private macOS
APIs and is left out of the [public-API-only flavour](#public-api-only-flavour).
**Experimental** is opt-in, relies on private APIs or recent work, and may break with macOS updates.
**Labs** is off by default; you turn it on in *Settings → Diagnostics → Labs*.

### Brightness & dimming

| Feature | What it does | Status |
|---|---|---|
| **Hardware brightness (DDC/CI)** | Sets the external monitor's real backlight, plus contrast, volume and mute, input source, colour preset, sharpness, RGB gain, power and factory reset. Settings are read back after a change, and if the monitor ignored it, the app tells you. The CLI can read or write any raw MCCS VCP code. | Core · full build |
| **Built-in brightness** | Controls the built-in panel through the system brightness service. | Core · full build |
| **Software dimming** | Dims any display with gamma, a black overlay or both, including displays without DDC. Each display also gets a colour-temperature slider. By design it never goes fully black. | Core |
| **Black Out** | Makes a display fully black with a click-through overlay. Offered only while another display stays lit. | Core |
| **XDR Brightness** | Pushes SDR content on a built-in XDR panel up to 2× its normal maximum using EDR headroom. Never survives quit or a crash. You can have it switch off on battery or in Low Power Mode. | Labs |
| **Adaptive & scheduled brightness** | Follows the built-in display or the ambient light sensor. *Clock Mode* schedules brightness by fixed times or by sunrise, solar noon or sunset with offsets. *Location Mode* follows the sun's elevation. There's also evening warmth that follows Night Shift, and per-app presets. | Core · full build |
| **Display groups** | One slider or brightness key moves several displays together. The group learns each display's offset from your adjustments. Contrast sync is optional. | Core |
| **FaceLight** | One press turns a display into a bright fill light for video calls. Press again to restore the previous settings. | Core |

### Resolutions & modes

| Feature | What it does | Status |
|---|---|---|
| **Mode picker** | Shows logical size, framebuffer, refresh rate and HiDPI for every mode macOS offers, with optional non-HiDPI variants and a resolution slider in the menu-bar panel. | Core |
| **Favourite modes** | Star modes and switch between them quickly. Also available as `opendisplay favorite`. | Core |
| **Keep or revert** | A new mode stays only if you confirm it. Otherwise it reverts automatically after a countdown. | Core |
| **Main display, mirroring, colour profiles** | Choose the main display, mirror the main display, and apply or reset ICC profiles through ColorSync. | Core |
| **Rotation** | Rotates through an isolated helper with automatic rollback. Unavailable on macOS versions where it can't be done safely. | Labs |

### Arrangement & scenes

| Feature | What it does | Status |
|---|---|---|
| **Drag arrangement** | Drag displays on a canvas. Changes apply immediately. | Core |
| **Protected layout** | When hotplug, sleep or another app changes your setup, puts back positions, modes, mirroring, the main display and which displays are off. Each combination of displays keeps its own layout. | Core |
| **Scenes** | Saves the arrangement and modes of all displays so you can plan or apply them later from the app or the CLI. | Core |
| **Logical disconnect** | Turns a display off without unplugging it, and always keeps at least one display active. Optionally turns the built-in panel off when an external display connects. | Experimental · full build |

### Virtual displays · Experimental

Creates virtual screens for the current session through a private macOS API. You set the name,
pixel size, refresh rate (30, 60 or 120 Hz) and HiDPI. Up to four can exist at once, and they
disappear when the app quits. Creation must be allowed first, and it is refused in Safe Mode or
when no physical display is visible for recovery. *Full build only.*

### Screen capture & picture in picture · Experimental

Shows a live ScreenCaptureKit preview of any display or window in a floating, resizable window.
The preview can be flipped horizontally, rotated, cropped or zoomed, and passed through a `.cube`
LUT. It's an SDR preview at 30 fps, scaled to at most 1920 px, and it stays in memory: nothing is
recorded to disk. macOS asks for Screen Recording permission the first time you load sources.

### EDID & HiDPI tools · export only

- Import a binary EDID and validate its header, checksum, extension count and identity. Export it
  as an Apple display-override plist.
- Plan HiDPI sizes and export a JSON plan that includes the restore steps.
- Read the current and potential EDR headroom of each display.
- Dump a connected display's EDID with `opendisplay edid <selector> --out edid.bin`.

FreeDisplay **never installs** overrides or system configuration. Applying an exported file is up
to you, and at your own risk.

### Automation

| Surface | What it does |
|---|---|
| **CLI `opendisplay`** | Covers display lists, brightness, DDC (including raw VCP), scenes, layout protection, groups, favourites, EDID, ambient light (`lux`), lid state, diagnostics and recovery. `listen` streams events as JSON lines. |
| **URL scheme** | `opendisplay://reconnect-all` runs immediately. A `disconnect` URL is recognised but never runs silently; it only brings the app forward. |
| **Shortcuts & Siri** | Actions with a display picker: *Get* and *Set Display Brightness* (0–100 %, the result says whether the display confirmed the level), *Set Display Mode* (the display's exact modes; the change is kept or reverted like one made in the menu), *Set Main Display*, plus *Reconnect All Displays*. Results are typed, so a shortcut can branch on them. *Settings → Automation* opens the Shortcuts app. |
| **Local HTTP API** | Listens only on 127.0.0.1, on a random port, with a new 256-bit bearer token each session. Endpoints: `GET /v1/displays`, `POST /v1/brightness`, `POST /v1/reconnect-all`. It runs only while *Settings → Automation* is open. |
| **Media keys & OSD** | The brightness keys control the chosen display, in hardware or software. The volume keys use DDC only when sound plays through that monitor. The on-screen HUD has several styles, and events can optionally be broadcast to external HUD apps. Needs Accessibility permission. |
| **Keyboard shortcuts** | *Settings → Keyboard* records a global shortcut for each action (Reconnect All, brightness steps, FaceLight, the menu, Settings, Quit), shows whether it is active or which shortcut it clashes with, and sets the brightness/volume step size. Input hotkeys (⌃⌥⌘-digit) switch a monitor to a chosen input, which is handy with a KVM. |
| **Notifications** | Posts a system notification when an external display connects or disconnects. |

### Safety & recovery

| Feature | What it does |
|---|---|
| **Reconnect All** | Available from the menu, a global hotkey (**⌃⌥⌘R** by default), Shortcuts, the URL scheme, HTTP and `opendisplay recover`. |
| **Transactions & audit log** | Risky changes go through checkpoints, verification and rollback. Quitting the app reconnects every display it turned off. |
| **Rescue app** | The standalone **OpenDisplay Rescue** restores the last known-safe arrangement, even when the main app can't run. |
| **Diagnostics export** | Saves one zip to your Desktop with the app's records, macOS display configuration and recent display-related log lines. It is never sent anywhere. |

If a display won't come back, see [Recovering a stranded display](Docs/Recovering-a-stranded-display.md).

## Gallery

<table>
  <tr>
    <td width="50%"><img src="Docs/images/freedisplay/arrange-en.png" alt="Arrange section: a display on the arrangement canvas and the Protected layout option"><br><sub><b>Arrange</b>: drag layout and protected layout</sub></td>
    <td width="50%"><img src="Docs/images/freedisplay/virtual-en.png" alt="Virtual Displays section: experimental opt-in toggle, name, size in pixels, refresh rate and HiDPI"><br><sub><b>Virtual displays</b> (experimental)</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="Docs/images/freedisplay/capture-en.png" alt="Screen Capture section: source picker, Start PIP, flip, rotation, crop and zoom, LUT loading"><br><sub><b>Screen capture & PiP</b> (experimental)</sub></td>
    <td width="50%"><img src="Docs/images/freedisplay/advanced-en.png" alt="EDID and HiDPI section: HDR capabilities, export-only EDID tools and HiDPI mode planning"><br><sub><b>EDID & HiDPI</b>: export-only tools</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="Docs/images/freedisplay/automation-en.png" alt="Automation section: local HTTP control with Start Local Server, Stop and Copy Session Token buttons and the three endpoints"><br><sub><b>Automation</b>: local HTTP control</sub></td>
    <td width="50%"><img src="Docs/images/freedisplay/about-en.png" alt="About section: version 0.11.5, local build note, upstream links, licence and the Interface language picker"><br><sub><b>About</b>: local build and interface language</sub></td>
  </tr>
</table>

## FreeDisplay vs BetterDisplay

BetterDisplay is a mature commercial app with a free tier and a paid Pro tier. FreeDisplay is
**not** a drop-in replacement. It covers the everyday core, and several large areas are still
missing. The full, page-by-page study of the official guide, with code evidence and a prioritised
backlog for every topic, lives in **[Docs/BetterDisplay-Guide/](Docs/BetterDisplay-Guide/)**:
all 501 guide pages are covered, giving 392 backlog items (58 of them P0 fixes).

| Area | FreeDisplay today |
|---|---|
| DDC/CI hardware controls (Apple Silicon) | ✔ Brightness, contrast, volume, input, presets, RGB gain, power, raw VCP |
| Software dimming, colour temperature, media keys, OSD | ✔ |
| Resolution and refresh picker, favourites, keep/revert | ✔ Only modes macOS already offers |
| Layout protection, scenes, display groups | ✔ Groups sync brightness and contrast only |
| **Flexible HiDPI scaling and custom resolutions** | ✘ The HiDPI planner exports a plan; it installs nothing |
| **XDR / HDR extra brightness** | Partial: built-in XDR panel only (Labs); no third-party HDR displays, no nits calibration |
| **Streaming, PiP on another screen, video-filter windows, display-wide LUTs** | Partial: one floating SDR preview window |
| **Network TV and AV-receiver control** (LG webOS, Samsung, Philips, Yamaha) | ✘ |
| **HDMI-CEC, DisplayLink** | ✘ |
| **EDID override installation** | ✘ Validate and export only |
| Virtual screens | Partial: session-only, basic settings, no associations, no HDR |
| Automation breadth | Partial: CLI, 5 Shortcuts actions, 3 HTTP endpoints, 1 URL command; no console or per-display event hooks |
| Intel Macs | ✘ Apple Silicon only |

Where FreeDisplay takes a different path:

- **Free and open source (GPL-3.0).** No licence key, no trial, no paid tier, and every line can be
  inspected.
- **Safety model.** Risky changes are transactions with verification and automatic rollback.
  Reconnect All is always one hotkey away, and a standalone rescue app is included.
- **Honest results.** When a monitor ignores a DDC write, the UI says so instead of showing a value
  the monitor isn't at.

*The comparison reflects the public BetterDisplay guide as studied in October 2026. If something
here is wrong or out of date, please open an issue.*

## Interface language

<p align="center">
  <img src="Docs/images/freedisplay/bilingual.png" width="900" alt="The same EDID and HiDPI settings section shown side by side in English and in Russian">
</p>

- By default the interface **follows your macOS language**. macOS picks the first language in your
  preferred list that the app supports (English or Russian) and falls back to English if neither
  is there. You can also set a per-app language in *System Settings → General → Language & Region →
  Applications*.
- To pin a language inside the app, open *Settings → About → Language → Interface language* and
  choose **System**, **English** or **Русский**. Click **Relaunch** to apply.
- The strings live in Xcode String Catalogs (`Apps/OpenDisplay/Resources/*.xcstrings`), with
  English as the source language. CLI output and JSON/HTTP field names stay in English, so scripts
  never depend on the UI language.

## Build from source

**Requirements:** an Apple Silicon Mac. Running the app needs macOS 14 or later; building needs
**Xcode 26** (tested with 26.6, Swift 6) and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
git clone https://github.com/garshany/FreeDisplay.git
cd FreeDisplay
make xcode                      # runs `xcodegen generate` (installs XcodeGen via Homebrew if missing)

xcodebuild -project OpenDisplay.xcodeproj -scheme OpenDisplay -configuration Debug \
  DEVELOPMENT_TEAM=<YOUR_TEAM_ID> CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual \
  build
```

- `OpenDisplay.xcodeproj` is generated and isn't committed. Re-run `make xcode` whenever
  `project.yml` changes.
- `project.yml` signs the app with the upstream Developer ID team, so pass your own team as shown
  above. A stable signature matters: macOS ties the Accessibility permission (needed for the media
  keys) to it.
- Other schemes: `OpenDisplayRescue` (rescue app), `opendisplay` (CLI) and
  `OpenDisplay-PublicAPIOnly`. `make bundle-helper` copies the CLI into
  `OpenDisplay.app/Contents/Helpers`, where the Labs rotation helper expects it. It builds with the
  signing settings from `project.yml`.
- The app lives in the menu bar and has no Dock icon. ⌥-click the menu-bar icon to open Settings.

### Tests

```sh
make test        # swift test --parallel
```

This runs the platform-independent core (`DisplayDomain`, `SceneEngine`, `AutomationSchema`,
`TopologyCore`): **727+ unit and state-machine tests**. The core is meant to build on Linux too
(`make bootstrap` installs a Swift 6 toolchain there). There's no remote CI; the local test run
is the gate.

### Public-API-only flavour

`OpenDisplay-PublicAPIOnly` builds the same sources with `PUBLIC_API_ONLY` defined and without the
private-API providers. That removes DDC, built-in brightness, logical disconnect, rotation,
ambient-light and Night Shift readings, Clock Mode and virtual displays. Modes, arrangement,
scenes, software dimming, colour profiles, capture and the EDID tools remain. Use it to audit the
app or where private APIs aren't acceptable.

### Releases and updates

There are **no FreeDisplay releases yet**. The Info.plist key `OpenDisplayLocalBuild` turns off the
Sparkle updater, so a FreeDisplay build never replaces itself with an upstream OpenDisplay release.
*About* shows "Local build · updates from source". To update, pull the latest changes and rebuild.
The upstream Homebrew cask and upstream releases install **OpenDisplay**, not FreeDisplay.

## Automation examples

<details>
<summary><b>CLI usage</b> (<code>opendisplay help</code>)</summary>

```text
opendisplay — OpenDisplay automation CLI

USAGE:
  opendisplay list [--json]
  opendisplay diagnose [--json]
  opendisplay diagnose --bundle [directory]   # diagnostics zip for a bug report (default: Desktop)
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
  opendisplay brightness <selector> [0..1]
  opendisplay ddc <selector> <brightness|contrast|volume|input|colour|sharpness|red|green|blue|mute|power|caps> [value]
  opendisplay ddc <selector> reset                # restore the monitor's factory defaults (VCP 0x04)
  opendisplay ddc <selector> vcp <0xNN> [value]   # any raw MCCS feature code
  opendisplay edid <selector> [--out <path.bin>]
  opendisplay favorite <list|set|unset> <selector> [WxH[@Hz][@2x]]

SELECTORS: id:<recordID> · alias:<name> · tag:<tag> · group:<name> · main · builtin · state:<active|managedOffline> · <cgDisplayID>
```

</details>

```sh
opendisplay list                          # displays, IDs and states
opendisplay alias 3 desk                  # name display 3 (CG display ID) "desk"
opendisplay brightness alias:desk 0.6     # 0…1, over DDC (or the built-in panel's own brightness)
opendisplay ddc alias:desk contrast 70    # raw DDC value
opendisplay ddc alias:desk vcp 0x60       # read any MCCS feature (here: input source)
opendisplay scene save Work               # later: opendisplay scene apply Work
opendisplay listen                        # JSON events, one per line, until Ctrl-C
```

**Local HTTP API.** Open *Settings → Automation*, click **Start Local Server**, note the port it
shows, then click **Copy Session Token**:

```sh
PORT=<port from the panel>
TOKEN="$(pbpaste)"
curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/v1/displays"
# {"displays":[{"active":true,"brightness":0.8,"id":"…","name":"…"}]}

curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"displayId":"<id from /v1/displays>","value":0.5}' \
     "http://127.0.0.1:$PORT/v1/brightness"
```

A brightness response reports that the change was *requested*; it doesn't claim a verified
hardware result. See [Docs/Local-HTTP-Control.md](Docs/Local-HTTP-Control.md) for the full
contract and threat model.

**URL scheme:**

```sh
open "opendisplay://reconnect-all"
```

## Project structure

| Path | Contents |
|---|---|
| `Apps/OpenDisplay` | Menu-bar app and Settings window (SwiftUI + AppKit), String Catalogs |
| `Apps/OpenDisplayRescue` | Standalone rescue app that restores the last known-safe arrangement |
| `Packages/` | Platform-independent core, also built and tested by SwiftPM: `DisplayDomain`, `ProviderInterfaces`, `SceneEngine`, `AutomationSchema`, `TopologyCore`, `SimulatorProvider`. Plus the macOS-only `OpenDisplayDesignSystem` UI kit |
| `Providers/` | macOS back ends: `CoreGraphicsProvider` (public API), `ExperimentalLifecycleProvider` (DDC, disconnect, rotation, built-in brightness; private API), `VirtualDisplayProvider`, `CaptureProvider` |
| `Tools/opendisplay` | Automation CLI |
| `Docs/` | Architecture, recovery model, RFCs, HTTP API, EDID tools, [BetterDisplay guide study](Docs/BetterDisplay-Guide/) |
| `Tests/` | Integration harness (local HTTP loopback) and hardware-lab notes |
| `project.yml`, `Package.swift`, `Makefile` | XcodeGen spec, SwiftPM manifest, developer entry points |

<details>
<summary><b>More documentation</b></summary>

- [Architecture overview](Docs/Architecture/overview.md) · [Architecture decisions](Docs/Architecture/decisions.md)
- [Recovery model](Docs/Recovery/recovery.md) · [Recovering a stranded display](Docs/Recovering-a-stranded-display.md)
- [Local HTTP control](Docs/Local-HTTP-Control.md) · [Advanced display tools (EDID/HiDPI)](Docs/ADVANCED-DISPLAY-TOOLS.md)
- RFCs: [capture preview](Docs/RFCs/0010-opt-in-capture-preview.md) · [session virtual displays](Docs/RFCs/0042-session-virtual-displays.md)
- [Product requirements](Docs/PRD.md) · [Upstream changelog](CHANGELOG.md) (OpenDisplay history up to 0.11.5)

</details>

## Contributing

Issues and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) (inherited
from upstream) first. Its two key rules:

- **Clean-room only.** No decompiled or reverse-engineered proprietary code, and no copied UI,
  icons, screenshots or text from other display apps.
- **Sign off** every commit (`git commit -s`, DCO).

For this fork, also run `make test` before sending a change, and check UI changes in both English
and Russian. New user-visible strings need a Russian translation in the String Catalog.

## Security

- The full build uses **private macOS APIs**: SkyLight for logical disconnect, IOAVService for DDC,
  DisplayServices for built-in brightness and CGVirtualDisplay for virtual screens. They are
  undocumented and can change with any macOS update. Experimental and Labs features are opt-in and
  reversible, and the [public-API-only flavour](#public-api-only-flavour) leaves them out entirely.
- The local HTTP server listens only on loopback, requires a per-session bearer token, rejects
  browser `Origin` requests and stops when you leave the Automation section. Any local process
  that obtains the token can change brightness or reconnect displays.
- Permissions are requested only when you use the feature that needs them: Accessibility for the
  media keys, Screen Recording for capture, Notifications for connect alerts.
- Please report vulnerabilities **privately**. Use GitHub's private vulnerability reporting on
  this repository if it's enabled, or contact the maintainer
  [@garshany](https://github.com/garshany). Don't open a public issue. See also
  [SECURITY.md](SECURITY.md) (inherited from upstream).

## License

FreeDisplay is licensed under the **GNU General Public License v3.0**, like upstream OpenDisplay
(GPL-3.0-or-later; see [LICENSE](LICENSE)). The copyright of the original OpenDisplay code stays
with its authors; FreeDisplay's changes are released under the same licence. If you distribute a
modified build, the GPL requires you to provide the corresponding source.

## Acknowledgements

- [**OpenDisplay**](https://github.com/aquitaine/OpenDisplay) by aquitaine and contributors: the
  foundation of this project, including the DDC engine, the safety model, the rescue app and the
  CLI.
- [Sparkle](https://sparkle-project.org) (linked by the app, disabled in this fork) and
  [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- The public-domain NOAA solar equations behind Clock Mode and Location Mode.
- The authors of BetterDisplay, MonitorControl and Lunar, for showing what display control on
  macOS can be. FreeDisplay is independent of all of them.
