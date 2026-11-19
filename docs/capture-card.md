# Direct console capture (fork)

Open **File → Capture card** (Shift–Command–C), or launch with
`--odf-capture-card`. Select the USB capture device, press **Recommend**, and
start. A separate video window can be placed fullscreen on the selected display.
The feature requires camera permission; optional HDMI audio monitoring requires
microphone permission. It never selects the Mac microphone as a fallback.

## Which numbers mean what?

- **USB link:** the reported negotiated link speed, read without opening the device exclusively. Missing or ambiguous registry data stays unknown.
- **Requested USB mode:** one of the formats and frame durations advertised by
  AVFoundation for this specific device. Mode availability is not proof of stable
  delivery at that rate. Stop/restart applies changes transactionally. The source
  reasserts the hardware format after session configuration, requests matching
  output buffer dimensions, and checks the active hardware dimensions after start
  so macOS does not silently use its default 1080p output for a selected 4K mode.
  Frame duration is configured on both the device and its macOS output connection.
- **Received USB video:** actual CVPixelBuffer dimensions/pixel format and counted
  callback rate. A mismatch is displayed rather than hidden.
- **Input to processing:** frames admitted to the selected processing profile.
- **Sampled picture changes:** a sparse luma-change estimate, not game FPS or an
  HDMI signal detector. It falls on still scenes; noise and HUDs can inflate it.
- **AI processing size:** the runtime inference size, which may be smaller than
  the incoming frame. Generated frames are restored to source dimensions.
- **Presented FPS:** drawable presentation callbacks, not submissions or proof of
  unique content. Output is limited by the display and processing performance.
- **App buffering / P95:** internal playout delay and callback-to-presentation
  latency. These exclude the console, controller and capture card's own delay.

Standard UVC/AVFoundation does not expose the original HDMI timing here. Check
PS5 **Settings → Screen and Video → Video Output Information** for that signal.
Neither the HDMI output nor a 3840×2160 USB frame proves native 4K game rendering:
a console can upscale and a capture card can downscale. The interface explicitly
reports HDMI timing as unknown. It does not read Elgato firmware through private
USB requests or change EDID/firmware.

## Profiles

**30 → 60** is an explicit user-selected content-rate assumption. A timestamp
phase gate samples the received stream at 30 (or 30000/1001 for fractional-rate
modes), then requests X2 from the selected generator. It is intended for 30 fps games
transported in a 60 Hz signal. It is not automatic game-rate detection, and may
sample the wrong cadence if the game changes modes or drops frames. Switch to
**Original** for diagnosis or **60 → 120** for actual 60 fps input. In the latter
profile all USB frames enter X2, so select a 60 Hz capture mode, not 120 Hz.

**Recommend** ranks the actual advertised formats, favoring an uncompressed
60 Hz mode close to the selected display's pixel area. It is a starting point,
not a measured optimum. To test higher source quality, manually select a 4K
mode and compare presented FPS, P95 and the image against the recommendation.
For Elgato 4K X, check the vendor utility's 10 Gbps mode, USB cable and port if
high-bandwidth modes are absent or unstable. Do not confuse USB speed with HDMI
resolution. HDR handling remains that of the card/driver; no HDR reconstruction
or unsupported DLSS features are claimed.

**HDMI audio** uses AVFoundation's preview output and the system output device.
It is optional, without added video-delay compensation, so it can lead generated
video. The source never substitutes a built-in microphone. OBS/Elgato Studio may
need to release the device before starting this app.

## Generator and 4K preset

The capture window exposes Apple low latency, RIFE/ODF-VFI Fast, experimental
RIFE Balanced and HQ, and Apple FRC Normal and Quality. Availability is checked
by the runtime; selecting a model is not proof that it can sustain the target.
Generator choice is saved separately from ordinary workbench profiles.

**4K30 → 60 · RIFE** selects an advertised 3840×2160 uncompressed NV12 mode
near 30 Hz, the explicit 30 fps source assumption and RIFE Fast X2. The button is
disabled when the device does not advertise that mode. Press Start to apply it.
This can avoid transporting redundant 60 Hz frames for a 30 fps game. The PS5
HDMI output may remain 2160p60: HDMI timing and USB delivery remain separate.
The preset does not change the console, EDID, HDR settings or internal rendering.
It is unsuitable for preserving native 60 fps gameplay; use a 60 Hz capture mode
and the corresponding profile for that content.

Capture presentation prepares bounded Metal texture leases ahead of the display
submit deadline and uses the existing bounded-lag display queue. Its output
queue allowance scales with physical RAM (160–256 MiB), reserving one transient
slot; the existing 90 ms interactive time cap remains. Actual model and display
preparation costs still determine buffering. These changes only apply to the
capture-card source. They do not make every model or device real-time capable.

A 4K input and generated buffer do not turn a 2560×1440 monitor into a 4K display.
The final image is fitted to the selected screen. AI-generated pictures are
estimates and can contain artifacts, even when every output frame is presented.

## Pipeline and limits

`AVCaptureVideoDataOutput → retained CVPixelBuffer → SPLiveProcessor → Metal view`

Capture session setup, format changes, callbacks and stop run on one serial
queue. `alwaysDiscardsLateVideoFrames` is enabled. There is no screen capture,
video encoding or network transport. Old-output callbacks are rejected; source
clock discontinuities require restart. Closing either capture window stops the
session. Missing callbacks clear current FPS and display a recovery message.

Only the new capture-card source bypasses the window-specific 80 ms buffering
floor and raw-callback native-FPS shortcut. The existing adaptive model cost,
source lead, bounded queues, generation checks and display timing remain.
This is not zero latency and does not guarantee 4K60 interpolation.

The fork disables upstream Sparkle updates to avoid replacing these changes.

**Copy diagnostics** includes bounded processing and presentation counters with
the visible settings. It does not include captured pictures or audio.

## Recorded local acceptance (2026-11-19)

On an M4 Max with Elgato 4K X negotiated at 10 Gbit/s, a 3840×2160 30 Hz
NV12 capture and RIFE/ODF-VFI Fast X2 completed a 600-second visible run with
HDMI audio monitoring enabled. Excluding the first 10 seconds, measured drawable
callbacks averaged 60.003/s (30.002 synthetic/s); the rolling FPS estimate had
median 59.999 and minimum 59.746. No additional capture, processing or scored
presentation drops were recorded after warmup. Source, inference and presented
buffer dimensions were all 3840×2160. Rolling app-latency P95 ranged from about
62 to 75 ms. The physical display was 2560×1440 at 120 Hz, so this establishes
4K processing, not a physical 4K display test.

In separate short runs at the same capture mode, Apple low latency used
1920×1080 inference and averaged about 59 presented FPS with dips; RIFE Balanced
averaged about 43; HQ and Apple FRC Normal/Quality fell back to approximately
30 source frames/s. These observations are specific to this configuration and
scene. The console game was left running with an idle player; input-driven
combat, camera movement, artifact quality, end-to-end controller latency and
subjective audio synchronization were not acceptance-tested. AI output is not
lossless reconstruction, and these measurements are not a universal FPS guarantee.

The 600-second run used a test-only sampler of the real native pipeline; that
sampler is excluded from the shipped app. In the installed 0.8.0 (55) app, the
saved preset, camera/audio authorization and fullscreen transition were checked.
Fullscreen observations reached 60.0 FPS, including after an interaction-free
pause. Windowed operation and UI transitions also showed dips (about 46–59 FPS);
zero-drop acceptance does not extend to those conditions or competing workloads.
The exact cause of the windowed/benchmark difference remains unconfirmed.
