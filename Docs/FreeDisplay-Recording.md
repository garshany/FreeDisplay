# An independent FreeDisplay recording workspace

FreeDisplay supplies a temporary desktop and a local SDR picture-in-picture preview. An external
recorder or meeting app selects and encodes/shares its own source. FreeDisplay does not supply a
file recorder, network video server, HTTP video endpoint or protected-content bypass.

## Before setup

Keep a physical working desktop, keyboard and independent recovery route. Record arrangement,
main display and mode. Virtual creation uses private macOS APIs, needs the experimental opt-in and
physical recovery screen, and is disabled in Safe Mode/public-only builds. Existing limits remain:
four session endpoints and the virtual definition validator's supported dimensions/rates. Saved
virtual definitions, restoration after app relaunch and saved multi-PiP recipes await FD-094/FD-085.
Do not depend on this temporary source for headless login, FileVault, Recovery or unattended restart.

Grant Screen Recording separately to **FreeDisplay for preview** and **each external recorder or
meeting application for capture** in macOS Privacy & Security. Apply any relaunch that macOS/the
recorder requests. Creating a virtual display itself does not grant capture permission. CLI/terminal
capture may associate permission with its hosting app; check the actual recording process separately.
A working FreeDisplay preview proves nothing about another application's permission.

## Create, select and verify

1. In Settings → Virtual Displays opt in and create a clearly named independent source. For a
   1920×1080 logical HiDPI workspace, request **3840×2160 pixels** and enable half-size HiDPI;
   select/check the actually offered mode in Displays. A request is not proof of offered mode.
2. Keep the physical display main; arrange the virtual desktop adjacent in Arrange. Move only
   demonstration windows onto it. Private windows, notifications and microphone audio need their
   own privacy review; this is an additional shared desktop in the same user session, not isolation.
3. In Settings → Screen Capture refresh sources, select that display and Start. The floating
   preview is app-owned and survives leaving the settings page. It is a view, not a pointer/input
   forwarding surface. Stop explicitly or close the preview to end it. Resizing the preview changes
   local viewing only. Capture currently requests SDR, at most 1920 pixels on its longest axis and
   30 FPS, with audio/file recording off; these are not external-recorder output settings.
4. With external outputs stopped, choose that **actual display** in OBS/your meeting app's current
   source list, rather than the PiP window or physical desktop. Configure canvas/scaled output
   independently; for a full-HD sample choose 1920×1080, reset the source transform and fit all edges
   without stretching. Check extra recording rescale options, selected frame rate, color and a
   writable destination with available space. Mute microphone/system/other audio for the first
   visual-only sample. These are operator choices, not new FreeDisplay limits/defaults.
5. Record a motion sample, stop and wait for the file to finish. Play the saved file and inspect
   dimensions, readable text, all four corners, motion, silence and absence of private content.
   Inspect the remote recipient's preview separately for meetings. A moving source selector or
   successful API call is not output verification. Logical workspace, backing pixels, preview pixels
   and encoded output pixels are four separate values; 2× HiDPI alone does not choose encoder size.

### Using the PiP window instead

If an external recorder offers window capture, its own picker may expose FreeDisplay's visible
preview window. Choose it explicitly only when you intend to record that transformed SDR preview,
including its current crop/flip/LUT and preview resolution limit. This is a different source from
the complete virtual desktop. Preview resizing can change the recorder's source-window geometry;
refit and inspect its independently configured encoded output again. Keep private windows out,
check frame edges and avoid capturing a preview of the recorder itself. FreeDisplay's own
app-exclusion filter does not exclude this window from someone else's capture.

### FFmpeg / AVFoundation alternative

If FFmpeg is already installed, enumerate its **current** AVFoundation list in the intended session:

```sh
ffmpeg -f avfoundation -list_devices true -i ""
# Replace VIDEO_INDEX with the screen's current AVFoundation video index:
ffmpeg -f avfoundation -i "VIDEO_INDEX:none" /chosen/writable/path/sample.mov
```

Stop recording through the recorder’s normal stop control (for this FFmpeg command, press `q`),
then wait for the file to finish before inspecting it.

The enumeration command can exit with an input error after printing the list. Never substitute a
CoreGraphics display ID or copy someone else's index. Re-enumerate after topology changes. `none`
explicitly selects no audio here; other workflows must choose and verify audio themselves. Use the
recorder's supported output options for your intended dimensions/frame rate/color; inspect the
resulting file rather than assuming the source size is the output size. No FFmpeg invocation or
recorder compatibility/physical output was verified by this implementation round.

## Failures and return path

A missing source needs connection/identity checks and a refreshed recorder list. Blank PiP needs
FreeDisplay permission/source checks; blank recorder output needs that recorder's own checks.
Protected video can remain black on a virtual/captured route; no HDCP bypass is supplied, and black
frames alone do not prove DRM. Use a service-supported physical path when required.

FreeDisplay excludes its own app from its display capture to avoid recursion. That does not configure
OBS, other recorders, screenshots or meeting exclusions. Verify each independently. Notification
settings for mirroring/sharing affect other sharing apps globally; do not change them implicitly.

Stop recording/sharing and wait for writes, then move windows back to the physical desktop **before**
closing PiP or removing the virtual source. Remove only your added endpoint in Virtual Displays;
removal destroys this session endpoint, with no saved disconnected definition to recover. Restore
recorded layout/main/mode and any policy you paused. Closing Settings alone is not capture teardown;
quitting FreeDisplay removes its session virtual desktops. A retained OBS scene is reusable only
after rechecking its source, permissions, dimensions and audio on the next session.
