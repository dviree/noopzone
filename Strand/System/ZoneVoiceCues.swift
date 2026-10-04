#if os(iOS)
import Foundation
import AVFoundation
import StrandAnalytics

/// Spoken target-zone cues: "Raise", "In the zone", "Lower", and for intervals "Go", "Rest", "Done".
///
/// Each phrase is rendered ONCE by the system voice (`AVSpeechSynthesizer.write`) into a 16-bit PCM file
/// in Library/Sounds, the folder iOS also searches for notification sounds. The coaching notifications then
/// name that file as their sound, so the voice plays wherever the tone did before: on the Lock Screen, in
/// the background and through headphones, with no audio session or background-audio mode of NOOP's own.
/// Until a phrase's file exists (first launch, or the setting turned off) the notification keeps its tone.
enum ZoneVoiceCues {
    static let enabledKey = "noop.zoneVoice.enabled"

    /// On by default.
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static var allPhrases: [String] {
        [TargetZoneCoach.Feedback.below, .above].map(TargetZoneNotifier.voicePhrase(for:))
            + [TargetZoneCues.IntervalCue.go(round: 1), .rest(round: 1), .done]
                .map(TargetZoneNotifier.intervalVoicePhrase(for:))
    }

    static var soundsDirectory: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    /// The voice file for `phrase` when voice cues are on and the file has been rendered, else nil (the
    /// caller falls back to its tone).
    static func readySoundName(for phrase: String) -> String? {
        guard enabled, let dir = soundsDirectory else { return nil }
        let name = TargetZoneNotifier.voiceFileName(for: phrase)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) ? name : nil
    }

    /// Render every phrase that has no file yet. Cheap once done (a few existence checks); safe to call on
    /// every launch and foreground.
    @MainActor
    static func prepare() {
        guard enabled, let dir = soundsDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for phrase in allPhrases {
            let url = dir.appendingPathComponent(TargetZoneNotifier.voiceFileName(for: phrase))
            guard !FileManager.default.fileExists(atPath: url.path),
                  !renderers.contains(where: { $0.url == url }) else { continue }
            let renderer = Renderer(phrase: phrase, url: url)
            renderers.append(renderer)
            renderer.start { finished in
                Task { @MainActor in renderers.removeAll { $0 === finished } }
            }
        }
    }

    /// Kept alive until each synthesizer has delivered its last buffer.
    @MainActor private static var renderers: [Renderer] = []

    private final class Renderer {
        let phrase: String
        let url: URL
        private let tmp: URL
        private let synthesizer = AVSpeechSynthesizer()
        private var file: AVAudioFile?
        private var failed = false

        init(phrase: String, url: URL) {
            self.phrase = phrase
            self.url = url
            self.tmp = url.deletingPathExtension().appendingPathExtension("tmp.caf")
        }

        func start(done: @escaping (Renderer) -> Void) {
            try? FileManager.default.removeItem(at: tmp)
            let utterance = AVSpeechUtterance(string: phrase)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            synthesizer.write(utterance) { [self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    // The empty buffer marks the end: close the file, then publish it in one move so a
                    // half-written file is never picked up as a notification sound.
                    file = nil
                    if !failed { try? FileManager.default.moveItem(at: tmp, to: url) }
                    try? FileManager.default.removeItem(at: tmp)
                    done(self)
                    return
                }
                do {
                    if file == nil {
                        // Notification sounds must be linear PCM, so store 16-bit integer samples; the
                        // synthesizer hands over float buffers, which AVAudioFile converts on write.
                        let settings: [String: Any] = [
                            AVFormatIDKey: kAudioFormatLinearPCM,
                            AVSampleRateKey: pcm.format.sampleRate,
                            AVNumberOfChannelsKey: pcm.format.channelCount,
                            AVLinearPCMBitDepthKey: 16,
                            AVLinearPCMIsFloatKey: false,
                            AVLinearPCMIsBigEndianKey: false,
                        ]
                        file = try AVAudioFile(forWriting: tmp, settings: settings,
                                               commonFormat: pcm.format.commonFormat,
                                               interleaved: pcm.format.isInterleaved)
                    }
                    try file?.write(from: pcm)
                } catch {
                    failed = true
                }
            }
        }
    }
}
#endif
