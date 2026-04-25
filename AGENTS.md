# AGENTS.md

Project context for AI coding agents working on Kestrel.

## What this is

A native macOS menu-bar app that previews and records a USB-C HDMI capture card to fragmented MP4 (HEVC + AAC). No live streaming, no compositing, no cloud. One device, two outputs (preview window + writer), local-only. End user is `apahuja` recording a PS5 via a MACROSILICON MS213x USB-3 capture card.

The app was originally called "Local OBS" and was renamed to "Kestrel" — small, sharp, watches things. Bundle id is `dev.dgr8akki.Kestrel` (matches the GitHub owner `dgr8akki/kestrel`). The active repo lives at `~/personal/kestrel/`; an older `~/personal/local-obs/` directory may still exist on disk for reference but `~/personal/kestrel/` is the source of truth.

## Build / run / test

```bash
./build.sh release        # → ./Kestrel.app
./build.sh release run    # build + launch
```

`build.sh` wraps `swift build -c release` then assembles a real `.app` bundle (required for menu-bar apps and stable TCC identity) and ad-hoc codesigns it. There is **no `xcodebuild`** in this project.

There is no automated test target. To verify changes:

1. `pkill -9 Kestrel; ./Kestrel.app/Contents/MacOS/Kestrel > /tmp/lo.err 2>&1 &`
2. `tail -f /tmp/lo.err | grep "Kestrel:"` to watch capture-pipeline diagnostics.
3. Drive the menu bar via AppleScript when the user can't click it themselves:
   ```bash
   osascript -e 'tell application "System Events" to tell process "Kestrel" to click menu bar item 1 of menu bar 1'
   sleep 1
   osascript -e 'tell application "System Events" to tell process "Kestrel" to click menu item "Show Preview" of menu 1 of menu bar item 1 of menu bar 1'
   ```
4. Probe a recording with `ffprobe`. The full **"Verifying real fps"** recipe lives in `README.md` — use it when verifying frame-rate claims.

## File layout

```
Package.swift              SPM executable target, macOS 14+
Resources/Info.plist       LSUIElement, NSCameraUsageDescription, NSMicrophoneUsageDescription
build.sh                   builds + bundles + ad-hoc signs Kestrel.app
Sources/Kestrel/
  main.swift               NSApplication entry point
  AppDelegate.swift        accessory activation policy, owns MenuBarController
  MenuBar/
    MenuBarController.swift   NSStatusItem + menu, alerts, state display
  Capture/
    CaptureCardCapturer.swift AVCaptureSession wrapping the USB capture device
  Recording/
    RecordingController.swift state machine: idle / previewing / recordingStarting / recording / stopping
    RecordingSession.swift    AVAssetWriter HEVC + movieFragmentInterval (fMP4)
    Settings.swift            UserDefaults keys & defaults
  UI/
    PreviewWindow.swift       NSWindow + AVCaptureVideoPreviewLayer
    SettingsWindow.swift      SwiftUI settings form
```

## Key architectural choices (don't undo without a reason)

- **`@MainActor` on `RecordingController`.** All state transitions and AppKit interactions run on the main actor. Background work (`session.startRunning()`, `await capturer.startSession`) is dispatched via `Task { @MainActor in … }` so continuations land back on main. If you spawn a Task and don't pin it to MainActor, callbacks can silently drop because they run on a queue that the AppKit menu actions never service.
- **Single `AVCaptureSession`, two outputs.** `AVCaptureVideoDataOutput` for the writer and an `AVCaptureVideoPreviewLayer` attached to the same session for the live window. Preview and recording share frames; we never spin up a second session.
- **Preview can switch device formats during a session.** When `recordingProfile == .maxResolution4K30` we keep the smooth preview format (e.g. 1440p60) while idle and call `reconfigureForRecording()` (which does `beginConfiguration` → set `activeFormat` → `commitConfiguration` on the already-locked device) the moment recording starts. On Stop we call `reconfigureForPreview()` to swap back.
- **Audio is gated on availability.** No audio device → writer is created with `includeAudio: false` and the audio sample handler is never wired. Audio frames before the first video frame are dropped so the writer's session start time is video-anchored.
- **Sleep assertion held for the lifetime of an active capture session.** `RecordingController` calls `ProcessInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: …)` after `capturer.startSession` succeeds and `endActivity` in every `stopSession` path (`hidePreview`, `stopRecording` when no preview remains, `handlePreviewClosed`, `stopEverything`, and the start-session error path). Display sleep is **not** blocked — the user can dim/sleep their panel without killing the recording. Verify with `pmset -g assertions | grep -i kestrel`.

## AVFoundation pipeline gotchas (the hard-won ones)

These three together are the difference between 60 fps real throughput and 20 fps. Don't change them without re-running the frame-rate verification recipe:

1. **`videoOutput.videoSettings = nil`.** Setting it to a specific FourCC (even one the device delivers natively, e.g. NV12) makes AVFoundation insert a CPU pixel-format converter and throttles 4K throughput.
2. **Hold `lockForConfiguration` for the lifetime of the capture session**, not just while setting `activeFormat`. Releasing the lock lets the system re-negotiate the device behind your back; on cheap UVC chips that re-negotiation collapses delivery to ~20 fps. We track this in `lockedDevice` and only `unlockForConfiguration` in `stopSession()`.
3. **Set `device.activeFormat` *after* `session.addInput(videoInput)`.** Adding the input first resets the device to a preset-compatible format; setting `activeFormat` afterwards while the device is already in the session implicitly switches the session to input-priority and the device keeps the format we picked.

Reference implementation: OBS's `plugins/mac-avcapture/OBSAVCapture.m` (`configureSession:` and `switchCaptureDevice:withError:`). Cloning OBS to compare is fair game when something behaves weirdly:

```bash
mkdir -p /tmp/obs-ref && cd /tmp/obs-ref && \
  git clone --depth 1 --filter=blob:none --sparse git@github.com:obsproject/obs-studio.git && \
  cd obs-studio && git sparse-checkout set plugins/mac-avcapture
```

## Common tasks

- **Add a setting**: add a key + getter/setter in `Settings.swift`, then a row in `SettingsView` (`Sources/Kestrel/UI/SettingsWindow.swift`). Read it from `RecordingController` or `CaptureCardCapturer` at session start.
- **Change format-selection logic**: edit `bestFormat(for:maxFrameRate:prefersMaxArea:)` in `CaptureCardCapturer.swift`. Always log what you picked via `NSLog("Kestrel: picked format …")` so `/tmp/lo.err` stays useful for the user.
- **Change the writer**: `RecordingSession.swift`. HEVC settings, fragment interval, and color tagging all live there. AAC bitrate is also there.
- **Diagnostic logging**: prefer `NSLog("Kestrel: …")` so it both shows up in Console.app under the Kestrel process *and* in the redirected `/tmp/lo.err` when the app is launched as a foregrounded background process.

## Working-with-this-repo conventions

- **No git commits unless explicitly asked.** This isn't a git repo as of writing; the user runs it locally.
- **No emojis in code, comments, or commits.**
- **Comments only when they explain non-obvious *why*.** No `// Set the format` style narration.
- **Don't add tests speculatively.** There's no test target and the user hasn't asked for one.
- **The user's capture card is a MS213x.** Format-selection heuristics shouldn't hard-code that, but if a format-selection bug only reproduces with NV12 4K modes and gets weird at the upper rate ranges, it's probably this chip's quirk firmware.
- **Recordings live in `~/Movies/Kestrel/`.** Old recordings from before the rename are still in `~/Movies/LocalObs/` and were not migrated. The Movies folder may be outside this agent's read scope; copy via `osascript -e 'tell application "Finder" to duplicate (POSIX file "…" as alias) to (POSIX file "/tmp/" as alias) with replacing'` if you need to `ffprobe` a recording.
