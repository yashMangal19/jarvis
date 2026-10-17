import Testing
import JarvisCore

@Suite struct AudioSourceLabelTests {
    // D-7: the source decides the label. The user's own recorder (imported) follows the mic rule.
    @Test(arguments: [
        (AudioSource.mic, SpeakerLabel.me),
        (AudioSource.imported, SpeakerLabel.me),
        (AudioSource.systemAudio, SpeakerLabel.others),
        (AudioSource.roomMic, SpeakerLabel.others),
    ])
    func sourceDecidesTheLabel(source: AudioSource, expected: SpeakerLabel) {
        #expect(source.label == expected)
    }
}
