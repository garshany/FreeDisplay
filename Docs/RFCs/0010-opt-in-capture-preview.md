# Opt-in capture preview — experimental implementation review

Status: local experimental implementation; hardware and TCC acceptance outstanding.

## Threat and recovery review

Captured screen content is sensitive. Enumeration occurs only after an explicit Load sources
button, and streaming only after source choice and Start PIP. No startup capture, saved source,
audio, recording, network, screenshot persistence or automatic permission grant is introduced.
Own application windows are excluded from display capture, and window lists exclude own PID.
The UI identifies capture as experimental SDR preview and keeps macOS screen-sharing indicators.

Memory/CPU costs are bounded by a 1920-pixel maximum dimension, 30 fps and three queued frames.
LUT input is capped at 16 MB and 64 cubed samples, checked before allocation/application.
Malformed or unsupported LUTs preserve the existing transform and show the error.

Stop, preview-close and settings-section disappearance stop the stream and release the preview.
Late output checks stream identity. Startup uses a generation token, so Stop during an async
start cannot reopen a preview. Delegate errors and source loss release stream/preview; source
presence is checked every two seconds. This does not promise detection of every OS compositor
stall, and system stop errors are surfaced rather than claimed as proven system shutdown.
The independent rescue command and topology transaction engine are untouched.

## Acceptance still required

Permission denial and grant/relaunch; display/window live PIP; source destruction and display
unplug; close during startup; own-window exclusion; sustained memory/CPU; LUT identity visual
comparison. HDR fidelity and calibrated monitor output are outside this SDR preview's claims.

## Follow-up local test evidence

The image path is shared with a generated-frame rendering harness; identity, flip, quarter-turns,
crop bounds and identity/inversion LUT pixels passed without capturing user content. Standalone
strict Swift 6/MainActor typechecking passed after adding deinit cleanup and stale callback guards.
Lifecycle behavior is reviewed but not yet verified with real permission or source-close/unplug
operations. The capture UI's own strings and parser error descriptions are now Russian.
