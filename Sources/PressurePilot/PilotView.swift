import SwiftUI

struct PilotView: View {
    @ObservedObject var pilot: Pilot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Color(nsColor: pilot.level.color)).frame(width: 10, height: 10)
                Text("Speicherdruck: \(pilot.level.label)").font(.headline)
            }
            Text("RAM \(formatBytes(pilot.stats.used)) von \(formatBytes(pilot.stats.total)) · komprimiert \(formatBytes(pilot.stats.compressed)) · Swap \(formatBytes(pilot.stats.swapUsed))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(pilot.apps.prefix(20)) { app in
                        AppRow(
                            app: app,
                            leakRate: pilot.leaks[app.pid],
                            isFrozen: pilot.frozen[app.pid] != nil,
                            rule: Binding(get: { pilot.rule(for: app) }, set: { pilot.setRule($0, for: app) }),
                            toggleFreeze: { pilot.frozen[app.pid] == nil ? pilot.freeze(app) : pilot.thaw(app.pid) },
                            quit: { pilot.quit(app) }
                        )
                    }
                }
            }
            .frame(maxHeight: 380)

            Divider()

            Toggle("Bei Rot entbehrliche Apps automatisch entlasten", isOn: $pilot.autoQuit)
            Toggle("Zuerst einfrieren, erst danach beenden", isOn: $pilot.freezeFirst)
                .disabled(!pilot.autoQuit)
                .help("Eingefrorene Apps behalten Fenster und Daten und wachen beim Wechsel zu ihnen wieder auf.")
            Toggle("Hart beenden, wenn eine App nach 60 s noch läuft", isOn: $pilot.forceQuit)
            Toggle("Beim Login starten", isOn: Binding(
                get: { pilot.loginStatus == .enabled },
                set: { pilot.setLaunchAtLogin($0) }
            ))
            if pilot.loginStatus == .requiresApproval {
                Text("Autostart \(pilot.loginStatus.label)").font(.caption).foregroundStyle(.orange)
            }

            if !pilot.log.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(pilot.log, id: \.self) { Text($0) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                if !pilot.frozen.isEmpty {
                    Button("Alle auftauen (\(pilot.frozen.count))") { pilot.thawAll() }
                }
                Spacer()
                Button("Pressure Pilot beenden") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 420)
    }
}

private struct AppRow: View {
    let app: AppUsage
    let leakRate: UInt64?
    let isFrozen: Bool
    @Binding var rule: AppRule
    let toggleFreeze: () -> Void
    let quit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: app.icon ?? NSImage()).resizable().frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.name).lineLimit(1)
                HStack(spacing: 4) {
                    if isFrozen {
                        Text("eingefroren").foregroundStyle(.cyan)
                    } else if app.isPlayingAudio {
                        Label("spielt Ton, geschont", systemImage: "speaker.wave.2.fill").foregroundStyle(.green)
                    } else {
                        Text(app.isFrontmost ? "im Vordergrund" : "inaktiv seit \(idle)")
                            .foregroundStyle(.secondary)
                    }
                    if let leakRate {
                        Text("· wächst +\(formatBytes(leakRate))/h")
                            .foregroundStyle(.orange)
                            .help("Speicher wächst seit über einer Stunde stetig, vermutlich ein Speicherleck")
                    }
                }
                .font(.caption2)
            }
            Spacer()
            Text(formatBytes(app.footprint)).monospacedDigit()
            Picker("", selection: $rule) {
                ForEach(AppRule.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 115)
            Button(action: toggleFreeze) { Image(systemName: isFrozen ? "sun.max" : "snowflake") }
                .buttonStyle(.borderless)
                .disabled(app.isFrontmost)
                .help(isFrozen ? "\(app.name) auftauen" : "\(app.name) einfrieren")
            Button(action: quit) { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .help("\(app.name) beenden")
        }
    }

    private var idle: String {
        let minutes = Int(Date().timeIntervalSince(app.lastActive) / 60)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h"
    }
}
