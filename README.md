# Kestrel

A tiny native macOS menu-bar recorder for **USB-C capture cards**. One job: take the video and audio coming in over a capture card (Elgato, AVerMedia, etc.), preview it live, and record it to a fragmented MP4 — HEVC video, AAC audio, hardware-encoded, high configurable bitrate, fully offline.

## Install

Via Homebrew (easiest):

```bash
brew tap dgr8akki/tap
brew install --cask kestrel
open -a Kestrel
```

The cask is ad-hoc codesigned and the postflight strips the quarantine attribute, so the app opens without a Gatekeeper warning. See `brew info --cask kestrel` for the full caveats.

Or build from source — see [Build](#build) below.

## Requirements

- macOS 14 (Sonoma) or newer
- Apple Silicon (M-series). Tuned for M4.
- Xcode 15+ command-line tools (`xcode-select --install`) — only needed if you're building from source
- A USB / USB-C video capture device that exposes itself as a UVC video device (the vast majority do)

## Build

```bash
./build.sh release        # produces ./Kestrel.app
./build.sh release run    # build and launch
```

The script wraps `swift build`, then assembles a real `.app` bundle (required for menu-bar apps and TCC permissions) and ad-hoc codesigns it. Ad-hoc signing matters: it gives the app a stable identity so macOS can remember the Camera grant across launches.

## First run

1. Plug your capture card into the Mac via USB-C and connect the HDMI source to it.
2. Launch `Kestrel.app`. A `record.circle` icon appears in the menu bar (no Dock icon).
3. Click the icon → **Show Preview**. macOS will prompt for **Camera** permission (capture cards present themselves as cameras under the hood) and, the first time you record, for **Microphone** permission too (HDMI audio shows up as a microphone input).
4. Grant both in **System Settings → Privacy & Security**, then quit and relaunch the app.
5. Click **Show Preview** again. A live window opens showing the capture-card feed. Resize freely or hit the green button (or `Ctrl+⌘+F`) to go full-screen.
6. Click **Start Recording** — the menu bar icon turns into a filled record dot. The preview keeps running while we write to disk.
7. Click **Stop Recording** to finalize the file.

Recordings land in `~/Movies/Kestrel/` as `Kestrel-YYYYMMDD-HHmmss.mp4`. Use **Open Recordings Folder** in the menu to jump there.

You can preview without recording, record without preview, or both at once. The capture session is started on demand and torn down only when neither preview nor recording is active — so the device gets released cleanly. While a capture session is active Kestrel holds a `ProcessInfo.beginActivity` assertion that blocks system idle sleep (display sleep is still allowed), so a long recording won't be interrupted by your Mac falling asleep.

## Settings

Click the menu bar icon → **Settings…**

- **Video device**: dropdown of detected video devices. Default is **Auto (first external device)**, which picks the first USB / external camera that isn't the built-in FaceTime camera. Use the refresh button after plugging in a new device.
- **Audio device**: **Auto** picks the first external audio device (typically the audio side of the same capture card). **None (no audio)** records video only. Or pin a specific device. Encoded as **AAC stereo at 320 kbps / 48 kHz**.
- **Preview frame rate**: 24 / 30 / 50 / 60. Default 60. The format selector picks the largest 16:9 NV12 mode that can hit this rate. On a healthy USB-3 path this gets you native 3840×2160 @ 60.
- **Recording profile**:
  - **Match preview** (default) — record at the same format the preview is using. With Preview FPS = 60 you get 4K60 throughout.
  - **Max resolution (4K30)** — keep the smooth preview format while idle, then swap the device to its largest 16:9 NV12 mode at ≤30 fps the moment you hit Start Recording, and swap back when you Stop. Useful for cards or hosts that can do smooth 1440p60 preview but choke on 4K60.
- **Bitrate**: 20–200 Mbps slider. Default 60 Mbps (matches OBS's typical preset). For native 4K60 HEVC, 60–120 Mbps is a good range; raise it for high-motion content.
- **Fragment interval**: 0.5–10 s. Default 1 s. Smaller fragments mean the file is more recoverable if the app crashes mid-recording, at the cost of slightly larger files.
- **Output folder**: defaults to `~/Movies/Kestrel/`.
- Codec is fixed at HEVC, container at fragmented MP4. Color is tagged BT.709 / BT.709 / BT.709.

Format selection ranks every advertised NV12 format by **(meets target fps, 16:9 over DCI, primary metric, secondary metric)**. The primary metric is the achievable fps for preview and the area for the recording profile (so `3840×2160` is preferred over `4096×2160` even though DCI has slightly more pixels). The full advertised format list and the chosen mode are logged at session start — `tail -f /tmp/lo.err | grep Kestrel:` while the app is running shows it live, and `cat /tmp/lo.err | grep "captured"` shows the actual delivered fps once per second.

## Verifying the output

It is a real fragmented MP4. Confirm with `ffprobe` (`brew install ffmpeg` if you don't have it):

```bash
ffprobe -hide_banner -show_entries format=format_name,bit_rate \
        -show_entries stream=codec_name,width,height,r_frame_rate \
        -v error -of default=noprint_wrappers=0 \
        ~/Movies/Kestrel/Kestrel-*.mp4 | tail -20
```

A non-fragmented MP4 has one `moov` and zero `moof` atoms; fMP4 has one `moov` plus many `moof` boxes:

```bash
mp4dump ~/Movies/Kestrel/Kestrel-*.mp4 | grep -E 'moof|moov'   # via Bento4
```

## Project layout

```
Package.swift              # SPM executable target, macOS 14+
Resources/Info.plist       # LSUIElement, NSCameraUsageDescription, NSMicrophoneUsageDescription
build.sh                   # builds + bundles + ad-hoc signs Kestrel.app
Sources/Kestrel/
  main.swift               # NSApplication entry point
  AppDelegate.swift        # accessory activation policy, owns MenuBarController
  MenuBar/
    MenuBarController.swift   # NSStatusItem + menu, alerts, state display
  Capture/
    CaptureCardCapturer.swift # AVCaptureSession wrapping the USB capture device
  Recording/
    RecordingController.swift # state machine: idle / previewing / recording
    RecordingSession.swift    # AVAssetWriter HEVC + movieFragmentInterval (fMP4)
    Settings.swift            # UserDefaults: device id, bitrate, fragment, output dir
  UI/
    PreviewWindow.swift       # NSWindow + AVCaptureVideoPreviewLayer
    SettingsWindow.swift      # SwiftUI settings form with device picker
```

## Notes and limitations

- Video + audio in one MP4. HEVC video at the bitrate you choose, AAC stereo audio at 320 kbps / 48 kHz. Audio inputs at other rates / channel counts are resampled and downmixed automatically by the writer.
- Audio is dropped until the first video frame arrives, so the timeline is anchored on video PTS. You'll never get audio-leading-video sync drift.
- One capture device at a time. No compositing, no overlays, no webcam PIP.
- HEVC encoding is **8-bit Main profile**. The reference OBS pipeline uses 10-bit Main 10; matching that needs a 10-bit pixel buffer pool through the whole chain and isn't wired up yet.
- Lossless audio (ALAC / FLAC) inside `.mp4` isn't supported by `AVAssetWriter`. 320 kbps AAC is the practical ceiling without changing container.
- Output is `mp4` with HEVC + AAC. Some very old players struggle; modern macOS, Safari, VLC, and ffmpeg all handle it.

## Troubleshooting

- **"No external video device found"**: confirm the capture card is powered, the HDMI source is on, and the device shows up in `system_profiler SPCameraDataType` or in QuickTime Player → File → New Movie Recording → camera dropdown. Hit the refresh button in Settings after plugging in.
- **Preview is black**: the capture card is connected but the HDMI source is off / negotiating. Switch the source on (e.g. wake the console / camera / laptop feeding it) and the preview will fill in.
- **"Camera permission denied"** / **"Microphone permission denied"**: open **System Settings → Privacy & Security → Camera** (or Microphone), toggle Kestrel on. After rebuilding the app you may need to remove and re-add the entry because the binary signature changed. If you want video-only recording, set **Audio device** to **None (no audio)** in Settings to skip the microphone prompt entirely.
- **No sound in the recording**: open Settings, hit refresh on devices, and confirm an audio device is selected (Auto or a specific one). Some capture cards expose audio only when the HDMI source is actually outputting audio — start the source first.
- **0-byte file after stopping**: usually means no frames were delivered before stop (HDMI source asleep). Verify with the preview window first, then start recording.
- **Want lower bitrate / smaller files**: drop the bitrate slider in Settings. 30–50 Mbps is fine for 1080p60; 60–80 Mbps for 4K60 desktop content.
- **Mac falls asleep mid-recording**: shouldn't happen — Kestrel holds an `idleSystemSleepDisabled` activity assertion for the lifetime of any active capture session. Verify with `pmset -g assertions | grep -i kestrel` while previewing or recording. Display sleep is still allowed by design (the panel can dim/sleep without killing the recording).
- **Recorded video runs at much lower fps than expected** (e.g. 4K60 preview/recording reports ~20 fps): two known pitfalls in the AVFoundation pipeline, both fixed in `CaptureCardCapturer.swift` but worth knowing if you change that file:
  1. Leave `videoOutput.videoSettings = nil`. Setting it to a specific FourCC (even one the device claims to deliver natively) makes AVFoundation insert a CPU pixel-format converter and throttles 4K throughput.
  2. Hold `lockForConfiguration` for the lifetime of the capture session, not just while setting `activeFormat`. Releasing the lock lets the system re-negotiate the device behind your back and on cheap UVC chips that re-negotiation collapses delivery to ~20 fps.

  Both behaviours mirror OBS's `mac-avcapture` plugin. To verify the wire rate, watch `/tmp/lo.err` for `captured N video frames in last 1.00s` lines while previewing.

## Verifying real fps (vs nominal / frame-padded)

Container metadata can claim any frame rate it wants. To prove the recording is actually delivering unique frames at the advertised rate:

```bash
F=~/Movies/Kestrel/Kestrel-YYYYMMDD-HHmmss.mp4

# 1. Inter-frame PTS gaps — at true 60 fps every gap should be 0.01667s (1/60).
ffprobe -v error -select_streams v:0 -show_entries frame=pts_time -of csv=p=0 "$F" \
  | awk 'NR>1 {printf "%.5f\n", $1-prev} {prev=$1}' | sort | uniq -c | sort -rn | head

# 2. Decoded-frames-per-second sanity check.
TOTAL=$(ffprobe -v error -select_streams v:0 -count_frames \
                -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$F")
DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$F")
echo "decoded $TOTAL frames in $DUR s → $(echo "scale=2; $TOTAL/$DUR" | bc) fps"

# 3. Pixel-level uniqueness: hash every frame, count distinct hashes.
mkdir -p /tmp/fr && rm -rf /tmp/fr/* && \
  ffmpeg -y -nostats -hide_banner -i "$F" -vf "scale=320:180,format=gray" /tmp/fr/f_%05d.pgm 2>&1 | tail -1
TOTAL=$(/bin/ls /tmp/fr/ | wc -l | tr -d ' ')
UNIQUE=$(find /tmp/fr -name 'f_*.pgm' -print0 | xargs -0 md5sum | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
echo "exact-pixel unique frames: $UNIQUE / $TOTAL"

# 4. mpdecimate (strict) — meaningfully different frames.
ffmpeg -nostats -hide_banner -i "$F" -vf "mpdecimate=hi=64*4:lo=64*1:frac=0.05" -f null - 2>&1 | tail -2
```

A real 4K60 capture has all PTS gaps at 0.01667s, ~60.0 measured fps, and close to 100% pixel-unique frames. Frame-padded sources (e.g. OBS recording a 30 fps source at 50 fps with 5:3 cadence) show the padding as ~60% mpdecimate-unique frames despite a clean 0.02000s PTS gap.

## Releasing (maintainer)

Cutting a new release means: build a versioned `.app`, attach the zip to a GitHub release on this repo, and bump two lines in [`dgr8akki/homebrew-tap`](https://github.com/dgr8akki/homebrew-tap) so `brew upgrade --cask kestrel` picks it up.

### 1. Bump the version

Edit `Resources/Info.plist` and bump `CFBundleShortVersionString` to the new version (e.g. `0.2.0`). Keep `CFBundleVersion` in sync if you bump the major.minor.

### 2. Build the release artefact

```bash
./build.sh release

# Zip with ditto (NOT plain zip — ditto preserves the codesign attributes
# and resource forks; a regular zip will silently break Gatekeeper).
VERSION=0.2.0
ditto -c -k --sequesterRsrc --keepParent Kestrel.app "Kestrel-${VERSION}.zip"

# Confirm the zip is good and grab its sha256 — you'll need it for the cask.
codesign -v Kestrel.app && echo "codesign OK"
shasum -a 256 "Kestrel-${VERSION}.zip"
```

`Kestrel-*.zip` and `.last-sha256` are gitignored, so they stay local.

### 3. Tag and push

```bash
git tag -a v${VERSION} -m "Kestrel v${VERSION}"
git push origin v${VERSION}
```

### 4. Create the GitHub release

Open https://github.com/dgr8akki/kestrel/releases/new

- **Choose a tag**: pick the `v${VERSION}` you just pushed.
- **Release title**: `Kestrel v${VERSION}`.
- **Description**: brief changelog.
- **Assets**: drag `Kestrel-${VERSION}.zip` into the uploader.
- Click **Publish release**.

After publishing, the asset is downloadable at:
`https://github.com/dgr8akki/kestrel/releases/download/v${VERSION}/Kestrel-${VERSION}.zip`

### 5. Update the Homebrew cask

In [`dgr8akki/homebrew-tap`](https://github.com/dgr8akki/homebrew-tap), edit `Casks/kestrel.rb` and change exactly two lines:

```ruby
version "0.2.0"
sha256  "<the sha256 from step 2>"
```

The `url` is interpolated from `version` so it doesn't need touching. Then:

```bash
cd ~/personal/homebrew-tap
brew style ./Casks/kestrel.rb         # must pass cleanly
git add Casks/kestrel.rb
git commit -m "Bump kestrel to v${VERSION}"
git push
```

### 6. Verify end-to-end

```bash
brew update
brew upgrade --cask kestrel           # or `brew install --cask kestrel` for first install
open -a Kestrel
```

Should land in `/Applications/Kestrel.app` with no Gatekeeper warning (the cask's postflight strips quarantine), and the new version should show in the menu-bar app's `About`.

### 7. Smoke test before publishing

If you want to test the cask before pushing the GitHub release (catches typos in the cask file):

```bash
HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask --no-quarantine ./Casks/kestrel.rb
```

This installs from the local file but still pulls the zip from GitHub — so it only works once the release exists.
