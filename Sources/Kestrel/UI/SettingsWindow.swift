import AppKit
import AVFoundation
import SwiftUI

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let view = SettingsView()
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Kestrel Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 460, height: 600))
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct DeviceOption: Identifiable, Hashable {
    let id: String           // uniqueID, or "" for Auto
    let name: String
}

struct SettingsView: View {
    @State private var bitrateMbps: Double = Double(Settings.shared.bitrateMbps)
    @State private var fragmentSeconds: Double = Settings.shared.fragmentSeconds
    @State private var outputPath: String = Settings.shared.outputDirectory.path
    @State private var videoOptions: [DeviceOption] = []
    @State private var audioOptions: [DeviceOption] = []
    @State private var selectedVideoID: String = Settings.shared.preferredVideoDeviceID ?? ""
    @State private var selectedAudioID: String = Settings.shared.preferredAudioDeviceID ?? ""
    @State private var targetFps: Int = Settings.shared.targetFrameRate
    @State private var recordingProfile: Settings.RecordingProfile = Settings.shared.recordingProfile

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Video device")
                        Spacer()
                        Button(action: refreshDevices) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Rescan connected devices")
                    }
                    Picker("", selection: $selectedVideoID) {
                        ForEach(videoOptions) { opt in
                            Text(opt.name).tag(opt.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedVideoID) { _, newValue in
                        Settings.shared.preferredVideoDeviceID = newValue.isEmpty ? nil : newValue
                    }
                    Text("Auto picks the first connected USB / external video device. Plug your capture card in via USB-C, then refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Audio device")
                    Picker("", selection: $selectedAudioID) {
                        ForEach(audioOptions) { opt in
                            Text(opt.name).tag(opt.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedAudioID) { _, newValue in
                        Settings.shared.preferredAudioDeviceID = newValue.isEmpty ? nil : newValue
                    }
                    Text("Capture cards usually expose HDMI audio as a separate USB audio device. Encoded as AAC stereo at 320 kbps into the same MP4.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preview frame rate")
                    Picker("", selection: $targetFps) {
                        Text("24 fps (cinema)").tag(24)
                        Text("30 fps").tag(30)
                        Text("50 fps (PAL)").tag(50)
                        Text("60 fps").tag(60)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .onChange(of: targetFps) { _, newValue in
                        Settings.shared.targetFrameRate = newValue
                    }
                    Text("Pick the highest rate your card actually delivers smoothly. If preview looks like it's dropping frames, drop down a notch (60 → 50 → 30) and Show Preview again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recording profile")
                    Picker("", selection: $recordingProfile) {
                        Text("Match preview").tag(Settings.RecordingProfile.matchPreview)
                        Text("Max resolution (4K30)").tag(Settings.RecordingProfile.maxResolution4K30)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .onChange(of: recordingProfile) { _, newValue in
                        Settings.shared.recordingProfile = newValue
                    }
                    Text("Max resolution swaps the device to its largest NV12 mode at ≤30 fps when you hit Start Recording, and switches back to the smooth preview format when you stop. Useful when your card can do smooth 1440p60 preview but is rate-limited at 4K.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Bitrate")
                        Spacer()
                        Text("\(Int(bitrateMbps)) Mbps")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $bitrateMbps, in: 20...200, step: 5) { _ in
                        Settings.shared.bitrateMbps = Int(bitrateMbps)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Fragment interval")
                        Spacer()
                        Text(String(format: "%.1f s", fragmentSeconds))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $fragmentSeconds, in: 0.5...10.0, step: 0.5) { _ in
                        Settings.shared.fragmentSeconds = fragmentSeconds
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Output folder")
                    HStack {
                        Text(outputPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                    }
                }
            }

            Section {
                HStack {
                    Text("Codec")
                    Spacer()
                    Text("HEVC (hardware)").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Color tagging")
                    Spacer()
                    Text("BT.709").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Container")
                    Spacer()
                    Text("Fragmented MP4").foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { refreshDevices() }
    }

    private func refreshDevices() {
        var video: [DeviceOption] = [DeviceOption(id: "", name: "Auto (first external device)")]
        for device in CaptureCardCapturer.allVideoDevices() {
            video.append(DeviceOption(id: device.uniqueID, name: device.localizedName))
        }
        videoOptions = video

        if !video.contains(where: { $0.id == selectedVideoID }) {
            selectedVideoID = ""
            Settings.shared.preferredVideoDeviceID = nil
        }

        var audio: [DeviceOption] = [
            DeviceOption(id: "", name: "Auto (first external device)"),
            DeviceOption(id: Settings.audioDisabledID, name: "None (no audio)")
        ]
        for device in CaptureCardCapturer.allAudioDevices() {
            audio.append(DeviceOption(id: device.uniqueID, name: device.localizedName))
        }
        audioOptions = audio

        if !audio.contains(where: { $0.id == selectedAudioID }) {
            selectedAudioID = ""
            Settings.shared.preferredAudioDeviceID = nil
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.shared.outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            Settings.shared.outputDirectory = url
            outputPath = url.path
        }
    }
}
