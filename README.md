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
  <img src="Docs/images/freedisplay/hero-en.png" width="900" alt="FreeDisplay: the Settings window open on the Displays section (mode picker with aspect, refresh and density filters, colour temperature, software contrast and image adjustments), with the menu-bar panel in front showing the built-in display card, brightness and a resolution slider">
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
> fork. The app is **FreeDisplay.app**. The CLI and URL scheme retain their compatible names:
> `opendisplay`, `opendisplay://`.

## What is FreeDisplay?

FreeDisplay is a fork of [**OpenDisplay**](https://github.com/aquitaine/OpenDisplay) by aquitaine,
a free GPL-3.0 menu-bar app that controls your monitors' real hardware and keeps your display setup
safe to change. FreeDisplay builds on OpenDisplay 0.11.5 and adds:

- a redesigned **menu-bar panel** you can arrange (which displays and controls it shows, in what
  order, with which icons) and a grouped Settings window;
- a **free-drag arrangement canvas** with snapping, in Settings and in the menu-bar panel;
- **software contrast** next to dimming and colour temperature, and a **Default display group**
  with absolute or delta brightness sync;
- an in-app **EDID reader and decoder** (CTA-861, DisplayID), per-display information reports and
  a complete, filterable mode list; EDID and HiDPI files are validated and exported, never installed;
- **Shortcuts actions** for a chosen display, a **keyboard shortcut recorder**, a CLI with honest
  results and exit codes, and a **local HTTP API** bound to 127.0.0.1 and protected by a token;
- **settings backup, import and reset**, a **safe startup** (hold Shift at launch) and a list of
  remembered displays you can forget or reset;
- **virtual displays** for the current session (experimental);
- **screen capture with a picture-in-picture preview** (experimental);
- a full **Russian translation** with an in-app language switch;
- a **reliability pass**: fixes for Reconnect All, Black Out and display names, and for 30 of the 31
  most serious (P0) problems the guide study found in the code (see [Reliability](#reliability));
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
**Labs** is off by default; it is marked *Labs* in *Settings → Diagnostics*, where you turn it on.

### Brightness & dimming

| Feature | What it does | Status |
|---|---|---|
| **Hardware brightness (DDC/CI)** | Sets the external monitor's real backlight, plus contrast, volume and mute, input source, the monitor's own colour preset, sharpness, RGB gain, power and factory reset. Settings are read back after a change, and the app says whether a write was confirmed, only sent, or failed. Standby and power-off ask for confirmation first. The CLI can read or write any raw MCCS VCP code. | Core · full build |
| **Built-in brightness** | Controls the built-in panel through the system brightness service. | Core · full build |
| **Software dimming, colour temperature, contrast** | Dims any display with gamma, a black overlay or both, including displays without DDC; by design it never goes fully black. Each display also gets colour temperature and **software contrast**: a tone curve in that display's colour table, not the monitor's own contrast. Dimming, temperature, contrast and the XDR boost are worked into one colour table. *Suspend* bypasses temperature and contrast without losing their values; *Reset* returns them and dimming to neutral. These adjustments last until you quit. A custom ICC profile pauses gamma-based adjustments unless you allow them. | Core |
| **Black Out** | Makes a display fully black with a click-through overlay. Offered only while another display stays lit. | Core |
| **XDR Brightness** | Pushes SDR content on a built-in XDR panel up to 2× its normal maximum using EDR headroom. Never survives quit or a crash. You can have it switch off on battery or in Low Power Mode. | Labs |
| **Adaptive & scheduled brightness** | Follows the built-in display or the ambient light sensor. *Clock Mode* schedules brightness by fixed times or by sunrise, solar noon or sunset with offsets. *Location Mode* follows the sun's elevation. There's also evening warmth that follows Night Shift, and per-app presets. | Core · full build; *Adaptive display* and *App Presets* are Labs |
| **Display groups** | One slider or brightness key moves several displays together, in one of three modes: *learned offsets* (each display keeps the offset you taught it), *absolute* (every display takes the same percentage) or *delta* (every display moves by the same amount). Contrast sync is optional. The **Default group**, off by default, gives every connected display that isn't in a named group basic brightness sync. Hold **Shift** while dragging a brightness slider to change only that display. | Core |
| **FaceLight** | One press turns a display into a bright fill light for video calls. Press again to restore the previous settings. | Core |

### Resolutions & modes

| Feature | What it does | Status |
|---|---|---|
| **Mode picker** | Lists every mode macOS reports for a display, with logical size, framebuffer, refresh rate, HiDPI and tags such as native, default or scaled. Filter by aspect ratio, refresh rate, density and depth, optionally include modes macOS marks as not for desktop use, and see why a mode isn't listed. The menu-bar panel has a resolution slider that keeps the current refresh rate, density and depth. | Core |
| **Favourite modes** | Star modes and switch between them quickly. A favourite keeps the exact mode, so 59.94 Hz and 60 Hz stay different. Also available as `opendisplay favorite`. | Core |
| **Keep or revert** | A new mode or arrangement stays only if you confirm it. Otherwise it reverts automatically after a countdown. | Core |
| **Main display, mirroring, colour profiles** | Choose the main display, mirror the main display, and apply or reset ICC profiles through ColorSync. *Colour profile details* show where the active profile comes from, its class, colour space and file. You can import copies of profiles into your profiles folder, move your own profiles to the Trash (with undo), and open them in Finder or ColorSync Utility. | Core |
| **Rotation** | Rotates through an isolated helper with automatic rollback. Unavailable on macOS versions where it can't be done safely. | Labs |

### Arrangement & scenes

| Feature | What it does | Status |
|---|---|---|
| **Arrangement canvas** | Drag displays freely. A dropped display snaps to the nearest edge, centre or corner of another one (hold Shift to keep the exact spot along the edge); dropping it between two displays inserts it there, and gaps close by themselves. Drag the white menu-bar strip onto another display, or Control-click it, to make that display the main one. Each change applies at once and reverts unless you keep it. A compact copy of the canvas sits in the menu-bar panel under *Tools → Display arrangement*. | Core |
| **Protected layout** | When hotplug, sleep or another app changes your setup, puts back positions, modes, mirroring (with the exact mirror source), the main display and which displays are off. Each combination of displays keeps its own layout. | Core |
| **Scenes** | Saves the arrangement and modes of all displays so you can plan or apply them later from the app or the CLI. Applying a scene reports anything macOS didn't apply. | Core |
| **Logical disconnect** | Turns a display off without unplugging it, and always keeps at least one physical display active. Optionally turns the built-in panel off when an external display connects. | Experimental · full build |

### Menu bar & remembered displays

| Feature | What it does | Status |
|---|---|---|
| **Displays in the menu** | *Settings → Menu* shows or hides each display in the menu-bar panel, renames it, gives it an SF Symbols icon and sets the order (or keeps an automatic order, optionally with the main display first). A display the app turned off, or a blacked-out one, always stays in the menu. | Core |
| **Menu contents** | Every slider and display feature can be *Visible*, *In More* or *Hidden*, and each tool can be shown or hidden. Open sections can be remembered, and *Reset Menu Layout* puts everything back. | Core |
| **Hidden icon recovery** | If macOS hides the menu-bar icon (behind the camera notch, or switched off in System Settings), opening the app again brings up Settings, and **Open Menu Panel** shows the panel without the icon. | Core |
| **Remembered displays** | *Settings → Displays → Remembered* lists every display the app keeps a record of. *Forget* (for a display that isn't connected) and *Reset Settings* (for a connected one) show exactly what will be removed and ask for confirmation. Forgetting is refused while the app may still need a display's record to bring it back. | Core |

### Virtual displays · Experimental

Creates virtual screens for the current session through a private macOS API. You set the name,
pixel size, refresh rate (30, 60 or 120 Hz) and HiDPI. Up to four can exist at once, and they
disappear when the app quits. Creation must be allowed first, and it is refused in Safe Mode or
when no physical display is visible for recovery. *Full build only.*

### Screen capture & picture in picture · Experimental

Shows a live ScreenCaptureKit preview of any display or window in a floating, resizable window.
The preview can be flipped horizontally, rotated, cropped or zoomed, and passed through a `.cube`
LUT. It's an SDR preview at 30 fps, scaled to at most 1920 px, and it stays in memory: nothing is
recorded to disk. A running preview keeps going when you close Settings. macOS asks for Screen
Recording permission the first time you load sources.

### EDID & HiDPI tools · read and export only

- *Settings → EDID & HiDPI* reads the selected display's EDID inside the app. The bytes must carry
  that display's vendor, product code and serial number. If several EDIDs do (identical monitors
  without serial numbers) or none does, the app says *ambiguous* or *not found* instead of guessing.
- The decoder covers the base block, CTA-861 extensions (video and audio formats, HDR metadata,
  colorimetry and more) and DisplayID 1.x/2.x, including tiled displays. Checksum and structure
  problems are listed, not hidden.
- The bytes can be shown as a hex dump, hex, Base64 or a C array and copied. Export the original
  bytes as `.bin`, or an Apple display-override plist when the strict check passes. Imported EDID
  files are decoded the same way.
- *Settings → Displays → Information → Show Report…* builds a report for one display (identity,
  modes, capabilities, connection, EDID) that you can copy or save as UTF-8 text. Unknown values
  stay unknown.
- Plan HiDPI sizes and export a JSON plan that includes the restore steps, read each display's
  current and potential EDR headroom, or dump an EDID with `opendisplay edid <selector> --out edid.bin`.

FreeDisplay **never installs** overrides or system configuration. Applying an exported file is up
to you, and at your own risk.

### Automation

| Surface | What it does |
|---|---|
| **CLI `opendisplay`** | Covers display lists, brightness, DDC (including raw VCP), scenes, layout protection, groups, favourites, EDID, ambient light (`lux`), lid state, diagnostics and recovery. `listen` streams events as JSON lines. A write is reported as `verified` only when a read-back matches, otherwise as `sent`. Exit codes: 0 success, 1 failure, 2 usage error (nothing ran), 3 partly done. Unknown options are errors, never ignored. |
| **URL scheme** | `opendisplay://reconnect-all` runs immediately. A `disconnect` link is refused with a visible explanation: links never change displays. |
| **Shortcuts & Siri** | Actions with a display picker: *Get* and *Set Display Brightness* (0–100 %, the result says whether the display confirmed the level), *Set Display Mode* (the display's exact modes; the change is kept or reverted like one made in the menu), *Set Main Display*, plus *Reconnect All Displays*. A saved display that isn't connected is reported, never swapped for another one. Results are typed, so a shortcut can branch on them. *Settings → Automation* opens the Shortcuts app. |
| **Local HTTP API** | Listens only on 127.0.0.1, on a random port, with a new 256-bit bearer token each session. Endpoints: `GET /v1/displays`, `POST /v1/brightness`, `POST /v1/reconnect-all`. The display list gives the app's last known brightness with its age, or `null` when it isn't known. The server runs only while *Settings → Automation* is open. |
| **Media keys & OSD** | The brightness keys control the chosen display, in hardware or software. The volume keys are taken over only for a monitor whose DDC volume has been read back; otherwise macOS keeps them. Mute uses the monitor's own mute when it has one, and is labelled as volume 0 when it doesn't. The on-screen HUD has several styles, and every brightness or volume change can be broadcast to external HUD apps. Needs Accessibility permission. |
| **Keyboard shortcuts** | *Settings → Keyboard* records a global shortcut for each action: Reconnect All, making the next display main, FaceLight, brightness up and down (normal and fine steps), showing the menu, opening Settings and quitting. Each row says whether macOS registered the shortcut or why not (another action uses it, macOS refused it). Shortcuts can be removed or restored to their defaults. The same page sets the adjustment steps shared by the brightness and volume keys and the shortcuts. Input hotkeys (⌃⌥⌘-digit) switch a monitor to a chosen input, which is handy with a KVM. |
| **Notifications** | Notices about displays connecting and disconnecting, the built-in panel turning off automatically, layout protection and failures. In *Settings → Diagnostics → Behavior* choose Notification Center, a FreeDisplay window or off, mute routine protection notices, and see what macOS currently allows. |

### App settings

| Feature | What it does |
|---|---|
| **Backup, import, reset** | *Settings → About → App settings → Manage…* exports preferences, display names, favourites, groups, app presets, protected layouts, shortcuts and scenes to a JSON file. Importing checks the file and shows a summary, including displays this Mac doesn't know. Import and reset to defaults back up the current settings first and then relaunch the app. |
| **Safe startup** | Hold **Shift** while the app launches, or start it with `--safe-mode`. For that session nothing changes on its own: no layout restore, no automatic disconnects, no adaptive or scheduled brightness, no app presets and no group sync. Your settings stay untouched, and a banner lists what is held back. |
| **Dock icon** | *Settings → Diagnostics → Behavior*: never, while Settings is open (the default), while any app window is open, or always. The menu-bar icon stays either way. |
| **Settings window, build info** | Settings reopens on the last section and at the last size. *About* shows the build details and a **Copy Build Information** button. |

### Safety & recovery

| Feature | What it does |
|---|---|
| **Reconnect All** | Available from the menu, a global hotkey (**⌃⌥⌘R** by default), Shortcuts, the URL scheme, HTTP and `opendisplay recover`. |
| **Transactions & audit log** | Risky changes go through checkpoints, verification and rollback. Quitting the app reconnects every display it turned off, and keeps the record of any display that didn't come back. |
| **Rescue app** | The standalone **FreeDisplay Rescue** restores the last known-safe arrangement, even when the main app can't run. |
| **Diagnostics export** | Saves one zip to your Desktop with the app's records, macOS display configuration and recent display-related log lines. It is never sent anywhere. |

If a display won't come back, see [Recovering a stranded display](Docs/Recovering-a-stranded-display.md).

### Reliability

Besides comparing features, the [BetterDisplay guide study](Docs/BetterDisplay-Guide/00-overview-and-backlog.md)
checked FreeDisplay's own code and grouped what it found into 31 P0 clusters, mostly places where the
app could act on the wrong display or report something it didn't know. Fixes for 30 of them are merged:

- **DDC:** standby and power-off need confirmation, and every DDC result says confirmed, sent or
  failed. A requested input isn't shown as current until the monitor reports it. When two monitors
  can't be told apart, DDC refuses instead of guessing, and Apple displays get no generic DDC unless
  you opt in per display.
- **Identity and EDID:** identical monitors no longer silently share one record or borrow each
  other's EDID; when they can't be told apart, the app says so.
- **Recovery:** only a physical screen counts as the one that must stay on, so a virtual screen
  can't stand in for it. A display that didn't reconnect when the app quit keeps its recovery record.
- **Modes and colour:** the resolution slider keeps the current refresh rate, density and depth;
  favourites keep exact modes; mirror restores use the exact source; colour-profile and gamma
  failures are shown; an unknown HDR state stays unknown.
- **Automation:** the CLI has strict options, real help and exit codes; HTTP brightness is labelled
  as a cached value with its age; brightness events are broadcast even when the HUD is off; a
  cleared shortcut stays cleared; the release script fails if signing or Gatekeeper checks fail.

Still open: **FD-015**. The DDC reader still accepts some replies without a length and checksum
check, because making it strict without hardware evidence could break monitors that work today.
The gap is documented in the code and waits for the maintainer's decision. All of these are code
fixes with unit tests; they haven't been checked on a wide range of real monitors.

## Gallery

<table>
  <tr>
    <td width="50%"><img src="Docs/images/freedisplay/menu-en.png" alt="Menu section: hidden-icon help with an Open Menu Panel button, displays in the menu with name, icon, Show in menu switch and order arrows, and sliders set to Visible or In More"><br><sub><b>Menu</b>: what the menu-bar panel shows, and in what order</sub></td>
    <td width="50%"><img src="Docs/images/freedisplay/keyboard-en.png" alt="Keyboard section: shortcut recorder rows for Reconnect All, display, brightness and app actions, each with its registration status and Record Shortcut, remove and restore buttons"><br><sub><b>Keyboard</b>: shortcut recorder with registration status</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="Docs/images/freedisplay/arrange-en.png" alt="Arrange section: a display on the free-drag arrangement canvas with the menu-bar strip, instructions for snapping and changing the main display, and the Protected layout option"><br><sub><b>Arrange</b>: free-drag canvas and protected layout</sub></td>
    <td width="50%"><img src="Docs/images/freedisplay/advanced-en.png" alt="EDID and HiDPI section: display picker, EDR headroom, the EDID of this display reported as not found for the built-in panel, EDID file import and HiDPI planning"><br><sub><b>EDID & HiDPI</b>: in-app EDID reader, read-only</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="Docs/images/freedisplay/automation-en.png" alt="Automation section: Shortcuts app actions with an Open Shortcuts button, and local HTTP control with Start Local Server, Stop and Copy Session Token buttons and the three endpoints"><br><sub><b>Automation</b>: Shortcuts and local HTTP</sub></td>
    <td width="50%"><img src="Docs/images/freedisplay/about-en.png" alt="About section: version 0.11.5, local build note, upstream links, build information with a copy button, the Interface language picker and app settings backup, restore or reset"><br><sub><b>About</b>: build info, language, settings backup</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="Docs/images/freedisplay/virtual-en.png" alt="Virtual Displays section: experimental opt-in toggle, name, size in pixels, refresh rate and HiDPI"><br><sub><b>Virtual displays</b> (experimental)</sub></td>
    <td width="50%"><img src="Docs/images/freedisplay/capture-en.png" alt="Screen Capture section: source picker, Start PIP, flip, rotation, crop and zoom, LUT loading"><br><sub><b>Screen capture & PiP</b> (experimental)</sub></td>
  </tr>
</table>

## FreeDisplay vs BetterDisplay

BetterDisplay is a mature commercial app with a free tier and a paid Pro tier. FreeDisplay is
**not** a drop-in replacement. It covers the everyday core, and several large areas are still
missing. The page-by-page study of the official guide lives in
**[Docs/BetterDisplay-Guide/](Docs/BetterDisplay-Guide/)**: all 501 guide pages, with code evidence
for every topic. Its roadmap,
**[00-overview-and-backlog.md](Docs/BetterDisplay-Guide/00-overview-and-backlog.md)**, merges the
392 backlog items into 162 clusters: **31 P0 · 47 P1 · 62 P2 · 22 P3**. The status columns in that
file describe the code as of 14 October 2026, before the work listed here.

**Where the backlog stands on 15 October 2026:**

- **P0 (fixes): 30 of 31 clusters fixed.** FD-015 (relaxed DDC checksum handling) is still open;
  see [Reliability](#reliability).
- **P1: work has landed for 22 of 47 clusters**, several of them only in part.
  - *Wave 1, everyday display controls:* all 10 clusters (mode list and filters, adjustment steps,
    arrangement canvas, colour profiles, software contrast and image-adjustment restore, menu
    customisation, Default group). Partial: steps don't yet snap or follow scrolling, and physical
    size can't be edited.
  - *Wave 2, keyboard, audio and feedback:* 4 of 8 (shortcut recorder, notifications, Dock icon,
    Shortcuts guidance). Missing: binding to audio devices, key target sets and listening options,
    OSD placement.
  - *Wave 3, identity, diagnostics and recovery:* 5 of 8 (remembered displays, information report,
    EDID reader, settings backup, safe startup). Missing: moving settings between display
    identities, measured refresh rate, luminance (nits) anchors.
  - *Wave 4, shared automation:* 1 of 9 (Shortcuts display entity and actions, without a colour
    profile action), plus menu, Settings and Quit shortcuts from another cluster. Missing: one typed
    command model for CLI, URL and HTTP, a command console, outgoing actions, event hooks, unified
    logging.
  - *Wave 5:* 2 of 6 (Settings window memory, build information). *Wave 6* (FreeDisplay-owned
    signed updates, recording guide, LG and Samsung TV control) hasn't started.

| Area | FreeDisplay today |
|---|---|
| DDC/CI hardware controls (Apple Silicon) | ✔ Brightness, contrast, volume, input, presets, RGB gain, power, raw VCP; results say confirmed, sent or failed |
| Software dimming, colour temperature, software contrast, media keys, OSD | ✔ |
| Resolution and refresh picker, favourites, keep/revert | ✔ Complete list with filters; only modes macOS already offers |
| Arrangement, main display, layout protection, scenes | ✔ Free-drag canvas with snapping; no relative layout rules |
| Display groups | Partial: learned-offset, absolute or delta brightness, optional contrast, Default group; one group per display, no directional sync rules |
| Menu customisation | Partial: per-display visibility, order, name and icon, item placement; no detachable menu |
| App settings: backup/import/reset, Dock icon, notifications, safe startup | ✔ |
| EDID read, decode and export | ✔ In-app reader with CTA-861 and DisplayID decoding |
| **EDID override installation** | ✘ Validate and export only |
| **Flexible HiDPI scaling and custom resolutions** | ✘ The HiDPI planner exports a plan; it installs nothing |
| **XDR / HDR extra brightness** | Partial: built-in XDR panel only (Labs); no third-party HDR displays, no nits calibration |
| **Connection format (RGB/YCbCr, range, depth), timing, VRR, HDR switching** | ✘ |
| **Streaming, PiP on another screen, video-filter windows, display-wide LUTs** | Partial: one floating SDR preview window |
| **Network TV and AV-receiver control** (LG webOS, Samsung, Philips, Yamaha) | ✘ |
| **HDMI-CEC, DisplayLink** | ✘ |
| Virtual screens | Partial: session-only, basic settings, no associations, no HDR |
| Audio device association | Partial: matched by name; no native association |
| Automation breadth | Partial: CLI with typed results, 5 Shortcuts actions, 3 HTTP endpoints (only while *Settings → Automation* is open), 1 URL command; no console, outgoing actions or per-display event hooks |
| Signed releases and updates | ✘ Built from source only |
| Intel Macs | ✘ Apple Silicon only |

Where FreeDisplay takes a different path:

- **Free and open source (GPL-3.0).** No licence key, no trial, no paid tier, and every line can be
  inspected.
- **Safety model.** Risky changes are transactions with verification and automatic rollback.
  Reconnect All is always one hotkey away, and a standalone rescue app is included.
- **Honest results.** When a monitor ignores a DDC write, the UI says so instead of showing a value
  the monitor isn't at. EDID reads, reports and the HTTP API say "unknown" or "ambiguous" rather
  than guess.

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
  `FreeDisplay.app/Contents/Helpers`, where the Labs rotation helper expects it. It builds with the
  signing settings from `project.yml`.
- The app lives in the menu bar. By default its Dock icon shows only while Settings is open
  (change it in *Settings → Diagnostics → Behavior*). ⌥-click the menu-bar icon to open Settings,
  and hold Shift while the app launches for a [safe startup](#app-settings).

### Tests

```sh
make test        # swift test --parallel
```

This runs the platform-independent core (`DisplayDomain`, `SceneEngine`, `AutomationSchema`,
`TopologyCore`): **1,254 unit and state-machine tests**, all passing on 15 October 2026, after a codex review of the whole fork diff and two follow-up fix rounds. The core
is meant to build on Linux too (`make bootstrap` installs a Swift 6 toolchain there). There's no
remote CI; the local test run is the gate.

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
  opendisplay recover [--json]                # reconnect every display OpenDisplay turned off
  opendisplay scene <list|save|show|plan|apply|delete> [name] [--json]
  opendisplay layout <protect|unprotect|status> [--json]
  opendisplay group <list|create|delete> [name] [--json]
  opendisplay group <add|remove> <name> <selector>
  opendisplay brightness <selector> [0..1] [--json]
  opendisplay ddc <selector> <brightness|contrast|volume|input|colour|sharpness|red|green|blue|mute|power|caps> [value] [--json]
  opendisplay ddc <selector> reset                # restore the monitor's factory defaults (VCP 0x04)
  opendisplay ddc <selector> vcp <0xNN> [value]   # any raw MCCS feature code
  opendisplay edid <selector> [--out <path.bin>]
  opendisplay favorite <list|set|unset> <selector> [WxH[@Hz][@2x]]
  opendisplay help | --help | -h

Options are accepted only by the commands listed with them; any other option is an error, so
for example `--dry-run` never silently performs a real write.

RESULTS: a write is reported as `verified` only when reading the value back shows it; `sent`
means the display accepted the write but nothing confirmed it took. Failures go to stderr.

EXIT STATUS: 0 success (including nothing to do) · 1 failed · 2 usage error (nothing ran) ·
3 partly done (some displays/fields applied, others failed or were skipped).

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
# {"displays":[{"active":true,"brightness":0.8,"brightnessAgeSeconds":42.5,"brightnessCachedAt":"…",
#   "brightnessSource":"appCache","id":"…","name":"…","physicalBrightnessVerified":false}]}
# A display the app has no level for yet: "brightness":null,"brightnessSource":"unknown"

curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"displayId":"<id from /v1/displays>","value":0.5}' \
     "http://127.0.0.1:$PORT/v1/brightness"
```

A brightness response reports that the change was *requested* (`"physicalEffectVerified":false`);
it doesn't claim a verified hardware result. See [Docs/Local-HTTP-Control.md](Docs/Local-HTTP-Control.md) for the full
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
- [BetterDisplay guide study](Docs/BetterDisplay-Guide/) · [consolidated backlog and P1 waves](Docs/BetterDisplay-Guide/00-overview-and-backlog.md)
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
  media keys, Screen Recording for capture, Notifications for display notices.
- Display reports and settings exports can contain hardware identifiers such as serial numbers and
  display UUIDs. Check them before you share them.
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
