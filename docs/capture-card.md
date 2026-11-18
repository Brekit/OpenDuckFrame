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
modes), then requests Apple low-latency X2. It is intended for 30 fps games
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
