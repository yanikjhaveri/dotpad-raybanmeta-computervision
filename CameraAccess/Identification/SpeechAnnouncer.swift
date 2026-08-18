import AVFoundation

/// Speaks text aloud via on-device text-to-speech. No network, no API key.
final class SpeechAnnouncer: NSObject, AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()

  override init() {
    super.init()
    synthesizer.delegate = self
    // `.voicePrompt` is the mode Apple designed for a short spoken cue layered
    // over an existing audio route without forcing a full renegotiation.
    // (`.playAndRecord` + `.defaultToSpeaker` was tried to rule out Bluetooth
    // radio contention as the cause of a stream disconnect, but errored with
    // OSStatus -50 — invalid category/mode/option combination — and turned
    // out to be chasing the wrong problem anyway: the stream was failing
    // before ever reaching a state this code touches. Reverted.)
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(
        .playback,
        mode: .voicePrompt,
        options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
      )
      try session.setActive(true)
      print("🔊 SpeechAnnouncer: audio session configured. Route: \(session.currentRoute.outputs.map { $0.portType.rawValue })")
    } catch {
      print("🔊 SpeechAnnouncer: FAILED to configure audio session: \(error)")
    }
  }

  func speak(_ text: String) {
    print("🔊 SpeechAnnouncer.speak() called with: \"\(text)\"")
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    // Cut off whatever's currently playing (e.g. the "Looking..." cue) so the
    // real description starts immediately rather than queuing behind it.
    synthesizer.stopSpeaking(at: .immediate)
    synthesizer.speak(utterance)
    print("🔊 SpeechAnnouncer: speak() returned, isSpeaking=\(synthesizer.isSpeaking), route: \(AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue })")
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    print("🔊 didStart speaking")
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    print("🔊 didFinish speaking")
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    print("🔊 didCancel — interrupted before finishing")
  }
}
