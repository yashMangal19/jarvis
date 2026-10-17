import AVFoundation
import MediaPlayer

/// EXPERIMENTAL (story 27): the AirPods stem squeeze as press-to-talk. A silent, looping player makes
/// Jarvis the Now Playing app, so the squeeze arrives as a play/pause remote command. Another app that
/// starts playing takes Now Playing and the squeeze with it, until Jarvis relaunches.
/// Unverified on the stage AirPods; README (T-28) carries the outcome.
@MainActor
final class StemTrigger {
    private let player: AVAudioPlayer

    init?(onPress: @escaping () -> Void) {
        guard let player = try? AVAudioPlayer(data: Self.silence) else { return nil }
        self.player = player
        player.numberOfLoops = -1
        let commands = MPRemoteCommandCenter.shared()
        for command in [commands.togglePlayPauseCommand, commands.playCommand, commands.pauseCommand] {
            command.isEnabled = true
            // Playback never actually pauses: every squeeze is a press, and the state stays "playing".
            command.addTarget { _ in
                Task { @MainActor in onPress() }
                return .success
            }
        }
        player.play()
        let nowPlaying = MPNowPlayingInfoCenter.default()
        nowPlaying.nowPlayingInfo = [MPMediaItemPropertyTitle: "Jarvis"]
        // macOS only routes remote commands to an app that reports its playback state.
        nowPlaying.playbackState = .playing
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
