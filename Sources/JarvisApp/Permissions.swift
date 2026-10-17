import AppKit
import AVFoundation
import JarvisCore

/// The permission requests at launch. The microphone is asked for by the system only the first time; the
/// answer is read back by `Jarvis` (`microphoneAccessOff`), which the menu shows (DEC-31). Screen
/// Recording is explained and asked for once, as `Jarvis` decides (DEC-28); declining it leaves capture
/// on the microphone only, and the menu then offers the Settings page.
enum Permissions {
    @MainActor static func requestAtLaunch(for jarvis: Jarvis) async {
        await AVCaptureDevice.requestAccess(for: .audio)
        guard jarvis.shouldAskForScreenRecording else { return }
        let alert = NSAlert()
        alert.messageText = "Hear the other side of your calls?"
        alert.informativeText = """
            Jarvis needs Screen Recording permission to capture call audio. It records sound only, never \
            your screen. You can decline: Jarvis then listens through the microphone only.
            """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { CGRequestScreenCaptureAccess() }
        jarvis.recordScreenRecordingAsked()
    }
}
