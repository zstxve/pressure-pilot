import SwiftUI

@main
struct PressurePilotApp: App {
    @StateObject private var pilot = Pilot()

    init() {
        if CommandLine.arguments.contains("--dump") {
            ProcessScanner.dump()
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PilotView(pilot: pilot)
        } label: {
            Image(nsImage: statusIcon(for: pilot.level))
        }
        .menuBarExtraStyle(.window)
    }

    private func statusIcon(for level: PressureLevel) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(.init(paletteColors: [level.color]))
        let image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Speicherdruck \(level.label)")!
            .withSymbolConfiguration(config)!
        image.isTemplate = false  // keep the traffic-light color in the menu bar
        return image
    }
}

extension PressureLevel {
    var label: String {
        switch self {
        case .normal: "Normal"
        case .warn: "Erhöht"
        case .critical: "Kritisch"
        }
    }

    var color: NSColor {
        switch self {
        case .normal: .systemGreen
        case .warn: .systemYellow
        case .critical: .systemRed
        }
    }
}
