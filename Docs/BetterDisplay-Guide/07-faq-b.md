# BetterDisplay guide — 07-faq-b

## Coverage

All **139/139** files in `/tmp/bd-guide/parts/07-faq-b.txt` were read in full, including the 17 category landing pages. The live versions of those category pages and the scaling explanation were opened to recover navigation and verify flattened tables. Their additional linked articles outside the manifest are not counted as extra pages. Category summaries are covered in T01; detailed requirements are mapped below.

This is a clean-room capability analysis of the current working tree, inspected on 2026-10-14. It is **static code evidence**, not evidence of successful builds, tests, capture, monitor response, or sleep/wake operation. No app, CLI, test suite, or display-setting action was run. The older parity map was not treated as proof. Graph discovery was followed by current source reads because indexed line ranges had drifted; concurrent UI translations were ignored.

**Reading conventions.** “Free” means explicitly available without Pro in these sources; “Pro” means explicitly gated. “Tier unspecified” means the supplied FAQ does not establish that control's entitlement, not that it is free. Mixed topics identify the gated subfeatures. FreeDisplay has no proposed paywall: BetterDisplay tiers guide prioritization only. ✅ denotes an implemented code path, 🟡 an incomplete workflow, ⬜ an absent capability, and ➖ an OS/hardware or BetterDisplay-business limitation rather than a feature to reproduce. File paths are repository-relative and line numbers refer to the inspected snapshot. Effort S/M/L is relative engineering effort; private APIs require OS-specific qualification. Acceptance bullets are work for the implementing engineer, not checks performed in this audit.


| # | Guide page (URL) | Topics extracted |
| --- | --- | --- |
| 1 | [scaling](https://betterdisplay.pro/guide/faq/scaling/) | T01: Category navigation: scaling, mode creation and pixel interpretation |
| 2 | [display modes](https://betterdisplay.pro/guide/faq/display-modes/) | T01: Category navigation: logical modes, timing and filtering |
| 3 | [refresh rates](https://betterdisplay.pro/guide/faq/refresh-rates/) | T01: Category navigation: nominal rate, VRR and physical timing |
| 4 | [edid](https://betterdisplay.pro/guide/faq/edid/) | T01: Category navigation: EDID retrieval, overrides and writing |
| 5 | [brightness](https://betterdisplay.pro/guide/faq/brightness/) | T01: Category navigation: hardware, software and combined brightness |
| 6 | [hdr](https://betterdisplay.pro/guide/faq/hdr/) | T01: Category navigation: HDR, XDR, presets and protection |
| 7 | [color](https://betterdisplay.pro/guide/faq/color/) | T01: Category navigation: profiles, formats, depth and dithering |
| 8 | [ddc](https://betterdisplay.pro/guide/faq/ddc/) | T01: Category navigation: controller configuration and readback |
| 9 | [tv controls](https://betterdisplay.pro/guide/faq/tv-controls/) | T01: Category navigation: network TV/CEC readiness and automation |
| 10 | [connections](https://betterdisplay.pro/guide/faq/connections/) | T01: Category navigation: transport, detection and hardware diagnosis |
| 11 | [display disconnection](https://betterdisplay.pro/guide/faq/display-disconnection/) | T01: Category navigation: soft disconnect, safety and recovery |
| 12 | [wake](https://betterdisplay.pro/guide/faq/wake/) | T01: Category navigation: startup, wake, restoration and assertions |
| 13 | [layouts](https://betterdisplay.pro/guide/faq/layouts/) | T01: Category navigation: main screen, geometry and related devices |
| 14 | [virtual streaming](https://betterdisplay.pro/guide/faq/virtual-streaming/) | T01: Category navigation: virtual definitions, viewing and associations |
| 15 | [streaming](https://betterdisplay.pro/guide/faq/streaming/) | T01: Category navigation: capture, presentation and input handling |
| 16 | [recording](https://betterdisplay.pro/guide/faq/recording/) | T01: Category navigation: recording sources, resolution and permissions |
| 17 | [remote displays](https://betterdisplay.pro/guide/faq/remote-displays/) | T01: Category navigation: AirPlay, Sidecar and remote clients |
| 18 | [scaling / macos scaling hidpi lodpi](https://betterdisplay.pro/guide/faq/scaling/macos-scaling-hidpi-lodpi/) | T02: Logical points versus backing pixels; 2× HiDPI; panel resampling |
| 19 | [scaling / add hidpi resolutions](https://betterdisplay.pro/guide/faq/scaling/add-hidpi-resolutions/) | T03: Free custom sizes; Pro flexible generation; apply and activate |
| 20 | [scaling / hidpi resolution limits](https://betterdisplay.pro/guide/faq/scaling/hidpi-resolution-limits/) | T03: Rendering ceilings, sub-720p option and over-8K opt-in |
| 21 | [scaling / displaylink scaling](https://betterdisplay.pro/guide/faq/scaling/displaylink-scaling/) | T03: DisplayLink driver modes; native-route distinction; virtual workaround |
| 22 | [scaling / larger text](https://betterdisplay.pro/guide/faq/scaling/larger-text/) | T02: Per-display desktop size versus app zoom and physical PPI |
| 23 | [scaling / stretch desktop](https://betterdisplay.pro/guide/faq/scaling/stretch-desktop/) | T58: Virtual-source stretching; 1:1 mapping exclusion; free aspect |
| 24 | [scaling / text still poor](https://betterdisplay.pro/guide/faq/scaling/text-still-poor/) | T04: Text clarity, monitor processing, chroma and alternate resampling |
| 25 | [scaling / hidpi performance](https://betterdisplay.pro/guide/faq/scaling/hidpi-performance/) | T04: HiDPI pixel cost; capture load; CPU/GPU and latency comparisons |
| 26 | [scaling / resolution percentage](https://betterdisplay.pro/guide/faq/scaling/resolution-percentage/) | T02: Resolution percentage baseline; logical width versus density |
| 27 | [scaling / magnification percentage](https://betterdisplay.pro/guide/faq/scaling/magnification-percentage/) | T05: Magnification option; native-aspect filter; 12-mode prerequisite |
| 28 | [scaling / check hidpi](https://betterdisplay.pro/guide/faq/scaling/check-hidpi/) | T02: Active HiDPI marker and inspecting the selected mode |
| 29 | [scaling / pixel perfect photo editing](https://betterdisplay.pro/guide/faq/scaling/pixel-perfect-photo-editing/) | T02: Pixel-accurate photo viewing, app zoom and native signal |
| 30 | [scaling / desktop above native](https://betterdisplay.pro/guide/faq/scaling/desktop-above-native/) | T58: Above-native workspace, downsampling and presentation requirements |
| 31 | [scaling / hidpi toggle size](https://betterdisplay.pro/guide/faq/scaling/hidpi-toggle-size/) | T06: Opposite-density selection, unavailable pairs and nonreversible toggles |
| 32 | [scaling / crt low resolution](https://betterdisplay.pro/guide/faq/scaling/crt-low-resolution/) | T07: CRT connection timing IDs, cropped desktops and safe restoration |
| 33 | [scaling / physical output resolution](https://betterdisplay.pro/guide/faq/scaling/physical-output-resolution/) | T07: Desktop mode versus physical signal; OSD and timing evidence |
| 34 | [scaling / save favorite mode](https://betterdisplay.pro/guide/faq/scaling/save-favorite-mode/) | T06: Five complete favorite slots; assign, replace, remove and availability |
| 35 | [scaling / missing mode list](https://betterdisplay.pro/guide/faq/scaling/missing-mode-list/) | T05: Mode filters, Show All and independent tiny-mode restriction |
| 36 | [scaling / limit resolution slider](https://betterdisplay.pro/guide/faq/scaling/limit-resolution-slider/) | T05: Slider/keyboard width-height limits; preserve out-of-range current mode |
| 37 | [scaling / hardware pbp](https://betterdisplay.pro/guide/faq/scaling/hardware-pbp/) | T08: Hardware PBP input geometry, EDID and model-specific DDC |
| 38 | [scaling / protection allows app changes](https://betterdisplay.pro/guide/faq/scaling/protection-allows-app-changes/) | T09: Protected values accept intentional app changes and reject external drift |
| 39 | [scaling / hidpi refresh rate](https://betterdisplay.pro/guide/faq/scaling/hidpi-refresh-rate/) | T10: Complete HiDPI/rate combinations and connection-level alternatives |
| 40 | [scaling / refresh rate disagrees](https://betterdisplay.pro/guide/faq/scaling/refresh-rate-disagrees/) | T10: Nominal versus connection refresh; VRR and timing reporter |
| 41 | [scaling / virtual refresh rate](https://betterdisplay.pro/guide/faq/scaling/virtual-refresh-rate/) | T11: Virtual 24–240 Hz list, 60-Hz fallback and mirror-target controls |
| 42 | [brightness / hdr hidpi modes](https://betterdisplay.pro/guide/faq/brightness/hdr-hidpi-modes/) | T12: Mode-dependent HDR, allow-forced gate, effective HDR and recovery |
| 43 | [scaling / shared model settings](https://betterdisplay.pro/guide/faq/scaling/shared-model-settings/) | T13: Model-wide system overrides versus app-local identification |
| 44 | [scaling / edit native resolution](https://betterdisplay.pro/guide/faq/scaling/edit-native-resolution/) | T08: Native geometry editing, staged activation and unsafe fictitious sizes |
| 45 | [connections / edid reapplied](https://betterdisplay.pro/guide/faq/connections/edid-reapplied/) | T14: Original/alternate EDID identity; automatic rule ownership and recovery |
| 46 | [scaling / import custom edid](https://betterdisplay.pro/guide/faq/scaling/import-custom-edid/) | T14: Prepared EDID import, explicit software apply and safe unapply |
| 47 | [scaling / edid write result](https://betterdisplay.pro/guide/faq/scaling/edid-write-result/) | T15: OS retrieval, extension completeness, hardware write limits and verification |
| 48 | [connections / displayid extension](https://betterdisplay.pro/guide/faq/connections/displayid-extension/) | T15: DisplayID parsing, timing/tile reports and unsupported advertised features |
| 49 | [scaling / apply configuration fails](https://betterdisplay.pro/guide/faq/scaling/apply-configuration-fails/) | T16: Pending Apply/Undo, authorization paths, helper errors and activation |
| 50 | [scaling / multiple user overrides](https://betterdisplay.pro/guide/faq/scaling/multiple-user-overrides/) | T13: Shared Mac-wide overrides across user accounts and conflict handling |
| 51 | [brightness / restore full dimming](https://betterdisplay.pro/guide/faq/brightness/restore-full-dimming/) | T17: Startup/wake restore, full-black safeguard and Apple excessive-dim default |
| 52 | [brightness / touch id prompt](https://betterdisplay.pro/guide/faq/brightness/touch-id-prompt/) | T22: Obscured purchase/Touch ID prompts and effect suspension diagnosis |
| 53 | [brightness / match displays](https://betterdisplay.pro/guide/faq/brightness/match-displays/) | T20: Nits-aware group matching, receiver limits and native-key bypass |
| 54 | [brightness / monitor percentage mismatch](https://betterdisplay.pro/guide/faq/brightness/monitor-percentage-mismatch/) | T18: Hardware/software/combined percentages; controller limits and locks |
| 55 | [brightness / dim below hardware minimum](https://betterdisplay.pro/guide/faq/brightness/dim-below-hardware-minimum/) | T18: Hardware floor with software dimming below it |
| 56 | [brightness / native auto brightness management](https://betterdisplay.pro/guide/faq/brightness/native-auto-brightness-management/) | T19: Native auto-brightness ownership versus the OS preference |
| 57 | [brightness / nits estimates](https://betterdisplay.pro/guide/faq/brightness/nits-estimates/) | T20: Nits provenance, HDR limits, manual anchors and curved mappings |
| 58 | [brightness / bright cursor](https://betterdisplay.pro/guide/faq/brightness/bright-cursor/) | T21: Cursor unaffected by overlay versus hardware/gamma behavior |
| 59 | [brightness / software dimming floor](https://betterdisplay.pro/guide/faq/brightness/software-dimming-floor/) | T18: Software slider zero remapping and separate screen-off-at-zero behavior |
| 60 | [brightness / automatic external brightness](https://betterdisplay.pro/guide/faq/brightness/automatic-external-brightness/) | T19: Ambient-driven source following, external events and group offsets |
| 61 | [brightness / startup restoration](https://betterdisplay.pro/guide/faq/brightness/startup-restoration/) | T17: Global restoration policies and their DDC persistence consequences |
| 62 | [brightness / direct upscaling dips](https://betterdisplay.pro/guide/faq/brightness/direct-upscaling-dips/) | T23: Direct XDR force-EDR default and cross-display effects |
| 63 | [brightness / upscaling stops working](https://betterdisplay.pro/guide/faq/brightness/upscaling-stops-working/) | T23: Software/direct XDR prerequisites, method troubleshooting and key routing |
| 64 | [brightness / keep hdr enabled](https://betterdisplay.pro/guide/faq/brightness/keep-hdr-enabled/) | T09: HDR-state protection, wake drift and stale OS UI |
| 65 | [scaling / virtual screen hdr](https://betterdisplay.pro/guide/faq/scaling/virtual-screen-hdr/) | T24: Virtual extended-luminance modes, HDR filter path and SDR alternatives |
| 66 | [brightness / reference presets](https://betterdisplay.pro/guide/faq/brightness/reference-presets/) | T22: Reference-preset appearance versus software master adjustment |
| 67 | [brightness / exit direct upscaling](https://betterdisplay.pro/guide/faq/brightness/exit-direct-upscaling/) | T23: Exit direct XDR using ordinary preset and restore saved context |
| 68 | [brightness / hdr vrr flicker](https://betterdisplay.pro/guide/faq/brightness/hdr-vrr-flicker/) | T10: Fixed-rate comparison for HDR/VRR flicker |
| 69 | [brightness / reference mode emulation](https://betterdisplay.pro/guide/faq/brightness/reference-mode-emulation/) | T24: Limits of virtual/EDID reference-preset and calibration emulation |
| 70 | [brightness / sdr brightness in hdr](https://betterdisplay.pro/guide/faq/brightness/sdr-brightness-in-hdr/) | T25: SDR reference white inside HDR versus hardware brightness preference |
| 71 | [brightness / hdr highlight clipping](https://betterdisplay.pro/guide/faq/brightness/hdr-highlight-clipping/) | T22: Highlight clipping, suspend effects/LUTs and immediate reset scope |
| 72 | [brightness / xdr readiness system load](https://betterdisplay.pro/guide/faq/brightness/xdr-readiness-system-load/) | T23: Continuous XDR readiness, immediate change and resource tradeoff |
| 73 | [brightness / custom profile black screen](https://betterdisplay.pro/guide/faq/brightness/custom-profile-black-screen/) | T26: Global custom-ICC gamma guard and black-but-connected diagnosis |
| 74 | [brightness / desktop dark filters](https://betterdisplay.pro/guide/faq/brightness/desktop-dark-filters/) | T27: Whole-desktop filters, inversion, compositor backend and transition flashes |
| 75 | [brightness / night shift tv](https://betterdisplay.pro/guide/faq/brightness/night-shift-tv/) | T28: TV/computer system role and HDR Night Shift/True Tone suppression |
| 76 | [brightness / select rgb](https://betterdisplay.pro/guide/faq/brightness/select-rgb/) | T29: RGB/YCbCr selection, bandwidth and Intel override distinction |
| 77 | [scaling / gamma test pattern](https://betterdisplay.pro/guide/faq/scaling/gamma-test-pattern/) | T02: Unresampled gamma patterns, native LoDPI and controlled viewing |
| 78 | [brightness / color table compatibility](https://betterdisplay.pro/guide/faq/brightness/color-table-compatibility/) | T26: Color-table bypass, current method, affected hardware and competing apps |
| 79 | [brightness / framebuffer connection depth](https://betterdisplay.pro/guide/faq/brightness/framebuffer-connection-depth/) | T29: Render precision, storage depth, cable depth and panel FRC |
| 80 | [brightness / keep color mode](https://betterdisplay.pro/guide/faq/brightness/keep-color-mode/) | T09: Separate protected SDR/HDR formats and effective-state availability |
| 81 | [brightness / calibration and profiles](https://betterdisplay.pro/guide/faq/brightness/calibration-and-profiles/) | T30: Profiles versus hardware calibration and measured characterization |
| 82 | [brightness / washed out colors](https://betterdisplay.pro/guide/faq/brightness/washed-out-colors/) | T29: Full/limited range agreement and avoiding compensatory adjustments |
| 83 | [brightness / mini led blooming](https://betterdisplay.pro/guide/faq/brightness/mini-led-blooming/) | T21: Mini-LED physical blooming and contrast/brightness tradeoffs |
| 84 | [brightness / disable dithering](https://betterdisplay.pro/guide/faq/brightness/disable-dithering/) | T29: GPU dithering state, active ports, uniformity correction and panel limits |
| 85 | [connections / missing input source](https://betterdisplay.pro/guide/faq/connections/missing-input-source/) | T31: Independent DDC input enablement, editable source values and write-only paths |
| 86 | [connections / apple cinema ddc](https://betterdisplay.pro/guide/faq/connections/apple-cinema-ddc/) | T32: Legacy Apple DDC exclusion and explicit generic-controller override risk |
| 87 | [brightness / ddc readback](https://betterdisplay.pro/guide/faq/brightness/ddc-readback/) | T33: Cached versus raw values, current/max readback and polling default |
| 88 | [brightness / ddc rgb gain range](https://betterdisplay.pro/guide/faq/brightness/ddc-rgb-gain-range/) | T34: Per-channel gain ranges, persistent monitor state and neutral values |
| 89 | [brightness / hardware contrast](https://betterdisplay.pro/guide/faq/brightness/hardware-contrast/) | T35: Hardware contrast enablement, menu placement, normalized/raw automation |
| 90 | [connections / lg wakes after undocking](https://betterdisplay.pro/guide/faq/connections/lg-wakes-after-undocking/) | T36: LG connection recheck default, wake prerequisites and third-pass WOL |
| 91 | [connections / philips input selection](https://betterdisplay.pro/guide/faq/connections/philips-input-selection/) | T37: Philips paired remote, source key and arrow/OK navigation |
| 92 | [connections / lg tv controls](https://betterdisplay.pro/guide/faq/connections/lg-tv-controls/) | T36: LG pairing, picture controls, relative volume and Mac-input power behavior |
| 93 | [brightness / lg service menu](https://betterdisplay.pro/guide/faq/brightness/lg-service-menu/) | T38: LG Option-revealed service entries and explicit access enable/disable |
| 94 | [connections / samsung tv controls](https://betterdisplay.pro/guide/faq/connections/samsung-tv-controls/) | T39: Samsung authorization, relative volume, remote inputs and missing backlight |
| 95 | [connections / dell up3218k](https://betterdisplay.pro/guide/faq/connections/dell-up3218k/) | T40: UP3218K dual-link limits, tile diagnosis and direct-cable comparison |
| 96 | [connections / generic display](https://betterdisplay.pro/guide/faq/connections/generic-display/) | T41: Generic identity, saved placeholders and KVM identification |
| 97 | [connections / dcp kernel panic](https://betterdisplay.pro/guide/faq/connections/dcp-kernel-panic/) | T42: DCP panic evidence, controlled isolation and persistent override effects |
| 98 | [connections / camera device names](https://betterdisplay.pro/guide/faq/connections/camera-device-names/) | T41: Display aliases do not rename cameras or microphones |
| 99 | [connections / kvm desktop continuity](https://betterdisplay.pro/guide/faq/connections/kvm-desktop-continuity/) | T43: Persistent virtual source across KVM switching and mirror restoration |
| 100 | [connections / automatic built in disconnect](https://betterdisplay.pro/guide/faq/connections/automatic-built-in-disconnect/) | T44: Automatic internal disconnect, eligible externals, ignore list and rescue |
| 101 | [connections / blank without disconnecting](https://betterdisplay.pro/guide/faq/connections/blank-without-disconnecting/) | T45: Blank image versus topology removal, standby and hardware power |
| 102 | [connections / last physical display](https://betterdisplay.pro/guide/faq/connections/last-physical-display/) | T44: Last physical screen, virtual exclusions, DisplayLink exception and overrides |
| 103 | [connections / brief blackout](https://betterdisplay.pro/guide/faq/connections/brief-blackout/) | T45: Transient link resync versus persistent black output |
| 104 | [connections / unwanted display](https://betterdisplay.pro/guide/faq/connections/unwanted-display/) | T46: Detected versus remembered screens, 90-day retention, reset and forget |
| 105 | [connections / touch bar after undocking](https://betterdisplay.pro/guide/faq/connections/touch-bar-after-undocking/) | T47: Lid/open/reconnect order before undocking and Touch Bar limitations |
| 106 | [brightness / ddc brightness after wake](https://betterdisplay.pro/guide/faq/brightness/ddc-brightness-after-wake/) | T48: Delayed DDC wake/reconnect replay and command-only exclusions |
| 107 | [connections / sleep after unplugging](https://betterdisplay.pro/guide/faq/connections/sleep-after-unplugging/) | T49: Assertion ownership, 15-second comparison and transient 10-second holds |
| 108 | [connections / reinitialize on wake](https://betterdisplay.pro/guide/faq/connections/reinitialize-on-wake/) | T50: Default-off framebuffer reinit, custom/factory EDID fallback and adapter reset |
| 109 | [connections / keep disconnected after wake](https://betterdisplay.pro/guide/faq/connections/keep-disconnected-after-wake/) | T51: Default-off post-wake redisconnection, delay and main-display exclusion |
| 110 | [connections / filevault startup resolution](https://betterdisplay.pro/guide/faq/connections/filevault-startup-resolution/) | T52: FileVault preboot/Recovery versus user-session controls |
| 111 | [layouts / main display](https://betterdisplay.pro/guide/faq/layouts/main-display/) | T53: Main-display origin, relative layout and automation ordering |
| 112 | [virtual streaming / split physical monitor](https://betterdisplay.pro/guide/faq/virtual-streaming/split-physical-monitor/) | T54: Multiple virtual regions, PiP levels/locks, sharing and pointer handling |
| 113 | [virtual streaming / switch desktops](https://betterdisplay.pro/guide/faq/virtual-streaming/switch-desktops/) | T55: Hide fullscreen streams, expose underlying desktop and separate pointer movement |
| 114 | [virtual streaming / reported physical size](https://betterdisplay.pro/guide/faq/virtual-streaming/reported-physical-size/) | T56: Reported diagonal versus group physical-size metadata |
| 115 | [virtual streaming / automatic reconnection](https://betterdisplay.pro/guide/faq/virtual-streaming/automatic-reconnection/) | T57: Any-online/all-offline associations and disabled manual controls |
| 116 | [virtual streaming / resolution steps](https://betterdisplay.pro/guide/faq/virtual-streaming/resolution-steps/) | T56: Generated steps, aspect arithmetic, bounds, cap and Sidecar setup |
| 117 | [virtual streaming / mission control](https://betterdisplay.pro/guide/faq/virtual-streaming/mission-control/) | T54: Mission Control/session semantics and PiP levels across Spaces |
| 118 | [virtual streaming / preview smaller monitor](https://betterdisplay.pro/guide/faq/virtual-streaming/preview-smaller-monitor/) | T58: Smaller-workspace previews, PiP size and stream zoom/underscan |
| 119 | [virtual streaming / pip dock icon](https://betterdisplay.pro/guide/faq/virtual-streaming/pip-dock-icon/) | T59: Dock policies: Settings-only, any-window and always |
| 120 | [virtual streaming / stream stopped](https://betterdisplay.pro/guide/faq/virtual-streaming/stream-stopped/) | T60: System capture stop reasons, exact errors, logging and focused restart |
| 121 | [virtual streaming / pip tabs](https://betterdisplay.pro/guide/faq/virtual-streaming/pip-tabs/) | T61: PiP merge/show/detach tabs and filter-window exclusion |
| 122 | [virtual streaming / freeze presentation](https://betterdisplay.pro/guide/faq/virtual-streaming/freeze-presentation/) | T62: Pause frame, stop source, hide output and privacy limitations |
| 123 | [virtual streaming / pip auto start](https://betterdisplay.pro/guide/faq/virtual-streaming/pip-auto-start/) | T63: Auto-start on source connection, wake resume and manual-close suppression |
| 124 | [virtual streaming / multiple cropped pips](https://betterdisplay.pro/guide/faq/virtual-streaming/multiple-cropped-pips/) | T64: Numbered independent crops, draw-region UI and aspect behavior |
| 125 | [virtual streaming / flip teleprompter](https://betterdisplay.pro/guide/faq/virtual-streaming/flip-teleprompter/) | T65: Physical-source teleprompter flip on extended target |
| 126 | [virtual streaming / integer scaling games](https://betterdisplay.pro/guide/faq/virtual-streaming/integer-scaling-games/) | T66: Nearest-neighbor sampling versus actual whole-factor geometry |
| 127 | [virtual streaming / record with ffmpeg](https://betterdisplay.pro/guide/faq/virtual-streaming/record-with-ffmpeg/) | T67: FFmpeg AVFoundation indices, permissions, audio choice and no HTTP video |
| 128 | [virtual streaming / create recording desktop](https://betterdisplay.pro/guide/faq/virtual-streaming/create-recording-desktop/) | T67: Free virtual presets, recording source selection and disconnect versus delete |
| 129 | [brightness / screenshots and overlays](https://betterdisplay.pro/guide/faq/brightness/screenshots-and-overlays/) | T68: Overlay picker problems, capture exclusion and DisplayLink interactions |
| 130 | [virtual streaming / protected video](https://betterdisplay.pro/guide/faq/virtual-streaming/protected-video/) | T69: No virtual HDCP; supported physical content path and other black-video causes |
| 131 | [virtual streaming / recording scale](https://betterdisplay.pro/guide/faq/virtual-streaming/recording-scale/) | T02: Virtual logical/backing recording size and fixed 2× scale |
| 132 | [virtual streaming / mirroring notifications](https://betterdisplay.pro/guide/faq/virtual-streaming/mirroring-notifications/) | T69: OS-wide notification allowance while mirroring/sharing |
| 133 | [virtual streaming / pip capture exclusion](https://betterdisplay.pro/guide/faq/virtual-streaming/pip-capture-exclusion/) | T68: Own-PiP recursion exclusion versus external-recorder visibility |
| 134 | [virtual streaming / hdmi dummy plug](https://betterdisplay.pro/guide/faq/virtual-streaming/hdmi-dummy-plug/) | T43: Software virtual versus HDMI dummy/emulator and stable identity limits |
| 135 | [virtual streaming / portrait airplay](https://betterdisplay.pro/guide/faq/virtual-streaming/portrait-airplay/) | T70: AirPlay extended setup, portrait rotation and lock-screen constraints |
| 136 | [virtual streaming / remote click offset](https://betterdisplay.pro/guide/faq/virtual-streaming/remote-click-offset/) | T70: Remote click offsets, layout comparison and client-coordinate evidence |
| 137 | [virtual streaming / hidden login screen](https://betterdisplay.pro/guide/faq/virtual-streaming/hidden-login-screen/) | T70: Lock visibility versus disconnect/reconnect policies and retained definitions |
| 138 | [virtual streaming / portrait sidecar](https://betterdisplay.pro/guide/faq/virtual-streaming/portrait-sidecar/) | T70: Portrait Sidecar creation, rotation, permission, cursor and iPad orientation |
| 139 | [brightness / hdr adjustment shortcuts](https://betterdisplay.pro/guide/faq/brightness/hdr-adjustment-shortcuts/) | T22: Idempotent HDR/SDR Shortcuts, explicit values and suspension scope |

## Topics

### T01 Scaling and related FAQ navigation — [page 1](https://betterdisplay.pro/guide/faq/scaling/), [page 2](https://betterdisplay.pro/guide/faq/display-modes/), [page 3](https://betterdisplay.pro/guide/faq/refresh-rates/), [page 4](https://betterdisplay.pro/guide/faq/edid/), [page 5](https://betterdisplay.pro/guide/faq/brightness/), [page 6](https://betterdisplay.pro/guide/faq/hdr/), [page 7](https://betterdisplay.pro/guide/faq/color/), [page 8](https://betterdisplay.pro/guide/faq/ddc/), [page 9](https://betterdisplay.pro/guide/faq/tv-controls/), [page 10](https://betterdisplay.pro/guide/faq/connections/), [page 11](https://betterdisplay.pro/guide/faq/display-disconnection/), [page 12](https://betterdisplay.pro/guide/faq/wake/), [page 13](https://betterdisplay.pro/guide/faq/layouts/), [page 14](https://betterdisplay.pro/guide/faq/virtual-streaming/), [page 15](https://betterdisplay.pro/guide/faq/streaming/), [page 16](https://betterdisplay.pro/guide/faq/recording/), [page 17](https://betterdisplay.pro/guide/faq/remote-displays/)

- **BetterDisplay behaviour** (Free/Pro: landing pages do not grant entitlements): The 17 category pages organize HiDPI/desktop size; modes; refresh rates; EDID/system configuration; brightness; HDR/XDR; color; DDC/inputs; TV control; detection/hardware; disconnection; wake/startup; layouts; virtual screens/mirroring; streaming/PiP; recording/sharing; and remote displays. These are navigation pages, not 17 additional control panels. The TV page also directs users to verify HDMI-CEC volume, power and input commands before binding native keys or separate standby/wake Shortcuts. Live category summaries additionally distinguish missing native modes from a Pro purchase, physical connection limits from software features, HDMI signal capture from desktop capture, display groups from connection presets, and Universal Control device placement from display layout.
- **FreeDisplay today**: 🟡 Partial. Settings routes to Displays, Arrange, Scenes, Virtual Displays, Capture, EDID/HiDPI, Automation and Health at `Apps/OpenDisplay/Sources/SettingsView.swift:35`; the tray exposes per-display controls and recovery notices at `Apps/OpenDisplay/Sources/MenuBarView.swift:30`. There is no corresponding troubleshooting navigation or end-to-end CEC setup; `Apps/OpenDisplay/Sources/LocalControlPanel.swift:35` explicitly excludes TV/AV/CEC protocols. Live category links to articles outside this manifest remain cross-references, not evidence that their complete contents were reviewed here.
- **Implementation notes**: S, public SwiftUI/AppKit help links and capability-based navigation. Preserve the distinction between a control reference and a diagnostic tutorial.
- **Acceptance criteria**:
  - Every category leads to relevant help and actual supported controls, including a clear unavailable state.
  - Automation setup identifies the controller and target before offering key bindings.

### T02 Desktop, framebuffer, panel pixels and accurate scale explanations — [page 18](https://betterdisplay.pro/guide/faq/scaling/macos-scaling-hidpi-lodpi/), [page 22](https://betterdisplay.pro/guide/faq/scaling/larger-text/), [page 26](https://betterdisplay.pro/guide/faq/scaling/resolution-percentage/), [page 28](https://betterdisplay.pro/guide/faq/scaling/check-hidpi/), [page 29](https://betterdisplay.pro/guide/faq/scaling/pixel-perfect-photo-editing/), [page 77](https://betterdisplay.pro/guide/faq/scaling/gamma-test-pattern/), [page 131](https://betterdisplay.pro/guide/faq/virtual-streaming/recording-scale/)

- **BetterDisplay behaviour** (Free for selecting existing modes; custom-size Free and flexible-scaling Pro distinctions are explicit in linked FAQs): Logical points determine workspace and UI size; LoDPI ordinarily renders one pixel per point per axis, HiDPI two. At 2560×1440 logical size this means 2560×1440 versus 5120×2880 rendering, about 3.7 versus 14.7 million pixels. Native panel pixels and cable signal dimensions are separate quantities. On a 4K panel, 1920×1080 HiDPI can map directly; 2560×1440 HiDPI is rendered at 5K then reduced. Fractional output scaling retains a 2× backing scale. Screenshots can record the larger backing image without proving a larger cable signal.
  Smaller logical dimensions enlarge the desktop interface; larger ones add workspace. Each screen can differ, but applications on one desktop share its scale; application zoom changes only that application's content. Existing mode switches need no reboot; installing overrides may. A 2560×1440 HiDPI starting point on a 27/32-inch 4K display is a suggestion, not an optimum. On QHD, intermediate HiDPI sizes can help readability; same-size supersampling can look smoother or softer and cannot increase physical PPI. Low-resolution bitmaps gain no detail. macOS grayscale font smoothing differs from former subpixel smoothing, removed at Mojave; fractional resizing also disrupts subpixel alignment.
  The ordinary resolution percentage uses the default logical width as its baseline: 3840 wide versus a 1920 default can read 200% in either density class. Portrait swaps dimensions; the baseline is display-specific. Inspect the highlighted Display Mode row's sparkle for active HiDPI; another listed HiDPI row proves nothing. Photo inspection requires rendering dimensions equal to panel pixels, native signal, no later rescaling and application pixel zoom (Photoshop 100%). A line-based gamma pattern must likewise be unresized at native LoDPI with browser zoom, profile, HDR and monitor settings controlled; a resampled pattern is not a calibration measurement.
  Virtual HiDPI is fixed at 2×: 1080p logical → 4K, 1440p → 5K, 4K → 8K backing. Reported diagonal cannot create 3×/4× scaling. For an 8K recording with larger content, enlarge it inside the application; the recorder may independently resize its output.
- **FreeDisplay today**: ✅ Logical/framebuffer/HiDPI labeling and exact mode comparison exist in `Packages/DisplayDomain/Sources/DisplayDomain/DisplayModeChoices.swift:44` and `Apps/OpenDisplay/Sources/AppModel.swift:1058`; the current mode is visible without switching. 🟡 Partial educational coverage: `Apps/OpenDisplay/Sources/DisplayDetailView.swift:91` explains scaling, but there is no percentage/magnification model or reliable connection-level signal inspector. The virtual bridge halves logical dimensions for HiDPI at `Providers/VirtualDisplayProvider/Sources/VirtualDisplayRuntime.m:54`. Its capture preview downsizes to a 1920-pixel longest edge (`Apps/OpenDisplay/Sources/CapturePanel.swift:75`), so it is not an 8K recorder.
- **Implementation notes**: S/M, public CoreGraphics mode data, AppKit screen metrics and explicit unknown transport fields. Treat native flags as reported metadata, not measured optical sharpness. Avoid silently deriving cable timing from framebuffer size.
- **Acceptance criteria**:
  - Show logical, backing and available transport dimensions separately; absent transport data stays unknown.
  - Same logical size in two density classes is distinguishable; a 5K screenshot on a 4K monitor is never labeled a 5K connection.
  - Explain 2× capture dimensions, application zoom, performance and panel limitations with the examples above.

### T03 Adding native HiDPI choices, rendering limits and DisplayLink — [page 19](https://betterdisplay.pro/guide/faq/scaling/add-hidpi-resolutions/), [page 20](https://betterdisplay.pro/guide/faq/scaling/hidpi-resolution-limits/), [page 21](https://betterdisplay.pro/guide/faq/scaling/displaylink-scaling/)

- **BetterDisplay behaviour** (Free: individual custom scaled sizes; Pro: flexible generation and in-app mirroring/streaming): In Settings → Displays → selected display → System Configuration and Flexible Scaling, first enable model configuration editing. Flexible scaling generates fine steps at the native aspect ratio; Custom scaled resolutions → Add Custom Resolution accepts desired logical width/height and requests both density variants without requiring doubled input. Apply installs pending edits with helper/admin authorization, then activation/restart occurs if requested. Adding a row neither applies nor selects a mode. Rows distinguish available HiDPI, LoDPI-only and unavailable sizes.
  Reported horizontal GPU/allocation limits appear only when supplied under Display Information → Capabilities. HiDPI can exceed those limits even when native output works: 3840×1080 needs 7680×2160 backing; 5120×1440 needs 10240×2880. Compare smaller modes, ports, direct cables and arrangements; Pro and bandwidth do not remove rendering limits. The global Advanced Display Settings option for sub-720p resolutions removes the app's lower bound; accepting reconnect cycles all connected virtual screens. macOS can still reject a tiny listed HiDPI mode and revert it.
  A virtual source provides an alternative, not an upgrade to native limits. Rendering dimensions above 7680 require the per-virtual over-8K option unless globally enabled; 4608×1920 HiDPI needs 9216×3840 backing. Test artifacts and wake recovery.
  DisplayLink's driver supplies its modes; the native editor is inapplicable even on a USB-C dock. Ports on one dock may use different transports. Direct native video is an alternative subject to the Mac's display-count limits. A matched-aspect virtual source can be mirrored through macOS for free, or via BetterDisplay Pro, or streamed with Pro and Screen Recording permission. Creation alone does not present the source. Layout protection repairs position, not frozen capture; indirect DDC is experimental.
- **FreeDisplay today**: 🟡 Partial. Existing modes work, but the custom-size pane only exports a plan (`Apps/OpenDisplay/Sources/AdvancedDisplayToolsView.swift:50`; `Packages/TopologyCore/Sources/TopologyCore/DisplayConfigurationTools.swift:85`). No installer, availability status, flexible generator, allocation-limit inspector or DisplayLink-specific controller is present. Virtual validation limits each dimension to 8192 and refresh to 120 (`Packages/DisplayDomain/Sources/DisplayDomain/VirtualDisplayDefinition.swift:22`), with one requested mode, not generated lists.
- **Implementation notes**: M for public discovery/help; L for privileged model overrides or private virtual mode generation. Keep planned, installed, activated and observed states separate. Never offer native override installation on driver-managed routes.
- **Acceptance criteria**:
  - A custom logical row never claims success until installation, activation and enumeration confirm availability.
  - DisplayLink is identified per output; Pro-like features cannot be presented as removing OS limits.
  - Low-resolution and oversized-mode opt-ins explain disruption and retain a working return mode.

### T04 Clarity and sustained performance troubleshooting — [page 24](https://betterdisplay.pro/guide/faq/scaling/text-still-poor/), [page 25](https://betterdisplay.pro/guide/faq/scaling/hidpi-performance/)

- **BetterDisplay behaviour** (Pro only for the suggested streamed alternative): Confirm the current HiDPI row, disable monitor sharpening/AI/picture enhancements temporarily, and inspect chroma subsampling. Monitor picture mode and ICC profile are different. Compare panel-matched rendering against fractional scaling before blaming hardware. An alternative is native LoDPI on the physical target plus a matched-aspect HiDPI virtual source streamed onto it; this changes resampling, needs capture permission and can add latency. A screenshot cannot show the panel's pixel structure or its processing.
  At equal logical dimensions HiDPI has four times the pixels and buffer storage at equal format, but not necessarily four times total cost. Compare density with recording off and on, smaller HiDPI desktops, lower application viewport quality, and lower recorder resolution/FPS. Compare mirroring with streaming when filters/crop/rotation are unnecessary. For delayed pointers compare no virtual presentation and another input device at the same mode. High reported refresh does not measure input latency. Oversized virtual modes may flash or corrupt; compare smaller sizes. Compare CPU and GPU separately, identical workloads and menu/Settings open versus closed; Reduce transparency may affect UI GPU cost. Quitting the app does not necessarily restore a selected mode.
- **FreeDisplay today**: 🟡 Partial. Exact modes and an SDR capture path are available; capture performs frame materialization and transforms on the main delivery path at `Apps/OpenDisplay/Sources/CapturePanel.swift:151`. There is no controlled comparison workflow, capture FPS control, performance telemetry, or full-screen stream. Hardware performance is unverified.
- **Implementation notes**: S for diagnostic guidance, M for capture instrumentation using public ScreenCaptureKit/Metal. Report dropped frames and actual output dimensions separately from declared mode rate.
- **Acceptance criteria**:
  - Diagnostics record modes, transport, capture settings, CPU/GPU comparison conditions and menu visibility.
  - Capture load comparisons use equivalent sources and distinguish repeat frames, input latency and refresh declarations.

### T05 Resolution slider filtering, percentage modes and bounds — [page 27](https://betterdisplay.pro/guide/faq/scaling/magnification-percentage/), [page 35](https://betterdisplay.pro/guide/faq/scaling/missing-mode-list/), [page 36](https://betterdisplay.pro/guide/faq/scaling/limit-resolution-slider/)

- **BetterDisplay behaviour** (Pro for flexible scaling if more modes are needed; slider setting tier unspecified): Settings → Menu can replace the resolution slider's size interpretation with magnification. Keep percentage display and native-aspect-only filtering enabled, with at least 12 eligible modes. Higher magnification means larger UI; the label still says Resolution and uses a magnifying-glass icon. Exact percentages such as 125% require a corresponding mode; virtual references derive from their mode list.
  Display Mode → Filter offers refresh, HiDPI/LoDPI, aspect and bit-depth criteria plus Show All. Filtering does not change the current mode or create absent ones; Show All includes unsafe/invalid entries, while the sub-720p restriction remains independent. The resolution slider preserves current refresh, depth and generally density. Under per-display Additional Settings, enable slider/keyboard range limits and set independent minimum/maximum width/height; blank bounds are unrestricted, minimum must be below maximum, and current mode remains visible outside bounds. Generated flexible-scaling range and everyday slider filtering are separate.
- **FreeDisplay today**: 🟡 Partial. Tray has a discrete release-to-apply slider and native-aspect filtering (`Apps/OpenDisplay/Sources/MenuBarView.swift:346`; `Apps/OpenDisplay/Sources/TrayModeCatalog.swift:93`), plus a show-all-variants switch at `Apps/OpenDisplay/Sources/MenuBarView.swift:542`. Settings uses a separate density filter at `Apps/OpenDisplay/Sources/DisplayDetailView.swift:110`. Missing: percentage/magnification, independent filters, sub-720p policy, per-display bounds and keyboard-range parity. **P0:** tray representatives favor native/default and HiDPI before matching refresh (`Apps/OpenDisplay/Sources/TrayModeCatalog.swift:83`), so a size-only adjustment can change density/rate even when a preserving candidate exists. Tray Show All is still limited to GUI-usable modes at `Apps/OpenDisplay/Sources/TrayModeCatalog.swift:35`.
- **Implementation notes**: M, public mode metadata and pure filtering. Unify tray/settings catalogs; represent safety flags and full properties before selecting a representative.
- **Acceptance criteria**:
  - Size-only adjustments retain density/rate/depth when available; otherwise explicitly explain the additional change.
  - Bounds retain the current out-of-range mode; invalid bounds are rejected.
  - Percentage visibility obeys the 12-mode/aspect criteria and never invents a mode.

### T06 HiDPI toggles and complete favorite modes — [page 31](https://betterdisplay.pro/guide/faq/scaling/hidpi-toggle-size/), [page 34](https://betterdisplay.pro/guide/faq/scaling/save-favorite-mode/)

- **BetterDisplay behaviour** (Pro: five favorites; custom-size Free/flexible Pro): HiDPI toggling chooses an opposite-density available mode. If no same-size/rate/depth pair exists it may change desktop size; toggling back need not restore the original. Exact Display Mode selection is more predictable. Automation should enumerate current modes before requesting one; a missing combination may receive a nearby match in BetterDisplay.
  Save a selected mode using Display Mode → Favorite modes → Manage → slots 1–5; filled slots replace their old value, and each occupied slot has a remove control. A mode's secondary-click menu can also assign it. Manage provides a keyboard/mouse-compatible alternative if secondary-click instead selects. Favorites store the complete mode and are usable only while that combination remains available.
- **FreeDisplay today**: 🟡 Partial. Tray density switching requires the same logical size, prefers matching rate and hides unavailable counterparts (`Apps/OpenDisplay/Sources/TrayModeCatalog.swift:125`); this conservative difference is acceptable if documented. Favorite stars and selection exist (`Apps/OpenDisplay/Sources/MenuBarView.swift:523`; `Apps/OpenDisplay/Sources/DisplayDetailView.swift:138`) without five-slot management. **P0:** favorite keys round Hz to an integer and omit framebuffer/depth (`Packages/DisplayDomain/Sources/DisplayDomain/FavoriteResolutions.swift:15`), conflating 59.94/60 and other variants; resolution uses the first matching candidate at line 52. Exact apply safeguards at `Apps/OpenDisplay/Sources/AppModel.swift:3099` cannot recover the user's original favorite properties once the key lost them.
- **Implementation notes**: M, public APIs and persistence migration. Store complete semantic mode identity; keep unavailable favorites visible with reasons rather than substituting.
- **Acceptance criteria**:
  - Favorites independently preserve 59.94 and 60 Hz, backing dimensions, density and depth.
  - Toggling an unavailable density pair explains the limitation.
  - Favorites can be saved, replaced and deleted without secondary-click; stale modes never silently select a different variant.

### T07 Physical output timings and very low-resolution CRTs — [page 32](https://betterdisplay.pro/guide/faq/scaling/crt-low-resolution/), [page 33](https://betterdisplay.pro/guide/faq/scaling/physical-output-resolution/)

- **BetterDisplay behaviour** (Pro: EDID application and stream/PiP; low-level connection selector tier unspecified): A smaller logical desktop need not lower the cable signal. Monitor pixel-for-pixel controls act on the incoming signal, not the pre-scaled desktop. Inspect all Display Mode variants and monitor OSD after selection; a working physical timing may be fixed or VRR. An Unsafe marker is a safety flag, not an unscaled-output label.
  On a supported Apple-silicon route, CLI connectionModeListAll and connectionMode queries enumerate physical timing IDs and save the current ID; setting an offered ID can enable 640×480 when ordinary desktop selection cannot. The desktop may remain larger and be cropped. Keep a working screen and restore ID. Content may be placed in the visible region through PiP/stream using 1:1 mapping and top-left alignment; account for HiDPI backing size. The adapter and receiving CRT must accept the timing.
  A prepared EDID can advertise supported timing on compatible routes but can interrupt output. Native-size editing is not a substitute. Streaming a smaller 1:1 image is a different workaround that leaves transport timing intact and adds latency.
- **FreeDisplay today**: ⬜ Missing connection-level timing enumeration/set and CRT placement. Public mode selection exists at `Apps/OpenDisplay/Sources/AppModel.swift:3081`; information at line 1058 contains logical/backing sizes, not measured output. EDID export-only UI is explicit at `Apps/OpenDisplay/Sources/AdvancedDisplayToolsView.swift:37`. PiP fits proportionally, without top-left 1:1 controls (`Apps/OpenDisplay/Sources/CapturePanel.swift:131`).
- **Implementation notes**: L, private framebuffer/connection SPI for timing changes; public CoreGraphics cannot be assumed to expose the same connection-level inventory. Add rollback and signal recovery first.
- **Acceptance criteria**:
  - Save and restore the original physical timing; verify receiving-device signal independently.
  - A 640×480 signal with a larger desktop is labeled cropped, not a complete 640×480 desktop.

### T08 Hardware Picture-by-Picture and native-dimension overrides — [page 37](https://betterdisplay.pro/guide/faq/scaling/hardware-pbp/), [page 44](https://betterdisplay.pro/guide/faq/scaling/edit-native-resolution/)

- **BetterDisplay behaviour** (Pro for flexible scaling/EDID application; model-editor entitlement otherwise unspecified): Hardware PBP uses multiple real inputs. Some monitors change EDID when entering PBP, others expose both sets of modes without a distinct event. Activate the monitor's layout first and select a supported timing for each input. A vertical split of a 3840×2160 panel gives each input 1920×2160, aspect 8:9. HDMI and DisplayPort may expose different split timings.
  Edit native panel pixel resolution changes scaling assumptions, not hardware pixels or physical timing. Use it to correct a bad report or PBP input geometry, not to enlarge workspace or invent a higher-resolution panel. Incorrect tiny values can ruin the generated list; current reported dimensions remain unchanged until Apply and activation. Advertising fictitious 8K may produce unusable output. For PBP, enable model editing and native-size editing, enter the input-region geometry, Apply, and generate flexible sizes from that aspect. Recheck overrides on return to full-panel mode and matching model identities.
  Prepared split-layout EDID must suit that monitor/state. A custom DDC feature can switch PBP only with verified model-specific command/values; it does not also choose macOS resolution. Software PiP regions remain windows over an underlying desktop and are not hardware inputs.
- **FreeDisplay today**: ⬜ Missing native-size editor and composed PBP workflow. Raw custom VCP commands are available in `Tools/opendisplay/Sources/main.swift:759`, but no saved model-specific PBP feature or coordinated mode switch. The export plan only doubles logical sizes (`Packages/TopologyCore/Sources/TopologyCore/DisplayConfigurationTools.swift:85`).
- **Implementation notes**: L, privileged model overrides plus private IOAVService DDC; M for a profile combining verified raw command and existing CoreGraphics mode. Keep per-input scope explicit.
- **Acceptance criteria**:
  - Two 1920×2160 input areas are configured independently and full-panel settings can be restored.
  - A PBP command does not claim to establish the right Mac timing.
  - Invalid native geometry is recoverable without inventing hardware capabilities.

### T09 Protecting resolution, HDR status and separate SDR/HDR formats — [page 38](https://betterdisplay.pro/guide/faq/scaling/protection-allows-app-changes/), [page 64](https://betterdisplay.pro/guide/faq/brightness/keep-hdr-enabled/), [page 80](https://betterdisplay.pro/guide/faq/brightness/keep-color-mode/)

- **BetterDisplay behaviour** (Pro): Select a working value first, then enable per-display App Menu → Configuration Protection. Resolution stores the desktop mode; HDR Status stores on/off; Color Mode and HDR Color Mode separately store non-HDR/HDR connection encoding, range and depth; HDR Color Profile is separate again. Display saved values beneath switches. Deliberate changes in BetterDisplay update protected values instead of being blocked. External changes may be restored while the app runs and the display is connected; no protection creates missing modes or guarantees incompatible combinations. Disable protection to retain outside changes.
  Color-format protection requires Apple-silicon connection information; wake/docks may remove a saved format. Inspect live lists, optionally reinitialize/reset the relevant adapter, and avoid switching when already matched. Restoring a format can briefly blank output. Default resolution editing does not make a system-wide format default effective with the app closed. After HDR restoration macOS Settings can display stale values; revisit the pane rather than toggling HDR merely to refresh it.
- **FreeDisplay today**: 🟡 Partial layout protection, not equivalent per-property configuration protection. `Packages/TopologyCore/Sources/TopologyCore/LayoutProtection.swift:22` defines debounce, self-change suppression and retry limits; `Apps/OpenDisplay/Sources/AppModel.swift:3763` integrates wake restoration. There are no HDR status, connection color-format or separate HDR profile fields/controllers; advanced HDR UI only reads EDR (`Apps/OpenDisplay/Sources/AdvancedDisplayToolsView.swift:24`). Missing explicit protected-value UI and availability-driven restore for these properties.
- **Implementation notes**: M for public mode protection; L/private for connection/HDR controls. Extend the state model rather than treating ICC profiles or EDR boost as HDR state.
- **Acceptance criteria**:
  - Own manual changes update protected values; unavailable modes suspend restoration with a reason.
  - SDR/HDR format and profile states remain distinct.
  - Wake restores only mismatches, respects recovery priority and bounds retries.

### T10 Refresh-rate evidence, HiDPI cost and VRR flicker — [page 39](https://betterdisplay.pro/guide/faq/scaling/hidpi-refresh-rate/), [page 40](https://betterdisplay.pro/guide/faq/scaling/refresh-rate-disagrees/), [page 68](https://betterdisplay.pro/guide/faq/brightness/hdr-vrr-flicker/)

- **BetterDisplay behaviour** (Pro for protection; additional-rate selector entitlement unspecified): Compare complete logical/backing/density/rate combinations; choosing the same size at a higher rate may switch to LoDPI. A 3008×1692 HiDPI desktop needs 6016×3384 rendering even with 4K output. Multi-display/dock arrangements can change limits. Try smaller HiDPI modes, lower rates and direct connections.
  Refresh Rate separates ordinary mode rates (dial icon) from additional connection rates (waveform), including fractional and fixed/variable options. Sometimes select a working lower-rate HiDPI mode first, then a connection-level rate. This cannot create missing HiDPI sizes and can corrupt colors or blank output; save a known-working mode. macOS Settings can retain the ordinary-mode rate after a connection override. Confirm the monitor's OSD, not a blink/menu checkmark. Option-opening Refresh Rate exposes a timing reporter; distinguish VRR range from current timing. Mode changes can lose an additional rate unless protected.
  For HDR-upscaling scroll flicker, compare a supported fixed rate with unchanged other settings and inspect monitor Game Mode/VRR. If it persists, compare upscaling methods and retain monitor/path/state evidence.
- **FreeDisplay today**: 🟡 Partial. Tray rate choices preserve logical/backing/density through `Apps/OpenDisplay/Sources/TrayModeCatalog.swift:113`; selection uses timed verified apply at `Apps/OpenDisplay/Sources/AppModel.swift:3081`. No waveform group, connection-rate setter, VRR range model or timing reporter. Built-in software XDR boost exists but does not control external HDR/VRR.
- **Implementation notes**: M for public mode metadata/reporting; L/private for connection-level overrides. Measurement and advertised rates need separate fields.
- **Acceptance criteria**:
  - Changing rate shows any density/depth change before applying.
  - Logs distinguish nominal mode Hz, connection rate, VRR range and measured presentation.
  - A failing additional rate returns to a working ordinary mode; fixed-rate comparison leaves other variables unchanged.

### T11 Virtual refresh rates and mirror-target mode controls — [page 41](https://betterdisplay.pro/guide/faq/scaling/virtual-refresh-rate/)

- **BetterDisplay behaviour** (Pro): Virtual settings → Custom refresh rate list → Add Refresh Rate accepts 24–240 Hz; default modes are 60 Hz. Retain 60 as fallback, reconnect to rebuild the virtual display, then select the intended size/rate. Reconnect temporarily removes its desktop. A 120-Hz virtual declaration, browser counter or mirrored state does not prove 120 distinct frames reach the monitor. Physical output support and Mac/OS/capture limits still apply; compare 60 at equal size for stutter or artifacts.
  Mirroring can alter target rates/VRR. Settings → Menu → Allow resolution change for mirror target displays reveals separate target menus and permits resolution/refresh protection there. Only already offered VRR is selectable; recheck after reconnect.
- **FreeDisplay today**: 🟡 Partial. Virtual UI offers 30/60/120 with 60 default (`Apps/OpenDisplay/Sources/VirtualDisplaysSettingsView.swift:16`, line 37); schema accepts one 24–120 Hz value, not a list (`Packages/DisplayDomain/Sources/DisplayDomain/VirtualDisplayDefinition.swift:25`), and runtime installs one mode (`Providers/VirtualDisplayProvider/Sources/VirtualDisplayRuntime.m:58`). PiP is fixed at 30 FPS (`Apps/OpenDisplay/Sources/CapturePanel.swift:78`). Tray hides its resolution slider for non-main mirror targets (`Apps/OpenDisplay/Sources/MenuBarView.swift:360`), without the guide's override.
- **Implementation notes**: L/private CGVirtualDisplay for mode lists; M/public presentation instrumentation. Do not increase accepted rates without checking platform capability.
- **Acceptance criteria**:
  - Rebuilt definitions preserve a 60-Hz fallback and report actual offered modes.
  - UI separates virtual nominal rate, capture target FPS and delivered physical frames.
  - Target-mode editing is opt-in and recoverable.

### T12 Mode-dependent HDR and forced HDR — [page 42](https://betterdisplay.pro/guide/faq/brightness/hdr-hidpi-modes/)

- **BetterDisplay behaviour** (Pro for forced HDR/protection): HDR availability depends on the complete size, HiDPI, refresh and connection combination. Compare lower rate or smaller HiDPI size first. On supported Apple-silicon connections, Color Mode → Allow Forced HDR exposes additional options; it does not itself enable HDR. Then use the HDR switch (marked Forced where applicable) or a forced color format. Recheck resulting size/rate. Green, corrupted or blank output is possible; return to a working mode. It cannot create HDR in SDR hardware or remove bandwidth/rendering limits. Once verified, protect HDR Status, Refresh Rate and optionally Resolution; test wake and monitor input switching, checking updated protected values.
- **FreeDisplay today**: ⬜ Missing hardware HDR/forced HDR controls and protection. `Apps/OpenDisplay/Sources/AdvancedDisplayToolsView.swift:29` reports current/potential EDR explicitly without claiming hardware HDR; `Apps/OpenDisplay/Sources/AppModel.swift:785` limits XDR boost to eligible built-in screens.
- **Implementation notes**: L/private display connection/SkyLight-family SPI, with per-OS probes. EDR metadata and a Metal EDR window are not replacements for transport HDR switching.
- **Acceptance criteria**:
  - Separate allow-override and enable-HDR states; unsupported screens offer neither.
  - Confirm effective HDR/format/size/rate after switching and recover on timeout.
  - Protection is offered only after a working combination is verified.

### T13 Model-wide configuration, per-display labels and multiple users — [page 43](https://betterdisplay.pro/guide/faq/scaling/shared-model-settings/), [page 50](https://betterdisplay.pro/guide/faq/scaling/multiple-user-overrides/)

- **BetterDisplay behaviour** (Free/Pro varies by edited property): System overrides are shared by vendor/model, even for distinct physical units and user accounts. Native/default resolution, scaling generation, system name and TV/computer role belong to that scope. Changing app identification to UUID matching, resetting/forgetting a record or assigning an alias does not make a model override unit-specific. Show scope before Apply, including matching monitors connected later. Per-display Additional Settings → Custom displayed name changes only BetterDisplay's label; reliable identity is still needed.
  User preferences remain per-account. Another account's Apply can replace the Mac-wide override; account switching alone does not. Prefer one managing account, reapply its intended configuration when necessary and complete activation. Protection cannot recreate modes removed by the replacement override.
- **FreeDisplay today**: 🟡 Partial. App aliases and registry matching exist (`Apps/OpenDisplay/Sources/AppModel.swift:604`; `Apps/OpenDisplay/Sources/DisplayDetailView.swift:566`). Exported EDID property lists use vendor/product identifiers (`Packages/TopologyCore/Sources/TopologyCore/DisplayConfigurationTools.swift:58`); no installation editor or shared-state conflict detection exists.
- **Implementation notes**: M for identity/scope preview, L for privileged shared overrides. Store installed configuration provenance and distinguish user pending edits from system state.
- **Acceptance criteria**:
  - Editing two identical monitors warns that the system override affects both; alias changes stay app-local.
  - Cross-account replacement is visible and reversible; merely signing in does not install staged edits.

### T14 Temporary EDID loading, application, identity continuity and recovery — [page 45](https://betterdisplay.pro/guide/faq/connections/edid-reapplied/), [page 46](https://betterdisplay.pro/guide/faq/scaling/import-custom-edid/)

- **BetterDisplay behaviour** (Pro for application/automatic application): Settings → Displays → selected screen → Display EDID → Load Custom EDID → Load EDID Data imports a prepared binary, saves it and displays interpreted data/warnings without applying. The loader is not a timing-field editor. Apply Custom EDID Now requires a connected external Apple-silicon display with an accessible framebuffer; confirm Apply EDID. A software override changes what macOS sees, not monitor memory, and cannot create a connection macOS does not detect.
  Timings must work across Mac, adapter and receiver; two overridden video processors are not automatically a frame-locked tiled wall. Identity-changing vendor/product/serial values can create a different saved record. An old record's automatic-on-detection rule may keep reapplying even after resetting the new record. Enable offline records in Displays Overview, disable that original rule, then Reset Factory EDID (Unapply) on the connected display. Loading another file alone does not undo an automatic rule.
  Preserve continuity in case of an EDID display identity change tracks original/alternate identities within the app session. Keep factory restoration on quit enabled when appropriate. For broken output physically reconnect; hold Shift at app launch to suppress automatic EDID application in safe mode. Export preferences before broad resets. Hardware Write EDID is a separate, unnecessary operation for software testing.
- **FreeDisplay today**: 🟡 Partial import validation/export, ⬜ application and continuity. `Apps/OpenDisplay/Sources/AdvancedDisplayToolsView.swift:64` loads and validates but `Apps/OpenDisplay/Sources/AdvancedDisplayToolsView.swift:47` explicitly states no installation; no apply/unapply, automatic rule, original/alternate identity or factory-on-quit machinery exists.
- **Implementation notes**: L/private framebuffer SPI. Keep binary storage, validation, activation and device writing separate. Persist an unapply journal before any identity-changing action and never infer successful recovery from request acceptance.
- **Acceptance criteria**:
  - Import has no display side effect; application names the target and retains factory data.
  - Reapplying rules can be located across alternate/offline identities.
  - Safe startup suppresses auto-apply; reconnect/unapply and quit restoration are exercised on supported hardware.

### T15 EDID retrieval, DisplayID blocks and physical-write claims — [page 47](https://betterdisplay.pro/guide/faq/scaling/edid-write-result/), [page 48](https://betterdisplay.pro/guide/faq/connections/displayid-extension/)

- **BetterDisplay behaviour** (Pro for software override; retrieval/hardware-write tier unspecified): Retrieve EDID defaults to OS managed (recommended), then Export EDID Data. Retrieval/overrides support extension blocks beyond the 128-byte base; validate file size and extension completeness because a valid base can accompany missing extensions. The EDID report decodes supported DisplayID timings/tiles, flags incomplete blocks and can compare OS data with direct device data. macOS need not support every advertised feature.
  Hardware writing has a separate 256-byte limit. A successful send only proves no reported communication failure, not durable storage or usable output. Reconnect and compare the reported binary with the intended bytes. Many monitors reject writes; some dongles/emulators accept them. A physical rewrite can permanently break a device and is not undone by reconnect. Preserve original bytes and never use it merely to test a software override.
- **FreeDisplay today**: 🟡 Partial. Import validates 128-byte multiples, extension count, all checksums and a 32768-byte ceiling, retaining uninterpreted extensions (`Packages/TopologyCore/Sources/TopologyCore/DisplayConfigurationTools.swift:28`). CLI prints base EDID details and exports raw data (`Tools/opendisplay/Sources/main.swift:822`); no DisplayID decoder, selectable direct retrieval or device writer exists. **P0:** retrieval matches product code alone, then falls back to tree order (`Providers/CoreGraphicsProvider/Sources/CoreGraphicsProvider/EDIDReader.swift:17`), which can attribute another identical or unrelated monitor's EDID to the selected display.
- **Implementation notes**: M/public IOKit for safe binding, validation and decoding; L/high-risk device I2C writing, best deferred. Report ambiguity rather than choosing the first EDID.
- **Acceptance criteria**:
  - Same-product monitors with different serials return their own EDID or an explicit ambiguity.
  - Export preserves complete supported extensions; incomplete blocks are reported.
  - Send, readback, durable write and physical operation are separate result states.

### T16 Pending configuration, authorization and activation states — [page 49](https://betterdisplay.pro/guide/faq/scaling/apply-configuration-fails/)

- **BetterDisplay behaviour** (entitlement depends on edited feature): Apply installs all pending model edits. Failure or cancelled authorization leaves the red Apply/Undo state pending; successful installation followed by required activation/reboot is a different state. Review every staged model first. The privileged helper requests normal authorization; Shift-Apply chooses the administrator prompt path and helper failure can fall back to it. Neither bypasses permissions. Undo discards pending edits.
  Troubleshooting uses Tools → Show Console → Logging, one reproduced attempt and the full error message. Helper failure, user cancellation and script errors must remain distinguishable; an error number alone is insufficient. Logging diagnoses rather than repairs the failure. Avoid broad resets before locating the failed component. After installation/activation, inspect actual Display Mode availability.
- **FreeDisplay today**: ⬜ Missing installer lifecycle. `Apps/OpenDisplay/Sources/AdvancedDisplayToolsView.swift:87` only saves exported artifacts. The similarly named Apply in `Apps/OpenDisplay/Sources/DisplayDetailView.swift:202` applies an existing mode through a timed revert flow, not a pending model override.
- **Implementation notes**: L, public authorization/service-management building blocks plus undocumented override format/integration risk. Use explicit staged/install/activate/observe phases and transactional backup.
- **Acceptance criteria**:
  - Cancelled authorization retains pending edits and never reports installed.
  - Install success without activated modes is visible separately.
  - Undo changes only staged data; mode Apply is not confused with system configuration Apply.

### T17 Restoration policies, full dimming and saved controls — [page 51](https://betterdisplay.pro/guide/faq/brightness/restore-full-dimming/), [page 61](https://betterdisplay.pro/guide/faq/brightness/startup-restoration/)

- **BetterDisplay behaviour** (tier unspecified): Startup/wake restoration is configured under Displays → Overview → Software XDR/HDR Upscaling and Dimming → Brightness Upscaling and Dimming Settings → On startup & wake. Restoring combined brightness/software adjustments is distinct from allowing restoration to complete darkness. Full dimming is normally avoided. The additional Apple-display option to restore excessive dimming is **off by default**; enabling it permits restoration below the brightness reported during startup, even though transitional hardware readings can be inaccurate.
  The global “do not restore” policy also suppresses saved ranged/on/off DDC settings and may clear stored restoration values. Restoring only non-brightness adjustments preserves appropriate DDC restoration while omitting software and combined brightness. These preferences are not automatically per-topology presets; group synchronization, mirroring, native auto brightness and other apps can subsequently change the result. For an external-only desktop, Pro soft disconnection may better express the intent than a black but connected internal screen.
- **FreeDisplay today**: 🟡 Partial. Brightness state and software methods exist at `Apps/OpenDisplay/Sources/AppModel.swift:1280` and `Apps/OpenDisplay/Sources/AppModel.swift:1374`; wake processing at `Apps/OpenDisplay/Sources/AppModel.swift:3763` refreshes topology and reasserts layout. It does not implement this restoration-policy matrix, full-dim exceptions or startup DDC replay. Current software limits are fixed in `Packages/TopologyCore/Sources/TopologyCore/Dimming.swift:20`.
- **Implementation notes**: M, persistent policy and public lifecycle notifications, with private/native/DDC controller risks. Save user intent separately from transient observations. Stage restoration until identity and controller readiness are known; preserve a recoverable visible screen.
- **Acceptance criteria**:
  - Independently exercise no restore, non-brightness-only and full restore after launch, reconnect and wake.
  - Full-black restoration requires its own explicit setting; Apple excessive-dim restoration initially remains disabled.
  - Saved settings, competing group changes and the final observed controller state are distinguishable.

### T18 Combined brightness, hardware floors and software zero — [page 54](https://betterdisplay.pro/guide/faq/brightness/monitor-percentage-mismatch/), [page 55](https://betterdisplay.pro/guide/faq/brightness/dim-below-hardware-minimum/), [page 59](https://betterdisplay.pro/guide/faq/brightness/software-dimming-floor/)

- **BetterDisplay behaviour** (combined controls: tier unspecified; configurable hardware minimum: Pro): Hardware, software and combined percentages are separate scales, not nits. Combined brightness coordinates software darkening, a hardware operating range and supported upscaling through defined transition points. Device Control can disable combined behavior to expose a hardware-only scale. DDC limits are configurable and need not be 0–100; a device may use 0–50. Turning off the DDC controller in Add/Remove Controllers also removes its input/volume controls, while retaining its configuration and other controller types.
  To dim below a hardware floor, enable a working hardware controller, software video adjustments and combined brightness; set the hardware minimum under Image Adjustment Settings. Below that point, lower the image in software while holding the hardware floor. This is useful when a monitor flickers at low backlight levels, but does not measure flicker or guarantee power savings. Sidecar offers image darkening, not control of the iPad backlight. HDR, picture presets or low-blue modes can lock hardware writes even when reads work; changing the numeric range cannot unlock them.
  In Device Control → Image Adjustments → Image Adjustment Settings, software-based video adjustments must be enabled before Redefine 0% software brightness level appears. A configurable software value corresponding to slider zero can preserve a faint image (for example 10%). It is independent of the hardware floor. A separate screen-off-at-combined-zero option can still turn the screen off and must be reviewed. Other brightness apps can interfere.
- **FreeDisplay today**: 🟡 Partial. Native → DDC → software fallback exists at `Apps/OpenDisplay/Sources/AppModel.swift:1280`; DDC requires a successful read and nonzero maximum before selection. Software fallback clamps to 0.15 at `Apps/OpenDisplay/Sources/AppModel.swift:1405`. The method named combined in `Packages/TopologyCore/Sources/TopologyCore/Dimming.swift:26` combines gamma and an overlay, **not hardware and software brightness**. Its fixed overlay cap is 0.9 and split parameter 0.55. No user-defined hardware floor, raw minimum/maximum or zero mapping exists. Forced software brightness is separately exposed at `Apps/OpenDisplay/Sources/DisplayDetailView.swift:376`.
- **Implementation notes**: M/L, controller abstraction and piecewise normalized mapping; CoreGraphics gamma/AppKit overlays are public, hardware/DDC paths are private. Name the existing gamma/overlay mixture accurately. Retain raw controller units, user limits and perceived combined values independently.
- **Acceptance criteria**:
  - Demonstrate continuous transitions across software dimming, hardware range and optional boost without a jump at the hardware floor.
  - A 0–50 controller round-trips correctly; a locked HDR preset produces an actionable failure.
  - Changing the software zero mapping never silently changes screen-off policy or iPad hardware brightness.

### T19 Native automatic brightness and externally triggered group synchronization — [page 56](https://betterdisplay.pro/guide/faq/brightness/native-auto-brightness-management/), [page 60](https://betterdisplay.pro/guide/faq/brightness/automatic-external-brightness/)

- **BetterDisplay behaviour** (basic default-group brightness synchronization: Free; advanced/custom group options can require Pro; native management tier unspecified): Device Control Settings can enable management of supported Apple native auto brightness. Disabling management removes BetterDisplay's auto-brightness toggle and prevents its other features changing that native setting; it does **not** turn off macOS auto brightness. Disable management on all affected Apple screens if behavior propagates between them.
  External monitors can follow a built-in display whose brightness macOS adjusts automatically: enable a display group, select brightness, establish source and receivers, and enable synchronization of externally triggered changes. This follows the source's actual brightness value, not raw ambient lux. Diagnose first whether a Control Center or Touch Bar change reaches BetterDisplay, then group rules and receiver controllers. Absolute synchronization and delta synchronization differ: deltas preserve offsets. Polling can observe Touch Bar changes without intercepting its keys.
- **FreeDisplay today**: 🟡 Partial. Groups synchronize brightness/contrast with optional learned offsets at `Packages/TopologyCore/Sources/TopologyCore/DisplayGroup.swift:14` and `Apps/OpenDisplay/Sources/DisplayGroupsCard.swift:106`. Native brightness polling forwards external changes at `Apps/OpenDisplay/Sources/AppModel.swift:1448`. There is no native auto-brightness management toggle, explicit source/receiver role or equivalent externally-triggered policy UI; DDC changes made on the monitor are not covered by this native polling path.
- **Implementation notes**: M, group state is ordinary application logic, native Apple brightness management is private and capability-dependent. Keep auto-brightness ownership distinct from observing it; prevent loops and preserve offsets.
- **Acceptance criteria**:
  - Changing the source through Control Center, automatic adjustment or Touch Bar updates eligible receivers once.
  - Disabling management leaves the OS auto setting unchanged and prevents subsequent app actions from changing it.
  - A receiver cannot feed its synchronized update back into an endless group cycle.

### T20 Nits estimates, calibrated anchors and perceived matching — [page 53](https://betterdisplay.pro/guide/faq/brightness/match-displays/), [page 57](https://betterdisplay.pro/guide/faq/brightness/nits-estimates/)

- **BetterDisplay behaviour** (nits-based group synchronization: Pro; capability/readout entitlement otherwise unspecified): Equal percentages do not imply equal luminance. Enable nits synchronization within a group and configure the source/receivers; reliable per-screen luminance ranges are prerequisites. Requests saturate at each receiver's physical limits. Externally triggered synchronization is separately configurable. Routing native brightness keys directly to all suitable screens bypasses the group's nits-matching calculation.
  Nits can be hardware-reported, known from model data or estimated. Settings → Displays → display → Display Information → Capabilities may show minimum HDR luminance, maximum average HDR luminance and peak luminance; for Apple screens the default preset's peak may be reported. Missing capability rows mean no value is available; recheck reports after changing a monitor's peak-brightness mode. EDR headroom is a relative ratio, not a light-meter measurement. For example, a 2023 16-inch MacBook Pro's 1000-nit sustained and 1600-nit peak figures do not imply a 1600-nit sustained desktop.
  General Settings → Configure Brightness Nits Ranges permits manual minimum, maximum and HDR/SDR anchors. Clearing overrides returns to automatic values; disabling them preserves the stored numbers while ignoring them. On Apple screens these anchors influence requests and readouts. Direct built-in adjustment can have a nonlinear brightness-to-nits curve, so equal slider increments need not be equal luminance steps. Troubleshooting must record controller, preset, auto-brightness state and anchors.
- **FreeDisplay today**: ⬜ Missing. Groups carry percentage/offset behavior rather than a luminance model (`Packages/TopologyCore/Sources/TopologyCore/DisplayGroup.swift:14`). `Apps/OpenDisplay/Sources/AdvancedDisplayToolsView.swift:24` shows EDR information, not measured nits; `Apps/OpenDisplay/Sources/AppModel.swift:1353` identifies the active brightness method.
- **Implementation notes**: L, model explicit measured/reported/estimated provenance and monotonic transfer curves. Public EDR metadata supplies only part of the information; native preset/control access may be private. Do not market visual matching as calibration.
- **Acceptance criteria**:
  - Estimated values are labeled, peak and sustained limits are separate, and clamping is visible.
  - Disabling then reenabling manual anchors restores them without changing their values.
  - Validate group behavior with calibrated measurements where available and with low-capability receivers.

### T21 Bright cursors and mini-LED blooming — [page 58](https://betterdisplay.pro/guide/faq/brightness/bright-cursor/), [page 83](https://betterdisplay.pro/guide/faq/brightness/mini-led-blooming/)

- **BetterDisplay behaviour** (software dimming entitlement depends on method; hardware facts are not tier-gated): An overlay darkens desktop content but may leave the hardware cursor bright. Hardware brightness also lowers the cursor; gamma may affect it on some paths, subject to the custom-profile compatibility guard. Mini-LED halos around a bright cursor on black are a different physical effect caused by shared local-dimming zones. Lower brightness, avoid excessive upscaling or change a monitor's local-dimming mode where available, accepting a contrast tradeoff. No software switch creates more backlight zones.
- **FreeDisplay today**: 🟡 Partial. Hardware and software methods exist, and the overlay is click-through at `Apps/OpenDisplay/Sources/DimOverlayController.swift:53`; no cursor/bloom troubleshooting distinction is exposed. Gamma/overlay application at `Apps/OpenDisplay/Sources/AppModel.swift:692` does not establish cursor behavior on a real display. ➖ Backlight-zone design cannot be fixed by FreeDisplay.
- **Implementation notes**: S, method-specific help and truthful capability labels; avoid synthesizing a fake cursor as a default workaround.
- **Acceptance criteria**:
  - Diagnose cursor-only brightness separately from an optical halo.
  - Changing methods reports the actual method and does not promise elimination of physical blooming.

### T22 Suspend, reset, reference-preset integrity and explicit Shortcuts — [page 52](https://betterdisplay.pro/guide/faq/brightness/touch-id-prompt/), [page 66](https://betterdisplay.pro/guide/faq/brightness/reference-presets/), [page 71](https://betterdisplay.pro/guide/faq/brightness/hdr-highlight-clipping/), [page 139](https://betterdisplay.pro/guide/faq/brightness/hdr-adjustment-shortcuts/)

- **BetterDisplay behaviour** (image-effect/automation tier depends on the selected feature; this FAQ set does not establish a blanket entitlement): Software overlays or strong image adjustments can obscure App Store purchase and Touch ID prompts. Temporarily suspend adjustments without losing stored values, restore saturation to neutral **1.00**, move the prompt to an unaffected display, and reenable effects individually. A gamma problem, compositor effect and direct hardware adjustment need different diagnosis; unrelated authentication failures are not resolved by resetting brightness.
  A reference preset does not prevent subsequent software changes. Disable the master software-video-adjustments setting when preserving its appearance; this affects dimming, gamma, overlays, software upscaling and their combined path, and does not perform calibration.
  Saved gain/color effects can clip HDR highlights even when HDR mode is correct. Compare the same content on the affected display through App Menu → display → Image Adjustments → Suspend Image Adjustments, leaving other displays operating; if detail does not return, inspect HDR mode and the Apple preset. Suspending color adjustments/LUTs preserves their settings and leaves software brightness active. Reset is an immediate operation without a confirmation dialog: it returns software adjustments, including brightness, to neutral and clears enabled per-display LUT assignments, while retaining LUT definitions and leaving hardware settings alone.
  Shortcuts should use explicit On/Off values instead of toggles. An HDR sequence enables HDR, enables image adjustments, then sets individual values; the SDR sequence deliberately reverses the chosen state. Suspending effects preserves values and does not change hardware brightness, hardware contrast or the global adjustment method. These sequences do not automatically run merely because HDR changed, and they do not protect settings against later changes.
- **FreeDisplay today**: 🟡 Partial. Temperature, dimming and boost are composed at `Apps/OpenDisplay/Sources/AppModel.swift:705` and `Apps/OpenDisplay/Sources/AppModel.swift:719`; the capture-only LUT loads at `Apps/OpenDisplay/Sources/CapturePanel.swift:168`. There is no full desktop effect suspension/reset distinction, reference-preset software master or HDR/effect App Intent sequence. Existing App Intents expose reconnect and built-in brightness, not these controls (`Apps/OpenDisplay/Sources/OpenDisplayIntents.swift:81`, `Apps/OpenDisplay/Sources/OpenDisplayIntents.swift:107`).
- **Implementation notes**: M/L, public AppIntents and software effect state; HDR/native-preset integration adds private API risk. Separate stored parameters, activation and reset commands. Avoid losing the last usable state when a prompt is hidden.
- **Acceptance criteria**:
  - Suspend/resume round-trips nonneutral values; reset neutralizes only the documented software scope.
  - A software-brightness setting survives color-effect suspension but not a full software reset.
  - Repeating an explicit HDR/SDR Shortcut twice produces the same final state, with unsupported operations reported.

### T23 Software XDR, direct built-in upscaling and readiness — [page 62](https://betterdisplay.pro/guide/faq/brightness/direct-upscaling-dips/), [page 63](https://betterdisplay.pro/guide/faq/brightness/upscaling-stops-working/), [page 67](https://betterdisplay.pro/guide/faq/brightness/exit-direct-upscaling/), [page 72](https://betterdisplay.pro/guide/faq/brightness/xdr-readiness-system-load/)

- **BetterDisplay behaviour** (Pro): Software upscaling needs a suitable HDR/XDR output and real headroom; a Retina label alone is insufficient. With combined brightness disabled, the hardware-only slider does not upscale: use the separate software path. A global color-table-method switch can avoid compatibility issues, using alternative compositor methods with different limitations. Compare profiles and competing apps, and restore the previous setting if the change does not help.
  Direct built-in XDR is a different supported-hardware path: allow direct XDR, disable ordinary software upscaling, activate direct mode, and route brightness keys through the app. The source explicitly excludes the external Studio Display XDR from this direct built-in procedure. Device Control → Additional Apple Brightness Settings appears when direct control is allowed. The direct-mode option to force EDR is **enabled by default**, preventing dips after HDR playback transitions; it can also influence external Apple EDR displays. Software readiness is a separate setting.
  Selecting an ordinary Apple preset exits direct mode immediately and restores saved brightness/automatic-brightness context; that exit remains available without a Pro entitlement after a trial. It does not automatically disable separate software effects. Trial/account handling itself is not a FreeDisplay requirement.
  Under the global Brightness Upscaling and Dimming Settings, Continuous software XDR upscaling readiness changes take effect immediately. Readiness keeps the path prepared before boost is requested; disabling it defers preparation until needed. Continuous software XDR readiness requires the global color-table method. Turning readiness off for automatic XDR may reduce load but can make transitions less smooth; it does not itself remove supported headroom or turn off existing boost. Compare the same topology, workload, HDR state and brightness before attributing load.
- **FreeDisplay today**: 🟡 Partial. Session boost requires a built-in screen and potential EDR above 1 at `Apps/OpenDisplay/Sources/AppModel.swift:785`. `Apps/OpenDisplay/Sources/XDRBrightnessController.swift:27` creates an 8×8 EDR-triggering window; its Metal surface is extended-linear sRGB/16-bit floating point at `Apps/OpenDisplay/Sources/XDRBrightnessController.swift:96`, and it draws a bright frame at `Apps/OpenDisplay/Sources/XDRBrightnessController.swift:118`. This is a software EDR/gamma technique, not direct Apple reference-preset control. Direct mode, preset restoration and a readiness policy are missing; XDR is off by default in `Packages/TopologyCore/Sources/TopologyCore/SettingsStore.swift:194`.
- **Implementation notes**: L, public Metal/CoreAnimation EDR for software rendering; private DisplayServices/SkyLight/preset interfaces for direct control. Verify sustained behavior, transitions, cursor and cross-display effects on each supported machine.
- **Acceptance criteria**:
  - Identify software and direct mechanisms separately; unsupported hardware cannot activate direct mode.
  - HDR playback start/stop, sleep and profile changes do not leave brightness unexpectedly low or boosted.
  - Exiting direct mode restores the saved context without licensing dependence; readiness can be benchmarked independently.

### T24 Virtual HDR and the limits of reference-mode emulation — [page 65](https://betterdisplay.pro/guide/faq/scaling/virtual-screen-hdr/), [page 69](https://betterdisplay.pro/guide/faq/brightness/reference-mode-emulation/)

- **BetterDisplay behaviour** (virtual HDR and streaming filters: Pro): Enabling virtual HDR declares extended luminance with 16 bits per component and requires reconnecting the virtual screen. Display P3 is a suggested profile, not proof of HDR. A mirror receiver must support the result. For streaming/PiP through the ordinary Apple Silicon capture path, enable the HDR Filter Pipeline under Video Filters; this control is unavailable for compositor or SDR capture paths. The entire remote/capture/display chain must preserve HDR.
  Keep Create HDR modes only off to retain SDR alternatives; the FAQ recommends this state without specifying a factory default. Enabling it removes the SDR/off choice until the virtual configuration is changed and reconnected. EDID edits and virtual definitions cannot install Apple's supported hardware reference presets, calibration or physical luminance. Some players react to declared capabilities with different tone mapping; that is not hardware emulation.
- **FreeDisplay today**: ⬜ Missing HDR workflow. `Providers/VirtualDisplayProvider/Sources/VirtualDisplayRuntime.m:40` declares an sRGB-like gamut and one SDR mode, while capture uses BGRA8 at `Apps/OpenDisplay/Sources/CapturePanel.swift:80`. The UI explicitly identifies capture as SDR/unverified at `Apps/OpenDisplay/Sources/CapturePanel.swift:216`. ➖ Emulating physical Apple calibration is not a legitimate feature claim.
- **Implementation notes**: L, private CGVirtualDisplay capability declarations plus public ScreenCaptureKit/CoreImage/Metal extended-range processing. Preserve transfer function, color space, precision and metadata end to end; qualify OS/hardware support.
- **Acceptance criteria**:
  - Reconnection applies HDR/SDR capability changes; HDR-only cannot strand the user without an understandable reversal.
  - Record and display an HDR test signal without clipping it to an 8-bit SDR buffer.
  - UI distinguishes declared virtual capability, working transport and real reference calibration.

### T25 SDR brightness within an HDR output — [page 70](https://betterdisplay.pro/guide/faq/brightness/sdr-brightness-in-hdr/)

- **BetterDisplay behaviour** (tier unspecified): On supported outputs, macOS Control Center exposes SDR peak brightness while leaving the physical backlight/HDR highlights available. BetterDisplay can use that system control in combined brightness. Leave the setting to disregard SDR-peak availability disabled when this behavior is desired. Enabling hardware brightness control in HDR instead makes combined brightness prefer hardware adjustment, although the OS SDR control remains available. Lowering the SDR white level is not the same operation as boosting HDR highlights.
- **FreeDisplay today**: ⬜ Missing. Brightness routing selects native/DDC/software without an HDR-specific SDR-peak controller (`Apps/OpenDisplay/Sources/AppModel.swift:1280`); EDR boost is separately handled at `Apps/OpenDisplay/Sources/AppModel.swift:799`.
- **Implementation notes**: L, investigate supported native control APIs and private fallback separately. Model SDR reference white, hardware backlight and EDR boost as different properties.
- **Acceptance criteria**:
  - On a supporting display, dim SDR UI without reducing a reference HDR highlight.
  - Changing the HDR hardware-preference option clearly changes the selected controller and preserves direct access to the other available control.

### T26 Custom-profile gamma safeguards and color-table compatibility — [page 73](https://betterdisplay.pro/guide/faq/brightness/custom-profile-black-screen/), [page 78](https://betterdisplay.pro/guide/faq/brightness/color-table-compatibility/)

- **BetterDisplay behaviour** (tier unspecified): A custom ICC profile installed in either user or shared locations can trigger color-table failures, including a black-but-connected image or tint. BetterDisplay's default safeguard blocks gamma when a custom profile is present **anywhere**, not just on the screen being adjusted. Keep the option allowing color tables with custom profiles disabled. A factory/system profile or an alternative adjustment method can avoid the issue; the ICC file is not necessarily defective.
  On the M5 Pro, M5 Max and MacBook Neo paths discussed by the FAQ, disable the color-table method per display while leaving software/compositor adjustments available; inspect the current-method readout. A global disable is another option. Avoid simultaneous gamma control by two apps. Direct built-in XDR is a separate supported Pro alternative with its own brightness-key routing. Recheck sleep/wake. Distinguish no signal from an active black image, and compare screenshot behavior when diagnosing an overlay.
- **FreeDisplay today**: 🟡 Partial, with a **P0 safety gap**. ICC assignment exists, but profile changes immediately reapply gamma (`Apps/OpenDisplay/Sources/AppModel.swift:2018`) without a custom-profile guard. Even the overlay-only path calls the gamma writer with a neutral dim factor at `Apps/OpenDisplay/Sources/AppModel.swift:692`; temperature/boost can still participate. The CoreGraphics provider discards the gamma-set result at `Providers/CoreGraphicsProvider/Sources/CoreGraphicsProvider.swift:186`. A user choosing overlays therefore cannot reliably avoid color-table calls or learn that the write failed.
- **Implementation notes**: M, public ColorSync profile discovery, explicit method capabilities and error propagation. Implement a genuine no-gamma route, conservative compatibility guard and reversible recovery, rather than treating a neutral gamma call as bypassing gamma.
- **Acceptance criteria**:
  - With a custom profile on another display or in shared storage, the default guard prevents gamma writes and explains the selected fallback.
  - Overlay-only mode invokes no color-table API, including on profile changes and wake.
  - Failed gamma writes are visible; recovery restores a usable image without overwriting the user's ICC selection.

### T27 Desktop dark filters and self-streaming — [page 74](https://betterdisplay.pro/guide/faq/brightness/desktop-dark-filters/)

- **BetterDisplay behaviour** (advanced software adjustments/self-stream filters: Pro): Software brightness, contrast and channel gain modify the whole image, not individual apps' themes. Inverting the desktop can use a self-stream with video filters. The compositor self-stream/Video Filter Window path differs from ordinary capture: it does not expose Target FPS or HDR Filter Pipeline. Ordinary capture needs screen-recording permission. Whole-desktop processing has resource cost, and a bright frame can appear at lock/wake or before the effect starts; a hardware brightness floor can reduce its impact.
- **FreeDisplay today**: 🟡 Partial. Desktop temperature/dimming/boost exist at `Apps/OpenDisplay/Sources/AppModel.swift:705`; capture offers a cube LUT, flips and rotation in `Providers/CaptureProvider/Sources/CaptureImageTransform.swift:6`. It has no desktop self-stream output, inversion preset, compositor-window backend or full desktop contrast/channel-gain pipeline. Capture is a small separate preview at `Apps/OpenDisplay/Sources/CapturePanel.swift:124`.
- **Implementation notes**: L, public ScreenCaptureKit/CoreImage/Metal for conventional capture; compositor techniques may involve private APIs. Detect recursion, preserve an independent escape route and report latency.
- **Acceptance criteria**:
  - A desktop inversion affects all intended content without claiming to change application themes.
  - Clearly distinguish compositor and captured-window controls; hide inapplicable FPS/HDR options.
  - Stop/escape and lock/wake behavior are predictable, including documented brief unfiltered frames.

### T28 TV role, Night Shift and True Tone — [page 75](https://betterdisplay.pro/guide/faq/brightness/night-shift-tv/)

- **BetterDisplay behaviour** (system display-role override: Free; automatic Night Shift/True Tone suppression in HDR: Pro): In the system display configuration editor, change the television role to computer, apply the model-wide configuration with administrator authorization, and activate it as instructed. This can restore OS eligibility for Night Shift/True Tone; it is not a hardware color correction. A separate global option to disable these features during HDR can still suppress them.
- **FreeDisplay today**: ⬜ Missing. The EDID/HiDPI panel exports configuration files only and explicitly does not install them (`Apps/OpenDisplay/Sources/AdvancedDisplayToolsView.swift:47`, `Apps/OpenDisplay/Sources/AdvancedDisplayToolsView.swift:50`). Temperature adjustment at `Apps/OpenDisplay/Sources/AppModel.swift:705` is not macOS Night Shift or True Tone.
- **Implementation notes**: M/L, privileged system-override workflow using undocumented configuration conventions; private OS feature controls may be required for HDR suppression. Keep model-wide effects and per-session temperature separate.
- **Acceptance criteria**:
  - Show scope, pending changes and activation requirements before writing a role override.
  - Explain why HDR policy can suppress an otherwise eligible feature, and provide reversible removal.

### T29 Connection color format, range, bit depth and dithering — [page 76](https://betterdisplay.pro/guide/faq/brightness/select-rgb/), [page 79](https://betterdisplay.pro/guide/faq/brightness/framebuffer-connection-depth/), [page 82](https://betterdisplay.pro/guide/faq/brightness/washed-out-colors/), [page 84](https://betterdisplay.pro/guide/faq/brightness/disable-dithering/)

- **BetterDisplay behaviour** (native Apple Silicon color-mode selection and dithering controls: tier unspecified): Available Color Mode entries under the expanded display controls describe RGB/YCbCr, bit depth, range and HDR compatibility. Lowering refresh rate can expose formats that exceed bandwidth at a higher rate. YCbCr 4:4:4 retains full chroma resolution; 4:2:2/4:2:0 do not. RGB is not a universal quality fix. The native selector does not apply to Intel in the same way; a prepared OS EDID override is a separate workaround that can remove HDR or modes, not a physical EDID rewrite.
  Rendering bits per sample, framebuffer storage bits per pixel, cable depth and panel precision are distinct. A 10-bit framebuffer with an 8-bit connection is possible; 8-bit-plus-FRC panel behavior is separate again. Full/limited range must agree at the GPU and monitor. Adjusting brightness/contrast to conceal a mismatch is not a correct fix.
  Expose GPU dithering only where its state is readable on Apple Silicon; remember the per-display choice and reapply it. IORegistry may contain several ports and offline entries, so arbitrary properties are not authoritative for the active screen. Selecting 8-bit output does not disable panel processing. Uniformity correction with GPU dithering off can produce banding; compare both enabled or, if desired, both disabled, accepting loss of correction. No control guarantees that every layer of the chain is free of dithering.
- **FreeDisplay today**: ⬜ Missing connection-format/range/dither controls. Mode descriptions can include render depth (`Packages/DisplayDomain/Sources/DisplayDomain/DisplayModeChoices.swift:44`), but the tray's catalog constructs modes without that depth at `Apps/OpenDisplay/Sources/TrayModeCatalog.swift:37`. Current EDR diagnostics at `Apps/OpenDisplay/Sources/AdvancedDisplayToolsView.swift:24` are not cable-format evidence. No monitor range agreement or uniformity-correction workflow exists.
- **Implementation notes**: L, private Apple Silicon IOMobileFramebuffer/IORegistry/SkyLight interfaces and careful active-port association. Public CoreGraphics metadata remains useful but cannot prove transport or panel behavior.
- **Acceptance criteria**:
  - Report each depth/range field with its source and unknown state; never infer panel bit depth from framebuffer storage.
  - After a format change, verify observed active transport state and preserve recovery if the link drops.
  - Dithering controls are unavailable without a trustworthy state read; documentation separates GPU, panel and uniformity processing.

### T30 ICC profiles versus measured calibration — [page 81](https://betterdisplay.pro/guide/faq/brightness/calibration-and-profiles/)

- **BetterDisplay behaviour** (profile selection: tier unspecified): A profile describes or corrects color behavior; selecting one is not a measured calibration. Hardware calibration, ICC characterization and software correction are different workflows. Profiles should correspond to the actual monitor preset, brightness and other settings used during measurement. Display P3 specifies color characteristics and does not itself turn on HDR. Users can select installed profiles through the display menu or use ColorSync Utility.
- **FreeDisplay today**: ✅ Profile enumeration, validation, assignment and reset exist at `Apps/OpenDisplay/Sources/ColorProfileService.swift:36`, `Apps/OpenDisplay/Sources/ColorProfileService.swift:85` and `Apps/OpenDisplay/Sources/ColorProfileService.swift:96`; the tray exposes profiles at `Apps/OpenDisplay/Sources/MenuBarView.swift:792`. 🟡 Enumeration deduplicates by display name (`Apps/OpenDisplay/Sources/ColorProfileService.swift:55`), so distinct ICC files with identical names disappear from the chooser. Assignment error handling and gamma interaction also need attention: `Apps/OpenDisplay/Sources/AppModel.swift:2010` ignores the setter's result before refreshing the name.
- **Implementation notes**: S/M, public ColorSync. Use profile identity/URL rather than name as the key, expose failures and connect to the global gamma safeguard. Do not imply calibration without measurements.
- **Acceptance criteria**:
  - Two different installed profiles sharing a name remain selectable and distinguishable.
  - Failed assignment leaves the observed active profile accurately displayed.
  - Help distinguishes profile selection, hardware calibration and HDR.

### T31 DDC input controls, editable sources and unavailable monitors — [page 85](https://betterdisplay.pro/guide/faq/connections/missing-input-source/)

- **BetterDisplay behaviour** (tier unspecified): Input selection is an independently enabled DDC control in Configure Controls. Input Sources lets users edit values, labels and visibility. Standard VCP 0x60 entries are defaults/examples, not an enumeration of ports physically detected on a monitor. After switching away, a monitor may stop responding to commands on the previous input. Read capability and write capability are independent; diagnose both and retain the actual request/result.
- **FreeDisplay today**: 🟡 Partial, with misleading success/state risk. Fixed standard sources come from `Apps/OpenDisplay/Sources/AppModel.swift:163` and are all listed at `Apps/OpenDisplay/Sources/DisplayDetailView.swift:420`; no per-monitor editable mapping exists. The regular UI path caches the selected input before transmission and ignores the write result at `Apps/OpenDisplay/Sources/AppModel.swift:1908` and `Apps/OpenDisplay/Sources/AppModel.swift:1921`. The hotkey path checks delivery but treats it as switching success (`Apps/OpenDisplay/Sources/AppModel.swift:1936`); neither proves the monitor changed inputs.
- **Implementation notes**: M, private IOAVService DDC with serial command scheduling. Separate configured, requested, delivered and observed input. Allow a write-only controller and preserve a recovery path when the previous input becomes inaccessible.
- **Acceptance criteria**:
  - Rename, hide and add raw source values per monitor without claiming automatic port discovery.
  - Failed delivery never updates the observed input; unavailable readback remains unknown.
  - Switching away can terminate DDC access without being interpreted as proof of successful switching or permanent failure.

### T32 Apple Cinema Display DDC eligibility — [page 86](https://betterdisplay.pro/guide/faq/connections/apple-cinema-ddc/)

- **BetterDisplay behaviour** (tier unspecified): BetterDisplay normally withholds DDC from certain Apple displays because older models can develop a persistent wake/black-screen failure. Treating an Apple-capable display as a generic non-Apple monitor is an explicit override with a serious model-specific warning. It is not a general fix for an incompatible dock or cable.
- **FreeDisplay today**: 🟡 Partial safety coverage. Native brightness is preferred for built-in/Apple-vendor devices at `Apps/OpenDisplay/Sources/AppModel.swift:1296`, but the subsequent non-built-in DDC fallback at `Apps/OpenDisplay/Sources/AppModel.swift:1308` is not an explicit model-aware exclusion or informed override. DDC's generic feature implementation is at `Providers/ExperimentalLifecycleProvider/Sources/DDCControl.swift:18`.
- **Implementation notes**: M, private hardware I/O; identify risky Apple models and make the default conservative. Keep a narrowly scoped expert override separate from normal discovery.
- **Acceptance criteria**:
  - A recognized risky Apple display is not probed/written through DDC by ordinary brightness discovery.
  - An override explains persistent hardware behavior and does not silently apply to all Apple products.

### T33 DDC cache, raw readback and polling — [page 87](https://betterdisplay.pro/guide/faq/brightness/ddc-readback/)

- **BetterDisplay behaviour** (tier unspecified): A managed hardware-brightness value is a cached, normalized application value; it is not a fresh DDC query. Raw luminance reads return current and maximum controller values. Writes can succeed while reads fail. Per-control periodic readback is **off by default** and must be enabled to reflect changes made in the monitor's own menu. Raw range values, normalized percentages and emitted light are three different observations.
- **FreeDisplay today**: 🟡 Partial. Raw CLI readback returns current/maximum at `Tools/opendisplay/Sources/main.swift:815`; normalized hardware refresh and delayed verification exist at `Apps/OpenDisplay/Sources/AppModel.swift:1814` and `Apps/OpenDisplay/Sources/AppModel.swift:1865`. Brightness routing requires a readable maximum at `Apps/OpenDisplay/Sources/AppModel.swift:1317`, excluding useful write-only cases. Native polling at `Apps/OpenDisplay/Sources/AppModel.swift:1448` is not configurable periodic DDC polling. CLI brightness success reflects request handling/delivery at `Tools/opendisplay/Sources/main.swift:643`, not a luminance measurement.
- **Implementation notes**: M, private DDC with bounded polling, retry/backoff and independent read/write capabilities. Include timestamps and raw units; do not overwrite an unknown observed state with a requested value.
- **Acceptance criteria**:
  - A cached slider value is visibly distinguishable from a timestamped readback.
  - Monitor-menu changes appear only after supported refresh/polling; polling is initially disabled.
  - Write-only devices can use configured ranges and report delivery without claiming verified physical brightness.

### T34 DDC RGB gains and monitor-specific ranges — [page 88](https://betterdisplay.pro/guide/faq/brightness/ddc-rgb-gain-range/)

- **BetterDisplay behaviour** (tier unspecified): Per-channel gain maxima vary, including 100, 200 and 255. Configure each control's true range before interpreting a percentage. A neutral normalized value is not a universal raw reset value or a calibration. Monitor-side changes persist after quitting the app; even a factory reset may not restore every gain. Capability detection is optional and cannot replace validation of the device's behavior.
- **FreeDisplay today**: 🟡 Partial. RGB gain VCP codes are implemented at `Providers/ExperimentalLifecycleProvider/Sources/DDCControl.swift:18` and exposed as hardware controls at `Apps/OpenDisplay/Sources/DisplayDetailView.swift:398`. Normalization uses reported maximums, with a default maximum of 100 when writing without one (`Apps/OpenDisplay/Sources/AppModel.swift:1837`); there are no manual per-control min/max settings or device-specific neutral values. Capability querying is a diagnostic at `Providers/ExperimentalLifecycleProvider/Sources/DDCControl.swift:223`, not a proof of calibration.
- **Implementation notes**: M, private DDC. Store explicit raw bounds and neutral/reset semantics per control, and identify unsupported reads rather than guessing a calibration value.
- **Acceptance criteria**:
  - 0–100, 0–200 and 0–255 gain controls map accurately without clipping or unintended overdrive.
  - Quitting does not claim to undo persistent monitor changes; reset scope is clearly described.

### T35 Hardware contrast, visibility and automation semantics — [page 89](https://betterdisplay.pro/guide/faq/brightness/hardware-contrast/)

- **BetterDisplay behaviour** (tier unspecified): Enable hardware contrast under Device Control; making Contrast visible in the customized main menu only changes placement. The Shortcuts image-adjustment hardware-contrast action uses the managed normalized range and updates the corresponding UI. Sending a raw DDC command is a different action and need not update the managed cache. Generic increase/decrease-contrast actions may choose a preferred software control; identify the target explicitly.
  Function keys such as Fn-F1/F2 and brightness media events are distinct bindings. Changing the brightness VCP code from 0x10 to 0x12 redirects **all** brightness actions using that controller to contrast, not just one shortcut; restore the original code to undo that remapping.
- **FreeDisplay today**: 🟡 Partial. Contrast exists among hardware controls (`Apps/OpenDisplay/Sources/DisplayDetailView.swift:398`) and can synchronize through groups (`Packages/TopologyCore/Sources/TopologyCore/DisplayGroup.swift:14`). Raw VCP CLI writes exist at `Tools/opendisplay/Sources/main.swift:759`, but App Intents expose brightness/reconnect only (`Apps/OpenDisplay/Sources/OpenDisplayIntents.swift:135`). There is no managed hardware-contrast intent, menu-placement setting or safe configurable VCP remap.
- **Implementation notes**: M, public AppIntents/key-binding layer over private DDC. Use typed commands with normalized-versus-raw units and explicit controller selection; avoid global remapping for a one-key requirement.
- **Acceptance criteria**:
  - A contrast intent selects hardware contrast and reflects verified/cache status in the UI.
  - A raw VCP write never masquerades as a managed normalized update.
  - Any VCP remap visibly affects all relevant brightness routes and is reversible.

### T36 LG network control, power automation and delayed wake — [page 90](https://betterdisplay.pro/guide/faq/connections/lg-wakes-after-undocking/), [page 92](https://betterdisplay.pro/guide/faq/connections/lg-tv-controls/)

- **BetterDisplay behaviour** (network-controller tier unspecified): Add an LG network controller using the TV's IP, initiate pairing, accept the TV prompt/PIN and associate it with the correct connected display. Supported picture controls include backlight/OLED brightness, contrast and saturation; firmware and picture modes can lock them. Volume can use full absolute control or only up/down/mute, appropriate when an external CEC amplifier owns the volume. Network control is separate from HDMI-CEC; an adapter may carry video without supporting CEC.
  Configure the Mac's TV input, power management and switching to that input on power-on separately. Standby wake requires TV/network support. Recheck the IP after control stops working.
  The wake automation option to recheck the connection before turning on is **off by default**. When enabled, the check occurs after wake/configuration delays. It prevents an undocked Mac waking an unrelated TV, but can block a TV that needs Wake-on-LAN before a video link exists. Disabling automatic power-on is another valid choice. A third-pass WOL delay should remain blank/zero unless needed; that retry does not perform another connection check.
- **FreeDisplay today**: ⬜ Missing. `Apps/OpenDisplay/Sources/LocalControlPanel.swift:35` explicitly excludes TV/AV/CEC protocols; existing monitor controls are DDC at `Providers/ExperimentalLifecycleProvider/Sources/DDCControl.swift:18`. There is no pairing, network-controller priority, WOL or TV-input automation.
- **Implementation notes**: L, public networking APIs but vendor/firmware-dependent protocols, authenticated pairing and secure token storage. Cancel delayed tasks on topology changes and distinguish wake prerequisite from post-wake verification.
- **Acceptance criteria**:
  - Pair to the chosen TV, retain authorization securely and recover from an IP change.
  - Test undocking before the delayed wake, link-dependent WOL, retries and disabled power-on.
  - Relative-volume mode never invents an absolute receiver volume.

### T37 Philips network remote and source selection — [page 91](https://betterdisplay.pro/guide/faq/connections/philips-input-selection/)

- **BetterDisplay behaviour** (tier unspecified): Add/pair the Philips network controller at the TV IP under Device Control → Add Controller, associate the display and wait for readiness. Show Philips Remote exposes a source button represented by two rectangles/arrows; use the remote's arrows and OK to choose an input. This is not the LG controller's direct named-input list.
- **FreeDisplay today**: ⬜ Missing. Only monitor DDC sources are enumerated at `Apps/OpenDisplay/Sources/AppModel.swift:163`; the local API does not implement TV protocols (`Apps/OpenDisplay/Sources/LocalControlPanel.swift:35`).
- **Implementation notes**: M/L, public networking with model-specific pairing/protocol support. Model remote key sequences separately from a directly addressable input capability.
- **Acceptance criteria**:
  - Readiness and authorization precede remote commands.
  - Source, arrows and OK work as a sequence without advertising unsupported direct selection.

### T38 LG service-menu access — [page 93](https://betterdisplay.pro/guide/faq/brightness/lg-service-menu/)

- **BetterDisplay behaviour** (tier unspecified): Holding Option while opening Device Control reveals IN-START and EZ-ADJUST for a paired, ready LG controller. The remote can enter a model-specific numeric password. Full Service Access presents Enable/Disable/Cancel and changes access permissions, not a dimming value. Firmware/service changes can be consequential; the FAQ is not a universal set of safe parameter values.
- **FreeDisplay today**: ⬜ Missing; no LG network controller exists (`Apps/OpenDisplay/Sources/LocalControlPanel.swift:35`). This is a niche expert workflow, not a required part of ordinary brightness.
- **Implementation notes**: M after LG support, vendor-specific network commands with high operational risk. Keep service access explicitly separate and reversible where supported; do not ship guessed passwords/parameters.
- **Acceptance criteria**:
  - Service controls are hidden from routine operation and require an identified, ready TV.
  - Cancel sends no command; changing access does not claim to change image settings.

### T39 Samsung TV/Smart Monitor network capabilities — [page 94](https://betterdisplay.pro/guide/faq/connections/samsung-tv-controls/)

- **BetterDisplay behaviour** (tier unspecified): Pair/authorize the IP-based controller and associate a connected display. The described controller supports volume up/down/mute, not absolute volume or hardware brightness. Source/HDMI remote keys vary by model. Enabling volume, selecting controller priority and choosing the target of native volume keys are separate steps. Software darkening changes the image, not the TV's backlight; DDC cannot create a brightness capability the device lacks. 8K transport support is a separate concern.
- **FreeDisplay today**: ⬜ Missing network control. DDC volume at `Providers/ExperimentalLifecycleProvider/Sources/DDCControl.swift:18` and software dimming at `Apps/OpenDisplay/Sources/AppModel.swift:685` are not Samsung remote support. The local panel explicitly excludes these protocols at `Apps/OpenDisplay/Sources/LocalControlPanel.swift:35`.
- **Implementation notes**: L, public networking and vendor authorization; declare relative-only volume and per-model remote-key capabilities.
- **Acceptance criteria**:
  - Unsupported absolute volume/backlight controls are absent rather than simulated as successful.
  - Native keys reach the authorized, selected controller and preserve mute semantics.

### T40 Dell UP3218K, tiled displays and bandwidth diagnosis — [page 95](https://betterdisplay.pro/guide/faq/connections/dell-up3218k/)

- **BetterDisplay behaviour** (hardware diagnosis; no tier bypass): The FAQ describes two DisplayPort 1.4 links for UP3218K 8K60 and one link for 8K30. Native macOS tile assembly is not guaranteed. Compare direct connections on separate ports with suitable cables against a dock, and inspect whether the OS sees one panel or two halves. Distinguish rendered dimensions from link timing and record wake behavior. Cropping virtual outputs into two halves is not synchronized native tiling and does not remove bandwidth limits.
- **FreeDisplay today**: 🟡 Basic topology and logical/framebuffer diagnostics exist at `Apps/OpenDisplay/Sources/AppModel.swift:1045`; ⬜ no tiled-panel/link-capacity diagnosis or supported tile assembly. Single-window capture at `Apps/OpenDisplay/Sources/CapturePanel.swift:124` is not a native dual-link solution.
- **Implementation notes**: M for diagnostics; L/high risk for private topology work. Treat official timing/cabling requirements as device-specific facts and qualify each Mac/OS path.
- **Acceptance criteria**:
  - A support report distinguishes two tile identities, one logical display, render mode and actual signal information.
  - No virtual workaround is labeled native 8K60 without verified transport and synchronization.

### T41 Generic identities, aliases and unrelated camera names — [page 96](https://betterdisplay.pro/guide/faq/connections/generic-display/), [page 98](https://betterdisplay.pro/guide/faq/connections/camera-device-names/)

- **BetterDisplay behaviour** (display naming/configuration tier unspecified): A generic display may reflect missing EDID, a real fallback identity or a remembered temporary placeholder. A friendly rename does not repair identification or DDC. Safety decisions require the live identity, not a retained label. Compare a direct connection against KVM pass-through/emulation. Display aliases do not rename a monitor's camera or microphone; select and verify those devices in the calling app using preview and audio meters.
- **FreeDisplay today**: 🟡 Partial diagnostics, with a **P0 classification gap**. `Providers/CoreGraphicsProvider/Sources/CoreGraphicsProvider.swift:291` builds identity/activity. Its helper at `Packages/DisplayDomain/Sources/DisplayDomain/DisplayActivity.swift:35` considers a single-mode display virtual as well as specific placeholder identifiers. That can misclassify a real single-mode monitor, while other virtual outputs can be treated as external. The app's information panel at `Apps/OpenDisplay/Sources/DisplayDetailView.swift:566` cannot repair EDID. ➖ Camera/microphone naming is outside display management.
- **Implementation notes**: M/L, use multiple independent identity signals, explicit own-virtual IDs, driver classification and conservative unknown states. Keep aliases separate from stable identity and live recoverability.
- **Acceptance criteria**:
  - Test physical single-mode, own virtual, third-party virtual, DisplayLink and transient placeholder fixtures separately.
  - Renaming never changes controller binding or last-physical-screen safety decisions.
  - Camera/microphone help directs users to their actual device selector.

### T42 DCP/Crossbar panic investigation — [page 97](https://betterdisplay.pro/guide/faq/connections/dcp-kernel-panic/)

- **BetterDisplay behaviour** (diagnostic procedure, not tier-gated): DCP, DCPEXT or Crossbar names in a panic identify a subsystem, not the cause. Capture the complete panic, exact trigger, hardware/OS, cables/docks and mode/HDR state. Isolate one feature, one direct-connected monitor and an app-quit baseline over enough repetitions. Installed system overrides can remain active after quitting, so record/remove them separately when appropriate. Apple diagnostics and hardware investigation remain relevant. Preventing sleep can hide a wake trigger but does not fix a kernel failure.
- **FreeDisplay today**: 🟡 Topology/health and recovery paths exist, but no unified panic reproduction bundle. Wake convergence at `Packages/TopologyCore/Sources/TopologyCore/WakeConvergence.swift:44` and sleep prevention at `Packages/TopologyCore/Sources/TopologyCore/DisplaySleepGuard.swift:15` cannot establish the cause of a kernel panic.
- **Implementation notes**: S/M, public diagnostic export with explicit redaction and an experiment log. Do not collect or upload panic files automatically without an appropriate user action.
- **Acceptance criteria**:
  - A local diagnostic report separates observations, hypotheses and active persistent overrides.
  - A sleep workaround is labeled mitigation; success requires repeated reproduction testing outside this audit.

### T43 KVM desktop continuity and software versus hardware dummy displays — [page 99](https://betterdisplay.pro/guide/faq/connections/kvm-desktop-continuity/), [page 134](https://betterdisplay.pro/guide/faq/virtual-streaming/hdmi-dummy-plug/)

- **BetterDisplay behaviour** (preset virtual screens: Free; presentation/mirroring workflows can require Pro): An EDID override does not keep a disconnected physical link alive. To retain a desktop while a KVM switches away, keep a virtual source connected and mirror/present it on the physical output. Disable both ordinary and inverse association-driven connection rules when continuous virtual presence is required; optionally enforce the virtual mirror when the monitor returns. Apps can still relocate windows, and an independent recovery display/control path is necessary.
  Software virtual screens consume no physical connector and provide configurable modes. An HDMI dummy consumes an output and advertises the plug's fixed capabilities. Cloned EDID does not make their OS identities identical. Use a hardware emulator if retaining a physical connection is the actual requirement; remote viewing still requires a separate sharing application. PiP is a Pro viewing option.
- **FreeDisplay today**: 🟡 Partial. Private virtual screens can be created, but their handles are session-only at `Providers/VirtualDisplayProvider/Sources/VirtualDisplayProvider.swift:25`. The UI has no startup restore or association policy (`Apps/OpenDisplay/Sources/VirtualDisplaysSettingsView.swift:7`). Public mirroring uses the main display as source (`Providers/CoreGraphicsProvider/Sources/CoreGraphicsProvider.swift:227`), rather than a persistent arbitrary virtual-source presentation relationship.
- **Implementation notes**: L, private CGVirtualDisplay plus public topology/mirroring where available. Persist definitions separately from instances; reconcile source/target identity after KVM transitions and preserve an escape path.
- **Acceptance criteria**:
  - Switching away leaves the intended virtual desktop alive; reconnecting restores only the configured presentation relationship.
  - Removing an association does not delete the virtual definition.
  - Documentation distinguishes desktop continuity, physical-link emulation and remote access.

### T44 Automatic built-in disconnection and the last physical screen — [page 100](https://betterdisplay.pro/guide/faq/connections/automatic-built-in-disconnect/), [page 102](https://betterdisplay.pro/guide/faq/connections/last-physical-display/)

- **BetterDisplay behaviour** (Pro soft disconnection): On supported Apple Silicon, automatic built-in disconnection responds to a suitable external monitor, including after wake. Own virtual screens, AirPlay and Sidecar do not normally satisfy the physical-screen requirement; registered DisplayLink outputs are an explicit physical exception. A per-monitor Ignore option permits selective triggers. Manually reconnecting the built-in screen suspends the automatic rule.
  Protect the last usable physical screen even when a virtual desktop is reachable remotely. Making a screen main does not disconnect others. A generic placeholder is not reliable rescue evidence. Allowing all screens to disconnect is an intentional expert override requiring an independent recovery method; it effectively disables automatic reconnection when none remain, even if that rescue preference still appears stored as enabled. Startup/quit reconnection policies are separate. Keep allow-all off and rescue on for normal use.
- **FreeDisplay today**: 🟡 Partial, with a **P0 safety inconsistency**. Automatic disconnection is off by default (`Packages/TopologyCore/Sources/TopologyCore/SettingsStore.swift:161`), and the rising-edge policy is at `Packages/TopologyCore/Sources/TopologyCore/AutoDisconnectBuiltInPolicy.swift:29`. Its input at `Apps/OpenDisplay/Sources/AppModel.swift:3517` tests display class without checking active state. Disconnect preflight in `Packages/TopologyCore/Sources/TopologyCore/SafetyEngine.swift:43` considers active non-mirrored recoverable candidates without excluding virtual displays. Wake recovery does exclude the virtual class (`Packages/TopologyCore/Sources/TopologyCore/WakeConvergence.swift:159`), while virtual creation/removal has another heuristic (`Packages/DisplayDomain/Sources/DisplayDomain/VirtualDisplaySafetyPolicy.swift:18`). Classification itself is imperfect as described in the identity topic. Missing selective ignore policy and documented manual-override semantics.
- **Implementation notes**: L, unify safety predicates and identity provenance before extending private disconnect capabilities. Use live active physical usability, registered driver-backed exceptions and a conservative unknown state; virtual connectivity alone cannot prove a visible escape route.
- **Acceptance criteria**:
  - With one physical display plus any own/third-party virtual screens, disconnecting the physical screen is refused by default.
  - An inactive remembered external screen cannot trigger internal disconnection.
  - DisplayLink, AirPlay, Sidecar and ambiguous placeholders are tested independently; manual reconnect suspends automatic redisconnection.

### T45 Blanking, power-off, disconnection and brief resynchronization — [page 101](https://betterdisplay.pro/guide/faq/connections/blank-without-disconnecting/), [page 103](https://betterdisplay.pro/guide/faq/connections/brief-blackout/)

- **BetterDisplay behaviour** (soft disconnect: Pro; screen-control/blanking tier unspecified): Blanking or Screen Control can leave a desktop connected while hiding the image. A black LCD may retain its backlight and is not necessarily in standby. Configure a per-display menu switch's behavior to Screen Control only when a suitable state controller exists. DDC screen-off may not be remotely wakeable; power-off can require the monitor's physical button. Soft disconnect removes the desktop from topology instead.
  An external screen may briefly go black after the built-in screen disconnects because timing, rate or color format is renegotiated. Compare a common working mode in both arrangements. A persistent black screen needs a different diagnosis from a brief link resynchronization.
- **FreeDisplay today**: 🟡 Partial. Blackout combines a 0.15 gamma floor with an opaque overlay (`Apps/OpenDisplay/Sources/AppModel.swift:1022`), retaining the desktop. Its alternate-screen check counts any other active display. The overlay is below the status-bar level (`Apps/OpenDisplay/Sources/DimOverlayController.swift:62`), so it is not proof that every on-screen element is black. DDC power options warn about recovery at `Apps/OpenDisplay/Sources/DisplayDetailView.swift:429`. The public lifecycle fallback mirrors a display rather than powering/disconnecting it (`Providers/CoreGraphicsProvider/Sources/CoreGraphicsProvider.swift:101`); only the appropriate private path can fulfill actual soft disconnection.
- **Implementation notes**: M, public AppKit blanking and topology observation, private DDC/disconnect for hardware state. Use precise labels and distinguish transient signal loss from a failed final state.
- **Acceptance criteria**:
  - Blanking leaves windows/topology intact and never claims standby or power savings.
  - A mirror fallback is reported as mirroring, not successful disconnection.
  - Power-off and disconnect controls expose their specific recovery route; a timeout distinguishes transient resync from lost output.

### T46 Unwanted connections, offline records, reset and forgetting — [page 104](https://betterdisplay.pro/guide/faq/connections/unwanted-display/)

- **BetterDisplay behaviour** (soft disconnect and in-app mirroring: Pro; OS mirroring: Free): A detected display cannot be removed by forgetting its record. Check for redundant USB-C video plus HDMI connections. Disconnect or mirror if appropriate; startup automation runs only after user login. An offline cross icon is status, not a delete button. Offline records normally remain at least **90 days** before automatic forgetting. Explicit Forget requires confirmation and removes saved settings/associations. Reset on a currently present screen causes it to be rediscovered rather than physically disconnected.
- **FreeDisplay today**: 🟡 Partial. A registry and offline lifecycle ledger exist at `Apps/OpenDisplay/Sources/AppModel.swift:604` and `Apps/OpenDisplay/Sources/AppModel.swift:3297`. Virtual removal at `Providers/VirtualDisplayProvider/Sources/VirtualDisplayProvider.swift:81` destroys a session display, a different operation. There is no equivalent configurable offline-retention/confirmed-forget workflow with association cleanup.
- **Implementation notes**: M, public persistence/UI. Define detected instance, retained identity, settings reset and definition deletion separately; avoid deleting diagnostics when a screen merely disconnects.
- **Acceptance criteria**:
  - Forget cannot claim to remove a currently detected hardware connection.
  - Confirmed deletion lists affected settings/associations, while reset preserves live discovery.
  - Retention respects the configured minimum and does not erase short-term offline history.

### T47 Touch Bar and lid order after undocking — [page 105](https://betterdisplay.pro/guide/faq/connections/touch-bar-after-undocking/)

- **BetterDisplay behaviour** (Pro disconnection context): If the built-in screen was disconnected or the Mac is in clamshell mode, open the lid and restore the built-in screen before unplugging the external monitor. Normally the internal screen cannot be reconnected while the lid remains closed. This ordering may prevent a dark Touch Bar, but is not a guaranteed repair once it is already dark.
- **FreeDisplay today**: 🟡 Recovery commands exist at `Apps/OpenDisplay/Sources/AppModel.swift:3345`; there is no Touch Bar/lid-specific guidance or proven repair. ➖ The underlying Touch Bar failure is not established as an application-fixable defect by this FAQ.
- **Implementation notes**: S for contextual recovery help, M if adding trustworthy lid/availability diagnostics. Do not describe a reconnect request as successful before topology confirms it.
- **Acceptance criteria**:
  - Undocking help describes the lid/open/reconnect order and avoids promising recovery of an already failed Touch Bar.
  - A closed-lid unavailable internal screen is not advertised as a verified rescue surface.

### T48 DDC restoration after wake and reconnect — [page 106](https://betterdisplay.pro/guide/faq/brightness/ddc-brightness-after-wake/)

- **BetterDisplay behaviour** (tier unspecified): Device Control → DDC Control → Advanced → Reapply DDC settings on wake can resend stored adjustments even when the saved percentage is unchanged. If a manual command works after the monitor becomes ready, increase the wake delay; global wake/configuration delays under Application → Advanced Settings & Privacy affect all displays, so change one relevant delay at a time. The same readiness test applies to a CLI wake script, including hardware contrast. DDC values on startup → Write last used values to display restores eligible ranged and on/off controls after reconnection, potentially including volume/mute. It must not replay command-only actions such as input changes, power commands or factory reset. The global restoration policy can suppress replay. Verify the monitor's actual response rather than the cached slider. If DDC is unavailable, inspect the controller actually in use; an unchanged hardware level with a dimmer image suggests software brightness, HDR or color configuration.
- **FreeDisplay today**: ⬜ Missing explicit replay policy. Wake processing at `Apps/OpenDisplay/Sources/AppModel.swift:3763` handles topology/layout, not saved DDC replay. Existing writes/verification at `Apps/OpenDisplay/Sources/AppModel.swift:1855` are driven by user/controller changes and do not implement delayed per-control restoration.
- **Implementation notes**: M, lifecycle state machine over private DDC. Classify controls as ranged/on-off/command-only, cancel stale jobs after disconnect and retry only within bounds. Respect global restoration policy and selected identity.
- **Acceptance criteria**:
  - Wake replays an unchanged saved brightness after readiness, with an independently adjustable delay.
  - Input, power and factory-reset commands are never replayed as ordinary saved values.
  - A failed or ignored command is shown separately from saved intent and confirmed readback.

### T49 Sleep prevention ownership and release — [page 107](https://betterdisplay.pro/guide/faq/connections/sleep-after-unplugging/)

- **BetterDisplay behaviour** (tier unspecified): A per-display sleep assertion should disappear when its owning display disconnects. Diagnose off/on/unplug states with at least **15 seconds** between observations using macOS assertion reporting. A display-ID label is not a process ID. Some display operations create a transient assertion lasting about **10 seconds** after the last operation; repeated operations extend it. Other applications may independently prevent sleep. System-sleep assertions, display-idle prevention and explicit/manual sleep are distinct.
- **FreeDisplay today**: 🟡 Partial. `Apps/OpenDisplay/Sources/PreventSleepAssertion.swift:13` uses the public PreventUserIdleDisplaySleep assertion, not a guarantee against system/manual/lid sleep. `Packages/TopologyCore/Sources/TopologyCore/DisplaySleepGuard.swift:15` owns a single assertion while enabled and an external screen is considered present, and releases it during reconciliation/deinitialization. Its topology input inherits the active/classification issues at `Apps/OpenDisplay/Sources/AppModel.swift:3599`. No per-display ownership UI or operation-scoped transient assertion exists.
- **Implementation notes**: M, public IOKit power assertions with explicit ownership and lifecycle cleanup. Keep idle-display prevention named precisely and recompute on active physical topology changes.
- **Acceptance criteria**:
  - Enabling, disabling and unplugging change only FreeDisplay's owned assertion after settling.
  - No stale inactive/virtual screen retains an assertion intended for an external physical display.
  - Diagnostics distinguish the app's assertion type from unrelated system assertions.

### T50 Framebuffer reinitialization and adapter reset — [page 108](https://betterdisplay.pro/guide/faq/connections/reinitialize-on-wake/)

- **BetterDisplay behaviour** (tier unspecified): Reinitialize on wake/unlock is **off by default** and applies to supported external Apple Silicon framebuffer paths, not built-in or virtual displays. First verify that manual reinitialization resolves the problem. It briefly interrupts the image and rebuilds EDID using the configured custom automatic path when available, falling back to factory data if unavailable or unsuccessful. The global VMM7100 adapter-reset option is a different mechanism.
- **FreeDisplay today**: ⬜ Missing. EDID handling exports/validates only (`Apps/OpenDisplay/Sources/AdvancedDisplayToolsView.swift:37`); reconnect at `Apps/OpenDisplay/Sources/AppModel.swift:3345` is not framebuffer reinitialization or a VMM7100 reset.
- **Implementation notes**: L, private framebuffer/adapter-specific interfaces; serialize with topology convergence and EDID restoration. Expose explicit eligibility and interruption warning.
- **Acceptance criteria**:
  - Built-in/virtual screens never offer an inapplicable reinitialization action.
  - A failed custom rebuild falls back predictably and reports the effective data source.
  - Wake automation remains disabled until chosen and never recursively triggers itself.

### T51 Keeping displays disconnected through wake — [page 109](https://betterdisplay.pro/guide/faq/connections/keep-disconnected-after-wake/)

- **BetterDisplay behaviour** (Pro): Under Settings → Displays → Overview → Display Connections → Connection Management Settings, the option to disconnect screens that reconnect during wake is **off by default**. It acts after a delay, so the screen may flash briefly, and excludes the post-wake main display. Retain automatic rescue and leave allow-all-disconnected off. Switching the monitor's input away does not necessarily remove its macOS desktop; off, standby and input-away are different states.
- **FreeDisplay today**: 🟡 Partial. The offline-intent ledger feeds wake policy at `Apps/OpenDisplay/Sources/AppModel.swift:3787`; convergence has bounded observation/reassertion intervals and retries (`Packages/TopologyCore/Sources/TopologyCore/WakeConvergence.swift:44`). It does not expose this exact default-off behavior with explicit post-wake-main exclusion. Existing safety/classification must be fixed before adding automatic redisconnection.
- **Implementation notes**: M/L, private soft-disconnect plus topology convergence. Reevaluate main identity and visibility at execution time, not from the pre-sleep snapshot.
- **Acceptance criteria**:
  - A newly main display is protected even if it was disconnected before sleep.
  - Intent restoration waits for convergence, admits possible brief flashes and stops on a safety conflict.
  - Input-away alone never becomes a false offline observation.

### T52 FileVault preboot versus session login — [page 110](https://betterdisplay.pro/guide/faq/connections/filevault-startup-resolution/)

- **BetterDisplay behaviour** (OS boundary, no tier workaround): BetterDisplay runs in the user session and cannot choose FileVault preboot resolution. Launch at login occurs too late. System EDID overrides are not writes to monitor firmware and do not automatically apply to firmware/Recovery/preboot. Keep a usable built-in display or compatible monitor for unlocking; session lock/wake is a separate case.
- **FreeDisplay today**: ➖ Not applicable as a preboot feature. `Apps/OpenDisplay/Sources/OpenDisplayApp.swift:6` defines an ordinary user-session app. Current exported overrides (`Packages/TopologyCore/Sources/TopologyCore/DisplayConfigurationTools.swift:58`) do not establish preboot behavior.
- **Implementation notes**: S, explicit help and scope labels. Do not build a privileged helper merely on the assumption that it can modify FileVault display behavior.
- **Acceptance criteria**:
  - Startup/lock documentation clearly excludes FileVault preboot and Recovery.
  - No ordinary login item or display preset promises to fix an unreadable preboot screen.

### T53 Main-display assignment — [page 111](https://betterdisplay.pro/guide/faq/layouts/main-display/)

- **BetterDisplay behaviour** (tier unspecified): Making a display main reanchors the desktop layout; it does not automatically mirror, disconnect or present a virtual display. macOS determines window/Spaces consequences. A virtual main display remains invisible until it is viewed through a mirror, stream or remote client. Automation connects the desired screen before Set Screen Main.
- **FreeDisplay today**: ✅ Public CoreGraphics main-display assignment reanchors relative origins at `Apps/OpenDisplay/Sources/AppModel.swift:3178`, with tray access at `Apps/OpenDisplay/Sources/MenuBarView.swift:612`. 🟡 No matching main-display App Intent in `Apps/OpenDisplay/Sources/OpenDisplayIntents.swift:135`.
- **Implementation notes**: S/M, public CoreGraphics and AppIntents; verify observed origin/main identity and retain relative layout.
- **Acceptance criteria**:
  - Switching main preserves relative positions and does not imply a presentation connection.
  - Automation rejects an unavailable target or connects it in a separately observable step.

### T54 Splitting one monitor into virtual regions and Mission Control — [page 112](https://betterdisplay.pro/guide/faq/virtual-streaming/split-physical-monitor/), [page 117](https://betterdisplay.pro/guide/faq/virtual-streaming/mission-control/)

- **BetterDisplay behaviour** (PiP positioning/presentation: Pro; preset virtual creation: Free): Create separate virtual desktops and show each in its own PiP on one physical panel. For example, two 1920×1080 desktops stacked occupy 1920×2160; the total physical shape is 8:9 and each region is 16:9. Conversely, splitting a 9:16 portrait screen into two equal horizontal regions produces 9:8 regions; choose source geometry accordingly.
  For stable regions, choose the window level above menu/Dock/Spaces, disable title bar/shadow, save size/position, lock position, prohibit resizing and enable automatic start. The underlying physical desktop still exists. Each virtual source can be selected independently in a compatible screen-sharing app; PiP windows are not automatically independent input surfaces. Test startup and sleep/wake after changing physical topology. Source applications must run on the intended virtual screen; making an app fullscreen on the physical display does not confine it to a simulated region. Avoid self-capture recursion. Hardware PBP remains a separate multi-input option.
  Virtual displays share one macOS session and Mission Control/Spaces behavior, not independent user sessions. Normal/Keep Above windows can behave differently across Spaces from the above-menu/Dock/Spaces level.
- **FreeDisplay today**: 🟡 Primitive building blocks only. Up to four session virtual screens are allowed at `Providers/VirtualDisplayProvider/Sources/VirtualDisplayProvider.swift:52`, but `Apps/OpenDisplay/Sources/CapturePanel.swift:186` owns one presentation with a floating resizable panel (`Apps/OpenDisplay/Sources/CapturePanel.swift:124`). No simultaneous region configurations, level selector, locks, saved geometry or auto-start exists.
- **Implementation notes**: L, private CGVirtualDisplay plus public ScreenCaptureKit/AppKit. Persist many independent presentation configurations, distinguish source and target, and keep Spaces semantics explicit.
- **Acceptance criteria**:
  - Two independent sources display in correctly sized regions without capturing their own output.
  - Chosen level/locks persist across source reconnection and Spaces transitions.
  - Fullscreen app behavior is explained accurately; no claim of separate sessions.

### T55 Switching between a presented desktop and the underlying desktop — [page 113](https://betterdisplay.pro/guide/faq/virtual-streaming/switch-desktops/)

- **BetterDisplay behaviour** (Pro): A virtual-source stream can cover a physical desktop. With fullscreen window mode disabled, a shortcut to hide all fullscreen streams toggles their overlays; a per-stream Hide affects one. Hiding is separate from moving the cursor: Command-click the source or use layout/cursor actions as appropriate. Remote sharing of the virtual source can continue while local presentation is hidden. Windows behind the presentation may need to be moved back to the intended desktop.
- **FreeDisplay today**: ⬜ Missing fullscreen source-to-target presentation and hide/toggle behavior. Existing preview stop at `Apps/OpenDisplay/Sources/CapturePanel.swift:111` destroys the preview rather than temporarily hiding a live output; the tray's PiP action only opens Capture settings (`Apps/OpenDisplay/Sources/MenuBarView.swift:872`).
- **Implementation notes**: M after multi-presentation support, public AppKit window visibility plus independent capture lifetime and pointer commands.
- **Acceptance criteria**:
  - Hide reveals the original desktop without stopping an unrelated recorder/sharer.
  - Pointer relocation is an explicit separate action; hide/show preserves source and geometry.

### T56 Virtual physical dimensions and generated mode lists — [page 114](https://betterdisplay.pro/guide/faq/virtual-streaming/reported-physical-size/), [page 116](https://betterdisplay.pro/guide/faq/virtual-streaming/resolution-steps/)

- **BetterDisplay behaviour** (custom reported diagonal/mode-list tuning: Pro): Settings → Displays → virtual screen → Additional Resolution Settings exposes Reported diagonal size. The virtual reported diagonal derives physical millimeters from the aspect ratio; it does not independently change width/height or pixel aspect. General Settings → Additional Settings → Display physical dimensions supplies separate width/height metadata for matching UI scale among group members; it does not replace the virtual report. Reconnect applies reported-size changes.
  Physical-display flexible scaling need not be enabled for a virtual screen. Under Additional Resolution Settings, with Use custom resolution list disabled, the generator uses a configurable step multiplier. Lowering it produces finer steps after regeneration/reconnection. Relatively prime aspect components can make steps large; a simpler nearby aspect can give a more useful list. Limit resolution range and minimum/maximum bounds and a mode-count cap combine with refresh-rate and HDR variants; some combinations may be pruned. The FAQ does not specify a universal numeric cap.
  For Sidecar, create a matched-aspect virtual screen, associate it, disable streaming and enable mirroring when using this particular workflow, then choose the desired mode from Virtual Screen Mode. The create dialog is under Displays → Overview → Create New Virtual Screen, using Match aspect ratio of and associate to a display. Changing virtual refresh declarations does not increase Sidecar transport FPS.
- **FreeDisplay today**: 🟡 Partial definition validation, ⬜ metadata editor and generation. `Providers/VirtualDisplayProvider/Sources/VirtualDisplayRuntime.m:47` hardcodes physical size from 110 PPI and installs one mode at line 58. `Packages/DisplayDomain/Sources/DisplayDomain/VirtualDisplayDefinition.swift:22` limits dimensions to 640–8192 by 480–8192, rates to 24–120, and requires even HiDPI dimensions. There is no diagonal, mode list, step multiplier, association or separate layout-size metadata.
- **Implementation notes**: L, private CGVirtualDisplay with pure mode-generation logic and explicit limits. Show requested versus installed mode counts and reasons for pruning.
- **Acceptance criteria**:
  - A diagonal change preserves pixel geometry and is observed only after successful reconnect.
  - Generated combinations remain bounded and retain a usable fallback; pruning is visible.
  - Sidecar guidance does not confuse virtual nominal rate with delivered frames.

### T57 Virtual associations, inverse rules and manual control — [page 115](https://betterdisplay.pro/guide/faq/virtual-streaming/automatic-reconnection/)

- **BetterDisplay behaviour** (association entitlement unspecified): Under Settings → Displays → virtual screen → Associated Displays → Association Settings, ordinary association rules respond when any associated display is online; inverse rules respond when all are offline, with complementary connect/disconnect behavior. With an association and either automatic rule enabled, normal manual connection controls can be unavailable. Turn off Auto-connect virtual screen and Auto-connect virtual screen when all associated screens are offline to regain manual control; the association itself can remain. Disable both rule families for a manually controlled, continuously available source. Disconnect preserves the definition; discard/delete removes it.
- **FreeDisplay today**: ⬜ Missing association state machine. Session virtual handles exist at `Providers/VirtualDisplayProvider/Sources/VirtualDisplayProvider.swift:25`; the settings UI has create/remove only (`Apps/OpenDisplay/Sources/VirtualDisplaysSettingsView.swift:41`, line 59), without persistent disconnected definitions.
- **Implementation notes**: L, persistence and topology rules over private virtual lifecycle. Resolve rule conflicts explicitly and distinguish explicit rule disablement from transient topology events.
- **Acceptance criteria**:
  - Any-online and all-offline predicates produce deterministic complementary behavior.
  - Manual controls correctly reflect automatic-rule ownership; disabling both rules retains the association.
  - Disconnect/reconnect retains configuration; deletion requires a separate explicit action.

### T58 Workspace previews, oversized desktops and nonuniform stretching — [page 23](https://betterdisplay.pro/guide/faq/scaling/stretch-desktop/), [page 30](https://betterdisplay.pro/guide/faq/scaling/desktop-above-native/), [page 118](https://betterdisplay.pro/guide/faq/virtual-streaming/preview-smaller-monitor/)

- **BetterDisplay behaviour** (streaming/PiP: Pro; selecting existing desktop modes: Free): A virtual LoDPI 1080p/1440p desktop can preview a smaller workspace, but cannot reproduce another panel's PPI or physical size. Resize its PiP, or use stream Zoom/Underscan to add an appropriate border. Desktop-above-native modes add logical workspace through downsampling; they do not add panel detail. HiDPI/backing limits still apply.
  A non-native aspect may be letterboxed instead of stretched. Disable 1:1 Pixel Mapping before enabling Free Aspect Ratio; the latter is unavailable while direct pixel mapping is active. Select the physical target from the virtual source's streaming menu and place the app/game on that source. A stream's free-aspect behavior can intentionally fill a differently shaped target with distortion; ordinary macOS scaling and monitor scaling are distinct. Use source/target aspect, crop and zoom controls deliberately. A virtual source must actually be mirrored/streamed onto the target to become visible; creating it alone is insufficient.
- **FreeDisplay today**: 🟡 Partial. Existing above-native modes can be selected, and session virtual creation supplies alternate workspace sizes. Capture previews fit proportionally (`Apps/OpenDisplay/Sources/CapturePanel.swift:131`); the central crop transform at `Providers/CaptureProvider/Sources/CaptureImageTransform.swift:6` has no free-aspect stretch, zoom/underscan or full-target placement.
- **Implementation notes**: M, public CoreImage/Metal transforms and AppKit geometry, atop private virtual source creation where needed. Keep crop, proportional fit, nonuniform stretch and physical timing separate.
- **Acceptance criteria**:
  - Preview labels state logical size and do not claim to emulate another monitor's physical pixel density.
  - Fit, crop, stretch and underscan have independently understandable results.
  - An oversized desktop retains an obvious route to a normal mode and displays rendering-limit failures.

### T59 Dock presence while PiP is open — [page 119](https://betterdisplay.pro/guide/faq/virtual-streaming/pip-dock-icon/)

- **BetterDisplay behaviour** (tier unspecified): Dock visibility defaults to appearing when Settings is open. Other policies show it whenever any window is open, including PiP, or always. These are application-presence policies, not a capture setting.
- **FreeDisplay today**: ⬜ Missing policy selection. The menu-bar application at `Apps/OpenDisplay/Sources/OpenDisplayApp.swift:6` has no equivalent Dock-presence preference; PiP is created as an auxiliary panel at `Apps/OpenDisplay/Sources/CapturePanel.swift:124`.
- **Implementation notes**: S, public AppKit activation policy and window lifecycle accounting.
- **Acceptance criteria**:
  - Settings-only, any-window and always policies behave consistently while opening/closing PiP.
  - Changing Dock presence does not restart capture or change its source.

### T60 Capture stopped by the system and meaningful diagnostics — [page 120](https://betterdisplay.pro/guide/faq/virtual-streaming/stream-stopped/)

- **BetterDisplay behaviour** (Pro streaming/PiP): A system-stop message reports a capture lifecycle event, not its root cause. Investigate use of the macOS sharing menu, disappearance of the source, sleep and permission changes. Preserve the exact error, time and context; verbose launch logging using the app's -v option can help. Calling a stop unintentional is a classification, not an explanation. Restarting capture can be sufficient; recreating the virtual display is not automatically necessary.
- **FreeDisplay today**: 🟡 Partial. ScreenCaptureKit stop errors are retained at `Apps/OpenDisplay/Sources/CapturePanel.swift:144`; a two-second watchdog checks source presence at line 91. No structured stop-reason timeline, targeted retry policy or user-facing diagnostic export exists. Capture also stops when its settings view disappears (`Apps/OpenDisplay/Sources/CapturePanel.swift:220`), an application-owned lifetime constraint rather than a macOS failure.
- **Implementation notes**: M, public ScreenCaptureKit callbacks and structured lifecycle logs. Distinguish user stop, source loss, permission denial, view teardown and system error; restart only the affected presentation.
- **Acceptance criteria**:
  - Each stop retains its exact error and whether it was user initiated.
  - Switching settings sections cannot be reported as a system capture fault.
  - Recovery can restart capture without deleting or recreating a healthy source display.

### T61 PiP tabs — [page 121](https://betterdisplay.pro/guide/faq/virtual-streaming/pip-tabs/)

- **BetterDisplay behaviour** (Pro): With more than one PiP and visible title bars, the context menu can merge windows into a tabbed group, show all tabs or move a tab into a new window. The source configurations remain independent. This does not apply to Video Filter Windows.
- **FreeDisplay today**: ⬜ Missing. One presentation/window is owned by `Apps/OpenDisplay/Sources/CapturePanel.swift:186`; no multi-window tab grouping exists.
- **Implementation notes**: M after multi-PiP support, public AppKit tabbing with explicit eligible window types.
- **Acceptance criteria**:
  - Merge and detach preserve each source, crop and filter configuration.
  - Ineligible filter windows never offer tab operations.

### T62 Pause/freeze versus stop and hide — [page 122](https://betterdisplay.pro/guide/faq/virtual-streaming/freeze-presentation/)

- **BetterDisplay behaviour** (Pro): Pause freezes the last presented frame; stop ends the presentation; hide reveals the desktop underneath while a stream may remain active. A pause-all shortcut applies to PiPs and fullscreen streams. Freezing an image is not a privacy guarantee: another capture route may still see the changing source.
- **FreeDisplay today**: ⬜ Missing pause/hide semantics and global shortcut. Start/stop at `Apps/OpenDisplay/Sources/CapturePanel.swift:55` and `Apps/OpenDisplay/Sources/CapturePanel.swift:111` replace or destroy the single preview; no retained frozen-frame state exists.
- **Implementation notes**: M, public capture/render pipeline with independent source-running, visible and paused flags.
- **Acceptance criteria**:
  - Pause retains the last frame and resumes the same source; stop releases its resources.
  - Hide does not imply pause, and a pause-all action updates only intended presentations.
  - The UI never describes a frozen local preview as guaranteed protection from other recorders.

### T63 PiP automatic start and persistence — [page 123](https://betterdisplay.pro/guide/faq/virtual-streaming/pip-auto-start/)

- **BetterDisplay behaviour** (Pro): Start Automatically belongs to each PiP configuration and runs when a source connects; it does not itself connect a virtual display. An active PiP can resume after wake, and an automatically started one may retry an unintentional interruption while the source remains connected. Manually closing it leaves it closed until a subsequent source reconnection rather than immediately reopening it.
- **FreeDisplay today**: ⬜ Missing persistent presentation configurations and auto-start. Capture state is owned by the Settings panel (`Apps/OpenDisplay/Sources/CapturePanel.swift:186`), and on disappearance it stops (`Apps/OpenDisplay/Sources/CapturePanel.swift:220`). Virtual creation is an independent session-only operation (`Apps/OpenDisplay/Sources/VirtualDisplaysSettingsView.swift:7`).
- **Implementation notes**: M/L, application-level presentation coordinator and persisted definitions, using public lifecycle notifications/ScreenCaptureKit. Retain manual-close suppression until the documented reconnection boundary.
- **Acceptance criteria**:
  - A connected source starts only configurations with auto-start enabled.
  - Closing a PiP manually suppresses immediate retry; a later reconnection resets that suppression.
  - Switching settings pages leaves active PiPs alive and wake resumes only eligible configurations.

### T64 Multiple cropped views from one source — [page 124](https://betterdisplay.pro/guide/faq/virtual-streaming/multiple-cropped-pips/)

- **BetterDisplay behaviour** (Pro): Enable a PiP, draw its crop on the source, then add additional numbered PiP configurations for independent regions of the same screen. Each retains its own crop, transform, filters and window geometry. Cropped aspect normally determines the fitting aspect unless free-aspect behavior is enabled. The source content must already exist; cropping does not create additional workspaces.
- **FreeDisplay today**: 🟡 Partial transforms, ⬜ multi-configuration workflow. `Apps/OpenDisplay/Sources/CapturePanel.swift:204` offers a single symmetric center-inset crop from 0 to 0.4, implemented at `Providers/CaptureProvider/Sources/CaptureImageTransform.swift:6`. There is no arbitrary drawn rectangle, numbered configurations or independent simultaneous windows.
- **Implementation notes**: M/L, public ScreenCaptureKit/Metal/CoreImage with one shared source where useful and independent output transforms. Validate crops against changing source dimensions.
- **Acceptance criteria**:
  - Two arbitrary crops update independently without changing the shared source.
  - Crop rectangles survive source resolution changes through a documented normalization/clamping rule.
  - Free-aspect behavior is explicit; default fitting preserves the cropped aspect.

### T65 Teleprompter flipping and extended targets — [page 125](https://betterdisplay.pro/guide/faq/virtual-streaming/flip-teleprompter/)

- **BetterDisplay behaviour** (Pro): Stream an existing physical source to a separate extended target and flip it horizontally/vertically as needed; ordinary mirroring is not the same transformed presentation path. Sidecar can provide an iPad target. A virtual display is needed only when a separate desktop is wanted. Stop the presentation through its controls rather than disabling an unrelated screen.
- **FreeDisplay today**: 🟡 Partial. Horizontal/vertical flips and quarter-turns are implemented in `Providers/CaptureProvider/Sources/CaptureImageTransform.swift:12` and exposed at `Apps/OpenDisplay/Sources/CapturePanel.swift:200`. They operate in the floating preview, without full-target source-to-screen routing or Sidecar workflow.
- **Implementation notes**: M, public capture/transforms and AppKit target-window placement. Keep mirroring and transformed streaming distinct and handle source/target disappearance.
- **Acceptance criteria**:
  - Flip a physical-source preview without creating an unnecessary virtual screen.
  - A configured extended target shows the correctly transformed image; stop restores its underlying desktop.

### T66 Nearest-neighbor scaling for games — [page 126](https://betterdisplay.pro/guide/faq/virtual-streaming/integer-scaling-games/)

- **BetterDisplay behaviour** (Pro): The option called Integer Scaling selects nearest-neighbor sampling; it does not force the output size to an integer multiple. A 1920-wide source on 3840 pixels is an exact 2× example. Fractional factors produce uneven pixel sizes, and later scaling by the OS/panel can resample the result again. This does not remove blur generated inside the game or solve game performance limitations.
- **FreeDisplay today**: ⬜ Missing selectable sampling policy. Capture displays a proportionally fitted image at `Apps/OpenDisplay/Sources/CapturePanel.swift:131`, without nearest-neighbor or whole-factor geometry controls.
- **Implementation notes**: S/M, public Metal/CoreImage sampler selection plus actual backing-pixel geometry. Label nearest-neighbor separately from optional integer-factor window sizing.
- **Acceptance criteria**:
  - At exactly 2×, each input pixel occupies a uniform 2×2 output block before any later scaling.
  - Fractional sizing is allowed only with a clear distinction from true integer-factor geometry.

### T67 Recording desktops and FFmpeg interoperability — [page 127](https://betterdisplay.pro/guide/faq/virtual-streaming/record-with-ffmpeg/), [page 128](https://betterdisplay.pro/guide/faq/virtual-streaming/create-recording-desktop/)

- **BetterDisplay behaviour** (preset virtual creation: Free; PiP viewing: Pro): Create a preset virtual desktop through Settings/Overview, choosing a 16:9 HD/4K/5K/6K definition, connect it and select the desired logical size. Grant capture permission separately to the viewing and recording applications, and inspect a recorded sample. If the status icon opens Settings, close Settings to return to ordinary menu access. Disconnecting a temporary virtual display retains its definition; discard/delete is a separate confirmed action. A custom 16:9 physical scaled resolution is a Free alternative for recording composition, but does not necessarily change the physical timing.
  FFmpeg can capture through AVFoundation after enumerating its current device list. The capture index is not a CoreGraphics display ID; the FAQ's index 2 is only an example and must be replaced with the actual index. Selecting no audio is a deliberate example, not an audio limitation of every recorder. Each recorder needs its own permission. BetterDisplay CLI/HTTP control does not expose a live video stream.
- **FreeDisplay today**: 🟡 Session virtual screens provide potential external-recorder sources, but only manual width/height/rate creation (`Apps/OpenDisplay/Sources/VirtualDisplaysSettingsView.swift:13`) and no preset library or retained disconnected definitions. Capture explicitly disables audio at `Apps/OpenDisplay/Sources/CapturePanel.swift:81` and has no file encoder. The local HTTP panel lists control endpoints only (`Apps/OpenDisplay/Sources/LocalControlPanel.swift:33`); it is not a media endpoint. No FFmpeg capture was executed in this audit.
- **Implementation notes**: S/M for preset definitions and recorder guidance, L if adding a native recorder using public ScreenCaptureKit/AVFoundation. Define output dimensions, FPS, color and audio explicitly.
- **Acceptance criteria**:
  - A recorder can select the connected virtual source from its own enumerated list and produce a verified sample.
  - Recording help never substitutes a CG display ID for an AVFoundation index.
  - Disconnect, delete and stop recording remain separate; HTTP control is not advertised as video transport.

### T68 Overlay capture exclusion, DisplayLink and recursion — [page 129](https://betterdisplay.pro/guide/faq/brightness/screenshots-and-overlays/), [page 133](https://betterdisplay.pro/guide/faq/virtual-streaming/pip-capture-exclusion/)

- **BetterDisplay behaviour** (software-method entitlement varies; PiP/streaming: Pro): Dimming/effect overlays can make a window picker select an overlay, producing a blank/fullscreen-looking capture. Preventing overlays from being captured excludes the effect, but the picker may still choose the wrong window. Region capture or temporarily suspending effects are alternatives; do not disable the custom-profile gamma safeguard merely to avoid an overlay.
  On DisplayLink, disabling overlay capture exclusion across **all displays**, including native ones, may reduce lag/CPU load, but effects then become visible to capture. DisplayLink Manager's external option for automatic video-call overlay detection can be another factor; turning it off can hide call overlays. This is a driver setting, not a BetterDisplay feature. Capture exclusion also affects the app's own streams/PiPs.
  Excluding PiP from capture prevents recursion in BetterDisplay's own capture path; it is not a promise that OBS or a meeting app will exclude it. Share another source/desktop or use that recorder's app/window exclusions, and inspect the recipient preview.
- **FreeDisplay today**: 🟡 Partial. Dimming and XDR windows set `sharingType = .none` at `Apps/OpenDisplay/Sources/DimOverlayController.swift:64` and `Apps/OpenDisplay/Sources/XDRBrightnessController.swift:92`, without a user toggle or DisplayLink-specific policy. Display capture excludes the **entire FreeDisplay application** at `Apps/OpenDisplay/Sources/CapturePanel.swift:68`; that avoids self-recursion but is broader than a per-PiP exclusion and says nothing about external recorders. It can also exclude other app-owned visuals that a user expected to capture.
- **Implementation notes**: M, public ScreenCaptureKit content filters and AppKit sharing flags, with OS/driver-specific verification. Prefer per-window exclusion when possible and state exactly which capture path honors it.
- **Acceptance criteria**:
  - Test app-owned capture, screenshots and an external recorder separately; report different behavior honestly.
  - A configurable exclusion policy can be compared across all displays without silently reenabling unsafe gamma.
  - Preventing recursion does not promise confidentiality from other capture applications.

### T69 Protected video and notifications while sharing — [page 130](https://betterdisplay.pro/guide/faq/virtual-streaming/protected-video/), [page 132](https://betterdisplay.pro/guide/faq/virtual-streaming/mirroring-notifications/)

- **BetterDisplay behaviour** (platform/content restrictions, no paid bypass): Virtual displays do not provide HDCP. Mirroring to a physical display does not add HDCP to the virtual source; buying Pro, enabling HDR or advertising a higher mode cannot change that. Stop/disconnect the virtual route and use a supported physical path when the content service requires it. Browser/service/cable requirements still apply; the FAQ cites HDCP 2.2 for a relevant external UHD Netflix path. Black video can also have other causes, so do not diagnose every black rectangle as DRM.
  macOS Notifications can be allowed while mirroring/sharing through the OS setting. That switch applies beyond BetterDisplay and changes privacy exposure for other sharing apps; it is not a per-presentation toggle.
- **FreeDisplay today**: ➖ HDCP circumvention is not an applicable feature. Current private virtual creation (`Providers/VirtualDisplayProvider/Sources/VirtualDisplayRuntime.m:14`) and ScreenCaptureKit capture (`Apps/OpenDisplay/Sources/CapturePanel.swift:55`) do not establish protected-content support. 🟡 Missing explanatory help and a link to the relevant OS notification setting; no app-specific notification policy exists.
- **Implementation notes**: S, diagnostic/help integration using public APIs. Do not attempt to bypass protected-content controls or silently change the global notification preference.
- **Acceptance criteria**:
  - Explain the physical-route prerequisite without claiming every black video has the same cause.
  - Notification guidance states its global scope and lets the user make the OS change.

### T70 Portrait AirPlay/Sidecar, lock-screen visibility and remote coordinates — [page 135](https://betterdisplay.pro/guide/faq/virtual-streaming/portrait-airplay/), [page 136](https://betterdisplay.pro/guide/faq/virtual-streaming/remote-click-offset/), [page 137](https://betterdisplay.pro/guide/faq/virtual-streaming/hidden-login-screen/), [page 138](https://betterdisplay.pro/guide/faq/virtual-streaming/portrait-sidecar/)

- **BetterDisplay behaviour** (streaming/rotation: Pro; external connection and OS restrictions are separate): Establish AirPlay as an extended display first; BetterDisplay does not initiate the AirPlay connection. Present a 9:16 virtual source with a 90°/270° stream rotation to use a physically portrait receiver. Show on Lock Screen requires the appropriate overlay path with fullscreen window mode disabled, and the virtual source must not be configured to disconnect on lock. This does not keep the Mac awake or guarantee that capture/AirPlay survives lock, sleep or logout.
  To keep a virtual presentation from covering session login, disable Show on Lock Screen or globally disconnect virtual screens on lock/screensaver and reconnect the same intended set on desktop return. Retain definitions; apps may relocate when screens disappear. This is unrelated to FileVault preboot.
  For Sidecar, start the iPad in landscape, create a matching-aspect associated virtual source, enable its stream and select portrait rotation: 90° for the port-down orientation described by the guide, 270° for port-up. A missing/disabled streaming control can reflect capture permission; grant permission and reopen the dialog. Keep the virtual source beside a working desktop and the Sidecar target in a corner. Command-click/Warp Cursor can move the pointer to the source; an Option-revealed experimental Prevent Cursor Entering setting can keep it off the presentation target. Pencil/touch input is not automatically forwarded by video streaming. Avoid applying both shape changes and rotation incorrectly.
  Lock iPad orientation in landscape before physically rotating it; if Sidecar starts sideways, restart the Sidecar session. Restore normal orientation policy when returning to ordinary use. For a blank image, inspect the intended target, capture permission and hidden state.
  Some remote clients misplace clicks with tall stacked display layouts. Compare side-by-side or a shorter stack with unchanged modes, reconnect the remote session and observe actual pointer position versus client coordinates. Record client/version and geometry, including a physical-display comparison. A dummy plug or resetting the virtual display may not fix client coordinate handling; preserve the known-working layout.
- **FreeDisplay today**: 🟡 Partial quarter-turn transforms (`Apps/OpenDisplay/Sources/CapturePanel.swift:201`) and layout/main controls (`Apps/OpenDisplay/Sources/AppModel.swift:3178`), ⬜ associated portrait presentation, pointer warp/fencing, lock-screen presentation policy and remote-coordinate diagnostics. The single floating preview at `Apps/OpenDisplay/Sources/CapturePanel.swift:124` is not a target-aware fullscreen stream; session-only virtual definitions cannot implement reliable lock/reconnect sets.
- **Implementation notes**: L, public ScreenCaptureKit/AppKit/layout events, private CGVirtualDisplay and possibly private lock/presentation behavior. Keep video transforms separate from input-coordinate transforms and OS-owned AirPlay/Sidecar sessions.
- **Acceptance criteria**:
  - AirPlay and Sidecar portrait workflows show the correct image and pointer mapping with independently established OS connections.
  - Lock policy is reversible, preserves definitions and never promises FileVault or logout operation.
  - Permission failures, hidden streams and disconnected targets have distinct diagnostics.
  - A remote-coordinate report preserves exact origins, sizes, scales and client version; a safe layout remains recoverable.

## Backlog

**54 items: P0 8 / P1 9 / P2 31 / P3 6.** P0 addresses concrete gaps in existing code; runtime impact still requires the targeted acceptance checks. P1 prioritizes valuable public-API work, including free guide capabilities. P2 covers Pro-equivalent or private/privileged integrations, even when the guide offers part of a workflow for free. P3 covers specialist workflows. API risk names describe the implementation boundary, not permission to bypass platform safeguards. Closely related topics share items; non-applicable OS, hardware and licensing limitations are documented as constraints rather than promised features.

| ID | Priority | Item | Effort | API risk | Notes |
| --- | --- | --- | --- | --- | --- |
| FB-01 | P0 | Use one physical-screen safety and identity policy | L | Mixed public/private | T41, T44–T49: replace single-mode placeholder inference; distinguish own/third-party virtual, DisplayLink, inactive and sleeping physical outputs. Apply it to disconnect, blackout, auto-disconnect, wake rescue and sleep ownership. |
| FB-02 | P0 | Preserve complete favorite mode identities | M | Public | T06: migrate keys to retain exact refresh, framebuffer, density and depth; display unavailable favorites without substituting. |
| FB-03 | P0 | Keep size-only slider changes within the current format | M | Public | T05–T06, T10: choose preserving variants before native/HiDPI preference; reveal unavoidable rate/density/depth changes. |
| FB-04 | P0 | Make gamma bypass real and honor custom-profile safety | M | Public; OS compatibility | T21, T26: overlay-only must not call gamma; guard custom profiles globally, propagate failures and provide recoverable fallback. |
| FB-05 | P0 | Bind EDID export to the actual selected display | M | Public IOKit; identity risk | T15, T41: remove product-only/tree-order guesses; return exact identity or ambiguity and preserve all extension bytes. |
| FB-06 | P0 | Separate requested, delivered and observed DDC state | M | Private IOAVService | T31, T33–T35: fix optimistic input success, retain write failures and readback uncertainty; protocol agreement is not physical brightness proof. |
| FB-07 | P0 | Preserve ICC identity and expose assignment failure | S | Public ColorSync | T30: do not deduplicate by display name; inspect setter results and refresh the actual profile identity. |
| FB-08 | P0 | Gate DDC probing on risky legacy Apple displays | M | Private; hardware risk | T32: native failure currently permits generic external DDC fallback. Add model-aware eligibility before probing, with a distinct expert override. |
| FB-09 | P1 | Unify mode information, filters and resolution bounds | M | Public CoreGraphics | T02, T05, T10: separate logical/backing/signal data; unify tray/settings filters, keep current modes visible and add bounds. Tier-unspecified UI first; do not claim private timing data. |
| FB-10 | P1 | Add capability-based help and reproducible diagnostics | M | Public; read-only | T01–T04, T21, T42, T52, T69: troubleshooting navigation, controlled performance comparisons, protected-content/notification/preboot limits and local diagnostic export. |
| FB-11 | P1 | Explain profile selection and calibration accurately | S | Public ColorSync | T30: identify installed profiles, open ColorSync assistance and distinguish hardware calibration, profiling and HDR. |
| FB-12 | P1 | Make sleep assertions explicit and correctly owned | M | Public IOKit | T49: per-display policy, assertion type/owner visibility and release after topology changes; fix safety input first. |
| FB-13 | P1 | Implement retained offline records and confirmed forgetting | M | Public persistence | T46: configurable retention, reset versus forget, association cleanup and no claim that forgetting disconnects hardware. |
| FB-14 | P1 | Expose main-display assignment through App Intents | S | Public CoreGraphics/AppIntents | T53: connect/resolve target before reanchoring; report observed main identity and preserve relative origins. |
| FB-15 | P1 | Add Dock visibility policies | S | Public AppKit | T59: Settings-only default, any-window and always; keep presentation lifetime independent. |
| FB-16 | P1 | Add external recording and source-selection guidance | S | Public AVFoundation/OS UI | T67: current AVFoundation indices, per-recorder permissions, sample verification, source dimensions and no HTTP video claim. |
| FB-17 | P2 | Implement staged system display configuration installation | L | Privileged; undocumented override format | T03, T08, T13, T16, T28: individual Free custom sizes first; model-wide scope, role/name/native settings, Apply/Undo, authorization, activation and multi-user conflicts. |
| FB-18 | P2 | Add flexible scaled-mode generation and supported limits | L | Undocumented overrides/private virtual APIs | T03, T05: Pro generation, sub-720p and over-8K opt-ins, requested versus available modes; DisplayLink transport-specific exclusions. |
| FB-19 | P2 | Implement temporary EDID apply/unapply with recovery | L | Private framebuffer SPI | T14–T15: import stays inert; preserve factory bytes, identity continuity, safe startup and automatic-rule ownership. |
| FB-20 | P1 | Decode DisplayID and validate complete EDID reports | M | Public parsing/IOKit | T15: extension/tile/timing diagnostics and incomplete-block warnings; device writing is explicitly excluded. |
| FB-21 | P2 | Add connection timing, rate and format inspection/control | L | Private framebuffer/SkyLight | T07, T10–T12, T29: distinguish nominal/current/VRR values, RGB/chroma/range/depth, complete availability and timed recovery. |
| FB-22 | P2 | Add HDR status and forced HDR with qualification | L | Private connection APIs | T12, T25: distinguish allow-forced, effective HDR and SDR peak brightness; preserve a known-working mode. |
| FB-23 | P2 | Extend protection to per-property SDR/HDR state | L | Mixed public/private | T09: separate mode/rate/HDR/color format/HDR profile, saved-value UI, own-change updates, unavailable states and bounded restoration. |
| FB-24 | P2 | Implement true hardware/software combined brightness | L | Private native/DDC plus public effects | T18: configurable hardware floor/raw bounds/software zero, continuous transitions, controller locks and explicit screen-off-at-zero policy. |
| FB-25 | P2 | Add coherent startup/wake brightness restoration | M | Mixed public/private | T17, T48: no restore/non-brightness/full restore, safe full-dim exceptions and delayed eligible DDC replay; never replay command-only controls. |
| FB-26 | P2 | Add native auto-brightness management and group roles | M | Private native controls | T19: management versus OS state, explicit source/receiver, external-change policy and loop-free offset behavior. |
| FB-27 | P2 | Add nits provenance, anchors and group matching | L | Mixed metadata/private controllers | T20: measured/reported/estimated values, sustained/peak distinction, manual-anchor persistence and saturation at physical limits. |
| FB-28 | P2 | Add effect activation, suspension, reset and explicit intents | M | Public effects/AppIntents; private HDR dependency | T22, T27: distinguish master off, color-only suspension, full reset, LUT assignment and idempotent HDR/SDR sequences. |
| FB-29 | P2 | Qualify software XDR and add readiness controls | L | Public Metal/EDR; OS-dependent | T23: identify the existing software trigger accurately; measure transitions/load and avoid unsupported direct-mode claims. |
| FB-30 | P2 | Implement supported direct built-in XDR/preset exit | L | Private Apple preset/brightness APIs | T23: eligible hardware only, force-EDR default, saved auto/brightness context and reliable ordinary-preset exit. |
| FB-31 | P2 | Add GPU dithering and uniformity-state diagnostics | L | Private framebuffer/IORegistry | T29: active-port association, trustworthy state reads, persistence and clear GPU-versus-panel scope. |
| FB-32 | P2 | Add editable DDC control ranges and input sources | M | Private IOAVService | T18, T31, T33–T35: labels/visibility/raw source values, write-only support, readback polling default off and safe optional capability discovery. |
| FB-33 | P2 | Add managed hardware-contrast automation | M | Public AppIntents/private DDC | T35: normalized units, explicit hardware target, UI/cache semantics and distinct raw VCP commands. |
| FB-34 | P2 | Build paired LG network control and wake automation | L | Vendor network protocol; firmware risk | T36: secure pairing, picture locks, relative/absolute volume, source selection, WOL prerequisites and cancellable delayed retries. |
| FB-35 | P2 | Build paired Philips and Samsung remotes | L | Vendor network protocols | T37, T39: model-specific key capabilities, Philips source navigation and Samsung relative-only volume; no invented hardware brightness. |
| FB-36 | P2 | Complete selective auto-disconnect and wake intent policy | L | Private lifecycle SPI | T44–T45, T47, T51–T52: ignore lists, manual override, post-wake-main protection, bounded delayed redisconnection and explicit recovery. |
| FB-37 | P2 | Add framebuffer reinitialization with factory fallback | L | Private framebuffer/adapter APIs | T50: manual eligibility and verification before default-off wake automation; keep adapter reset separate. |
| FB-38 | P2 | Persist virtual definitions and disconnected instances | L | Private CGVirtualDisplay | T43, T56–T57, T67: independent create/connect/disconnect/delete, startup restore, named presets and stable identity; retain safe physical access. |
| FB-39 | P2 | Add virtual association and KVM presentation rules | L | Private virtual lifecycle; public topology | T43, T57: any-online/all-offline rules, manual-control ownership, persistent sources and reestablished mirror relationships. |
| FB-40 | P2 | Add virtual geometry and generated refresh/mode lists | L | Private CGVirtualDisplay | T11, T56: reported diagonal separate from group dimensions, bounded step generator, 24–240 guide target with platform qualification and 60-Hz fallback. |
| FB-41 | P2 | Implement HDR virtual and capture pipelines | L | Private virtual metadata/public HDR capture | T24: reconnect semantics, SDR alternatives retained unless HDR-only is explicitly chosen, extended precision/transfer/color metadata and receiver qualification; no reference-preset emulation. |
| FB-42 | P2 | Move capture lifetime into a persistent coordinator | M | Public ScreenCaptureKit | T60, T63: survive settings navigation, classify stops, preserve errors and implement source-aware retry/manual-close semantics. |
| FB-43 | P2 | Add multiple independent PiP/region configurations | L | Public ScreenCaptureKit/AppKit | T54, T61, T64: drawn crops, numbered outputs, saved geometry/levels/locks, tabs and independent sources/filters. |
| FB-44 | P2 | Implement fullscreen source-to-target presentation | L | Public capture/AppKit; lock behavior may be private | T55, T58, T65, T70: target placement, pointer controls, flip/rotation, fit/stretch/zoom/underscan and a recoverable underlying desktop. |
| FB-45 | P2 | Separate pause, hide, stop and automatic start | M | Public capture/AppKit/AppIntents | T55, T62–T63: frame freeze versus overlay visibility, all-presentation actions and no privacy guarantee. |
| FB-46 | P2 | Add configurable capture sampling and performance telemetry | M | Public Metal/ScreenCaptureKit | T04, T11, T66: target FPS, actual delivered frames/drops, nearest-neighbor versus integer geometry and source/output size. |
| FB-47 | P2 | Make overlay/PiP exclusion configurable and scoped | M | Public capture/AppKit; driver variance | T68: per-window exclusion, DisplayLink comparisons, no external-recorder guarantee and no unsafe gamma workaround. |
| FB-48 | P2 | Implement session lock presentation policy | L | Public lifecycle/private presentation qualification | T70: show/hide versus disconnect, retain definitions and exact reconnect sets; exclude FileVault/logout guarantees. |
| FB-49 | P3 | Add an expert CRT connection-timing workflow | L | Private timing APIs; hardware risk | T07: low timing selection, original-ID recovery and 1:1/top-left placement; dependent on general connection controls. |
| FB-50 | P3 | Add model-specific PBP and tiled-monitor diagnostics | M | Private DDC if control is enabled | T08, T40: verified PBP command values, per-input modes, dual-link evidence; no claim that virtual crops create synchronized native tiles. |
| FB-51 | P3 | Consider physical EDID writing only as a separate expert tool | L | Private I2C; potentially persistent hardware damage | T15: defer by default; if implemented, preserve original bytes, enforce actual device limits and distinguish send/readback/durability. |
| FB-52 | P3 | Add gated LG service-menu access after ordinary control | M | Vendor protocol; high operational risk | T38: Option-revealed expert controls, ready paired target, explicit access changes and no guessed firmware parameters. |
| FB-53 | P3 | Add remote-coordinate and portrait workflow diagnostics | M | Public geometry; client-specific | T70: preserve safe layouts, record client geometry/version, compare side-by-side placement and distinguish video from input mapping. |
| FB-54 | P3 | Investigate compositor self-stream/filter windows | L | Potential private compositor APIs | T27, T61: distinct backend/permissions/options, recursion handling, effect latency and no unsupported FPS/HDR-pipeline controls. |

