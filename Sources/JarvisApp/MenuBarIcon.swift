import AppKit
import JarvisCore
import SwiftUI

/// The menu-bar icon: plain grey until `Jarvis` exists, then whatever the session's `iconState` says.
struct MenuBarLabel: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        if let jarvis = app.jarvis {
            SessionIcon(session: jarvis.session)
        } else {
            Image(nsImage: MenuBarIcon.image(for: .greyPlain))
        }
    }
}

private struct SessionIcon: View {
    @ObservedObject var session: ListeningSession

    var body: some View {
        Image(nsImage: MenuBarIcon.image(for: session.iconState))
    }
}

/// `waveform.circle.fill`: red while recording, grey with a small dot while paused, plain grey when
/// stopped. Template rendering is off, or the menu bar would draw the red in black and white.
enum MenuBarIcon {
    private static let images: [IconState: NSImage] = [
        .red: make(.systemRed, dot: false, description: "Jarvis is listening"),
        .greyDot: make(.systemGray, dot: true, description: "Jarvis is paused"),
        .greyPlain: make(.systemGray, dot: false, description: "Jarvis is stopped"),
    ]

    static func image(for state: IconState) -> NSImage { images[state]! }

    private static func make(_ color: NSColor, dot: Bool, description: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, color]))
        let symbol = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: description)!
            .withSymbolConfiguration(config)!
        let dotSize: CGFloat = dot ? 6 : 0
        let image = NSImage(size: NSSize(width: symbol.size.width + dotSize, height: symbol.size.height),
                            flipped: false) { bounds in
            symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
            if dot {
                NSColor.labelColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: bounds.maxX - dotSize, y: bounds.maxY - dotSize,
                                            width: dotSize, height: dotSize)).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = description
        return image
    }
}
