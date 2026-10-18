import AVFoundation
import Combine
import CoreAudio
import JarvisCore
import MediaPlayer

/// EXPERIMENTAL (story 27, DEC-33): the AirPods stem squeeze as press-to-talk, opt-in from Settings. While
/// `jarvis.stemTriggerActive`, a silent looping player makes Jarvis the Now Playing app, so the squeeze arrives as
/// a remote command; otherwise nothing plays and Jarvis gives up Now Playing.
///
/// Only `togglePlayPauseCommand` is registered; `play` and `pause` are switched off. Which command the stage
/// AirPods' squeeze sends is unverified on hardware: if it turns out to be `play`/`pause`, register those too.
/// Events that still alias a squeeze while active, because macOS sends them as the same command: the keyboard
/// play/pause key (F8), Control Center and Touch Bar media controls, and, if they arrive as a toggle, taking an
/// AirPod out of the ear, putting it back and a Bluetooth disconnect. Another app that starts playing takes Now
/// Playing and the squeeze with it until the trigger is next activated.
@MainActor
final class StemTrigger {
    private let player: AVAudioPlayer
    private let onPress: () -> Void
    private var target: Any?
    private var subscription: AnyCancellable?

    /// `nil` only if the silent clip cannot be loaded.
    init?(jarvis: Jarvis) {
        guard let player = try? AVAudioPlayer(data: Self.silence) else { return nil }
        self.player = player
        onPress = { [weak jarvis] in jarvis?.stemPressed() }
        player.numberOfLoops = -1
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = false
        commands.pauseCommand.isEnabled = false
        subscription = jarvis.$stemTriggerActive.removeDuplicates().sink { [weak self] in self?.apply($0) }
        // The player stays on the output it started on; when the default output changes (AirPods connect or
        // leave), it is restarted so the silence, and Now Playing, follow. Never removed: `Triggers` keeps this
        // object for the life of the process.
        var output = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &output, .main) { [weak self] _, _ in
            Task { @MainActor in self?.restartIfPlaying() }
        }
    }

    private func apply(_ active: Bool) {
        let commands = MPRemoteCommandCenter.shared()
        let nowPlaying = MPNowPlayingInfoCenter.default()
        if active {
            commands.togglePlayPauseCommand.isEnabled = true
            if target == nil {
                // Playback never actually pauses: every squeeze is a press, and the state stays "playing".
                target = commands.togglePlayPauseCommand.addTarget { [onPress] _ in
                    Task { @MainActor in onPress() }
                    return .success
                }
            }
            player.play()
            nowPlaying.nowPlayingInfo = [MPMediaItemPropertyTitle: "Jarvis"]
            // macOS only routes remote commands to an app that reports its playback state.
            nowPlaying.playbackState = .playing
        } else {
            player.stop()
            if let target { commands.togglePlayPauseCommand.removeTarget(target) }
            target = nil
            commands.togglePlayPauseCommand.isEnabled = false
            nowPlaying.nowPlayingInfo = nil
            nowPlaying.playbackState = .stopped
        }
    }

    private func restartIfPlaying() {
        guard target != nil else { return }
        player.stop()
        player.currentTime = 0
        player.play()
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    /// One second of 8 kHz 16-bit mono silence as a WAV, so no sound file ships.
    private static let silence: Data = {
        let rate: UInt32 = 8_000, bytes: UInt32 = 8_000 * 2
        var wav = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(rate); put(rate * 2); put(UInt16(2)); put(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); put(bytes)
        wav.append(Data(count: Int(bytes)))
        return wav
    }()
}
