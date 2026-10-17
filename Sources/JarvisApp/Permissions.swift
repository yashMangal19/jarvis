import AppKit
import AVFoundation
import JarvisCore

/// The permission requests at launch. The microphone is asked for by the system only the first time.
/// Screen Recording is asked for only when it is not granted, after an alert saying what it is for;
/// declining it leaves capture on the microphone only.
enum Permissions {
    @MainActor static func requestAtLaunch() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        guard !SystemAudioSource.isAuthorized else { return }
        let alert = NSAlert()
        alert.messageText = "Hear the other side of your calls?"
        alert.informativeText = """
            Jarvis needs Screen Recording permission to capture call audio. It records sound only, never \
            your screen. You can decline: Jarvis then listens through the microphone only.
            """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        CGRequestScreenCaptureAccess()
    }
}
