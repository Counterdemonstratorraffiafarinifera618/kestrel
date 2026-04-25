import Foundation

final class Settings {
    static let shared = Settings()

    private enum Keys {
        static let bitrateMbps = "bitrateMbps"
        static let fragmentSeconds = "fragmentSeconds"
        static let outputDirBookmark = "outputDirBookmark"
        static let outputDirPath = "outputDirPath"
        static let preferredVideoDeviceID = "preferredVideoDeviceID"
        static let preferredAudioDeviceID = "preferredAudioDeviceID"
        static let targetFrameRate = "targetFrameRate"
        static let recordingProfile = "recordingProfile"
    }

    /// Capture format used while we're recording. The preview-time format is always
    /// driven by `targetFrameRate` and aims for smoothness; the recording profile
    /// can override that at the moment recording starts (and revert when it stops).
    enum RecordingProfile: String, CaseIterable {
        case matchPreview         // record at the same format as the preview
        case maxResolution4K30    // switch to highest-area NV12 mode capped at 30 fps
    }

    /// Sentinel stored in defaults to mean "explicitly disable audio".
    /// Empty / missing means "auto-pick the first connected external audio device".
    static let audioDisabledID = "__none__"

    private let defaults = UserDefaults.standard

    var bitrateMbps: Int {
        get {
            let v = defaults.integer(forKey: Keys.bitrateMbps)
            return v == 0 ? 60 : v
        }
        set { defaults.set(max(20, min(200, newValue)), forKey: Keys.bitrateMbps) }
    }

    var bitrateBps: Int { bitrateMbps * 1_000_000 }

    var fragmentSeconds: Double {
        get {
            let v = defaults.double(forKey: Keys.fragmentSeconds)
            return v == 0 ? 1.0 : v
        }
        set { defaults.set(max(0.5, min(10.0, newValue)), forKey: Keys.fragmentSeconds) }
    }

    var outputDirectory: URL {
        get {
            if let path = defaults.string(forKey: Keys.outputDirPath) {
                return URL(fileURLWithPath: path)
            }
            let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
            return movies.appendingPathComponent("Kestrel", isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: Keys.outputDirPath) }
    }

    func ensureOutputDirectoryExists() throws {
        let dir = outputDirectory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// `nil` means "auto-pick the first connected external device".
    var preferredVideoDeviceID: String? {
        get { defaults.string(forKey: Keys.preferredVideoDeviceID) }
        set {
            if let id = newValue, !id.isEmpty {
                defaults.set(id, forKey: Keys.preferredVideoDeviceID)
            } else {
                defaults.removeObject(forKey: Keys.preferredVideoDeviceID)
            }
        }
    }

    /// Raw stored value:
    ///   `nil` / empty → auto-pick first external audio device
    ///   `audioDisabledID` → explicitly no audio
    ///   anything else → that device's uniqueID
    var preferredAudioDeviceID: String? {
        get { defaults.string(forKey: Keys.preferredAudioDeviceID) }
        set {
            if let id = newValue, !id.isEmpty {
                defaults.set(id, forKey: Keys.preferredAudioDeviceID)
            } else {
                defaults.removeObject(forKey: Keys.preferredAudioDeviceID)
            }
        }
    }

    var audioDisabled: Bool {
        preferredAudioDeviceID == Self.audioDisabledID
    }

    /// Target capture frame rate. Matches OBS-style "Common FPS" choices.
    /// Defaults to 60; 50 (PAL) matches the reference recording exactly.
    var targetFrameRate: Int {
        get {
            let v = defaults.integer(forKey: Keys.targetFrameRate)
            return v == 0 ? 60 : v
        }
        set { defaults.set(max(24, min(120, newValue)), forKey: Keys.targetFrameRate) }
    }

    /// Default to matchPreview — record at the same format as the preview, so
    /// "Preview FPS" alone controls both. Switch to `.maxResolution4K30` if your
    /// card can do smooth 1440p60 preview but only 4K30 NV12 (e.g. some MS213x
    /// firmware revisions, or a USB-2-only host).
    var recordingProfile: RecordingProfile {
        get {
            if let raw = defaults.string(forKey: Keys.recordingProfile),
               let p = RecordingProfile(rawValue: raw) {
                return p
            }
            return .matchPreview
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.recordingProfile) }
    }

    func nextRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "Kestrel-\(formatter.string(from: Date())).mp4"
        return outputDirectory.appendingPathComponent(name)
    }
}
