import AppKit
import ServiceManagement
import UserNotifications

enum AppRule: String, CaseIterable, Identifiable {
    case protected, normal, expendable
    var id: Self { self }

    var label: String {
        switch self {
        case .protected: "Geschützt"
        case .normal: "Normal"
        case .expendable: "Entbehrlich"
        }
    }
}

/// Escalation: yellow suggests via notification, red freezes expendable apps one by one, then quits them.
@MainActor
final class Pilot: ObservableObject {
    @Published private(set) var level: PressureLevel = .normal
    @Published private(set) var stats = MemoryStats.current()
    @Published private(set) var apps: [AppUsage] = []
    @Published private(set) var log: [String] = []
    @Published private(set) var leaks: [pid_t: UInt64] = [:]  // growth per hour
    @Published private(set) var rules: [String: AppRule]
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var frozen: [pid_t: [pid_t]] = [:]  // app pid -> its stopped processes
    @Published private(set) var summary = StatsSummary()  // last 7 days
    @Published var autoQuit: Bool { didSet { UserDefaults.standard.set(autoQuit, forKey: "autoQuit") } }
    @Published var freezeFirst: Bool { didSet { UserDefaults.standard.set(freezeFirst, forKey: "freezeFirst") } }
    @Published var forceQuit: Bool { didSet { UserDefaults.standard.set(forceQuit, forKey: "forceQuit") } }

    private let simulated: PressureLevel? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--simulate"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "warn": return .warn
        case "critical": return .critical
        default: return nil
        }
    }()
    private var lastActive: [String: Date] = [:]
    private var pending: [pid_t: Date] = [:]  // asked to quit, not exited yet
    private var skipped: Set<pid_t> = []      // user kept them open (e.g. cancelled save dialog), don't ask again
    private var lastSuggestion = Date.distantPast
    private var lastAutoAction = Date.distantPast
    private var autoFrozen: Set<pid_t> = []  // frozen by the pilot itself, thawed again once memory is fine
    private var normalSince: Date?
    private var termSignal: DispatchSourceSignal?
    private var history: [pid_t: [UInt64]] = [:]  // footprint once per minute
    private var reportedLeaks: Set<pid_t> = []
    private var ticks = 0
    private var timer: Timer?
    private lazy var statsLog: StatsLog? = simulated == nil ? StatsLog() : nil  // simulated pressure stays out
    private var levelSeconds: [PressureLevel: Int] = [:]  // since the last sample
    private var episodeStart: Date?  // current stretch of critical pressure
    private var episodeActions = 0

    var statsURL: URL? { statsLog?.url }

    init() {
        let defaults = UserDefaults.standard
        rules = (defaults.dictionary(forKey: "rules") as? [String: String] ?? [:]).compactMapValues(AppRule.init(rawValue:))
        autoQuit = defaults.object(forKey: "autoQuit") as? Bool ?? true
        forceQuit = defaults.bool(forKey: "forceQuit")
        freezeFirst = defaults.object(forKey: "freezeFirst") as? Bool ?? true

        // Never leave apps stopped behind: resume leftovers from a crash, and resume everything on
        // quit, SIGTERM and logout/shutdown (a stopped app would block the logout).
        Pilot.thawPersisted()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            Pilot.thawPersisted()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: nil) { _ in
            Pilot.thawPersisted()
        }
        signal(SIGTERM, SIG_IGN)
        termSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSignal?.setEventHandler {
            Pilot.thawPersisted()
            exit(0)
        }
        termSignal?.resume()

        Notifier.shared.setUp()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            Task { @MainActor in self?.thaw(pid) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            Task { @MainActor in self?.lastActive[id] = Date() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()

        // Autostart is switched on once, on the first launch from an Applications folder; after that the toggle decides.
        if Bundle.main.bundlePath.contains("/Applications/"), !defaults.bool(forKey: "loginItemConfigured") {
            defaults.set(true, forKey: "loginItemConfigured")
            setLaunchAtLogin(true)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            record("Autostart: \(error.localizedDescription)")
        }
        loginStatus = SMAppService.mainApp.status
    }

    /// Apps the pilot may freeze or close, best candidate first (leaking ones count double).
    /// Never protected ones, the frontmost one, or one playing sound: those are in use.
    var candidates: [AppUsage] {
        let now = Date()
        let score = { (app: AppUsage) in app.score(now: now) * (self.leaks[app.pid] == nil ? 1 : 2) }
        return apps
            .filter { rule(for: $0) != .protected && !$0.isFrontmost && !$0.isPlayingAudio }
            .filter { pending[$0.pid] == nil && !skipped.contains($0.pid) }
            .sorted { score($0) > score($1) }
    }

    func rule(for app: AppUsage) -> AppRule {
        rules[app.bundleID] ?? (app.bundleID == "com.apple.finder" ? .protected : .normal)
    }

    func setRule(_ rule: AppRule, for app: AppUsage) {
        rules[app.bundleID] = rule
        UserDefaults.standard.set(rules.mapValues(\.rawValue), forKey: "rules")
    }

    /// Like Cmd+Q: the app can still ask to save.
    func quit(_ app: AppUsage, automatic: Bool = false) {
        thaw(app.pid)  // a stopped app can't handle the quit request
        guard NSRunningApplication(processIdentifier: app.pid)?.terminate() == true else { return }
        record("\(app.name) beendet (\(formatBytes(app.footprint)))" + (automatic ? ", automatisch" : ""))
        logAction(.quit, app, automatic: automatic)
        if automatic {
            pending[app.pid] = Date()
            lastAutoAction = Date()
            Notifier.shared.post(title: "\(app.name) beendet", body: "Speicherdruck kritisch, \(formatBytes(app.footprint)) freigegeben.")
        }
    }

    /// Stops the app with all its helpers (SIGSTOP). A stopped process touches none of its memory, so macOS
    /// can compress or swap it out over time; it keeps its state and resumes as soon as you switch to it.
    func freeze(_ app: AppUsage, automatic: Bool = false) {
        guard frozen[app.pid] == nil, !app.isFrontmost else { return }
        app.pids.forEach { kill($0, SIGSTOP) }
        frozen[app.pid] = app.pids
        saveFrozen()
        record("\(app.name) eingefroren (\(formatBytes(app.footprint)))" + (automatic ? ", automatisch" : ""))
        logAction(.freeze, app, automatic: automatic)
        if automatic {
            autoFrozen.insert(app.pid)
            lastAutoAction = Date()
            Notifier.shared.post(
                title: "\(app.name) eingefroren",
                body: "Speicherdruck kritisch. macOS kann die \(formatBytes(app.footprint)) jetzt auslagern. Ein Klick aufs App-Symbol weckt sie wieder auf."
            )
        }
    }

    func thaw(_ pid: pid_t) {
        guard let pids = frozen.removeValue(forKey: pid) else { return }
        pids.forEach { kill($0, SIGCONT) }
        autoFrozen.remove(pid)
        saveFrozen()
        if let app = apps.first(where: { $0.pid == pid }) { record("\(app.name) aufgetaut") }
    }

    func thawAll() {
        Array(frozen.keys).forEach(thaw)
    }

    /// Resumes every PID recorded as stopped. Safe to call from any thread and during termination.
    nonisolated static func thawPersisted() {
        let defaults = UserDefaults.standard
        for pid in defaults.array(forKey: "frozenPIDs") as? [Int] ?? [] { kill(pid_t(pid), SIGCONT) }
        defaults.removeObject(forKey: "frozenPIDs")
    }

    private func saveFrozen() {
        UserDefaults.standard.set(frozen.values.flatMap { $0 }.map { Int($0) }, forKey: "frozenPIDs")
    }

    private func logStat(_ entry: StatsEntry) {
        guard let statsLog else { return }
        statsLog.append(entry)
        summary.add(entry)
    }

    private func logAction(_ kind: StatsEntry.Kind, _ app: AppUsage, automatic: Bool) {
        if episodeStart != nil { episodeActions += 1 }
        logStat(StatsEntry(kind: kind, app: app.name, footprint: app.footprint, automatic: automatic))
    }

    /// Time per pressure level, and how long each red phase lasted with or without the pilot stepping in.
    private func trackStats() {
        levelSeconds[level, default: 0] += 5
        if level == .critical, episodeStart == nil {
            episodeStart = Date()
            episodeActions = 0
        } else if level != .critical, let start = episodeStart {
            logStat(StatsEntry(kind: .episode, duration: Int(Date().timeIntervalSince(start)), actions: episodeActions))
            episodeStart = nil
        }
        if ticks % 12 == 0 {
            logStat(StatsEntry(
                kind: .sample,
                warnSeconds: levelSeconds[.warn] ?? 0,
                criticalSeconds: levelSeconds[.critical] ?? 0,
                used: stats.used,
                swap: stats.swapUsed
            ))
            levelSeconds = [:]
        }
        if ticks % 720 == 0 {  // hourly, so entries older than 7 days drop out of the summary
            summary = StatsSummary(statsLog?.load(since: Date().addingTimeInterval(-7 * 86400)) ?? [])
        }
    }

    private func tick() {
        let previous = level
        level = simulated ?? .current()
        stats = .current()
        apps = ProcessScanner.scan(lastActive: lastActive)
        let alive = Set(apps.map(\.pid))
        pending = pending.filter { alive.contains($0.key) }
        skipped.formIntersection(alive)
        history = history.filter { alive.contains($0.key) }
        reportedLeaks.formIntersection(alive)
        trackStats()
        if ticks % 12 == 0 { trackLeaks() }
        ticks += 1

        let gone = frozen.keys.filter { !alive.contains($0) }
        if !gone.isEmpty {
            gone.forEach { frozen[$0] = nil }
            saveFrozen()
        }
        autoFrozen.formIntersection(alive)
        // Fallback in case the activation notification was missed.
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier { thaw(front) }
        normalSince = level == .normal ? (normalSince ?? Date()) : nil
        if let since = normalSince, Date().timeIntervalSince(since) > 600 { autoFrozen.forEach(thaw) }

        switch level {
        case .normal: break
        case .warn: if previous == .normal { suggest() }
        case .critical: relieve()
        }
    }

    /// Once a minute: remember each app's footprint and report steady growth once per process.
    private func trackLeaks() {
        for app in apps {
            history[app.pid, default: []].append(app.footprint)
            if history[app.pid]!.count > LeakDetector.maxSamples { history[app.pid]!.removeFirst() }
        }
        leaks = history.compactMapValues(LeakDetector.growthPerHour)
        for (pid, rate) in leaks where !reportedLeaks.contains(pid) {
            guard let app = apps.first(where: { $0.pid == pid }) else { continue }
            reportedLeaks.insert(pid)
            record("\(app.name) wächst stetig (+\(formatBytes(rate))/h)")
            logStat(StatsEntry(kind: .leak, app: app.name, footprint: app.footprint))
            Notifier.shared.post(
                title: "\(app.name) wächst stetig",
                body: "+\(formatBytes(rate)) pro Stunde, jetzt \(formatBytes(app.footprint)). Ein Neustart der App gibt den Speicher frei.",
                quitPID: pid
            )
        }
    }

    private func relieve() {
        for (pid, asked) in pending where Date().timeIntervalSince(asked) > 60 {
            pending[pid] = nil
            if forceQuit, let app = apps.first(where: { $0.pid == pid }) {
                NSRunningApplication(processIdentifier: pid)?.forceTerminate()
                record("\(app.name) hart beendet")
                logAction(.forceQuit, app, automatic: true)
            } else {
                skipped.insert(pid)
            }
        }
        // Give the last action time to take effect before the next one.
        guard pending.isEmpty, Date().timeIntervalSince(lastAutoAction) > 15 else { return }
        let expendable = candidates.filter { rule(for: $0) == .expendable }
        if autoQuit, freezeFirst, let victim = expendable.first(where: { frozen[$0.pid] == nil }) {
            freeze(victim, automatic: true)
        } else if autoQuit, let victim = expendable.first {
            quit(victim, automatic: true)  // everything expendable is frozen and it's still critical
        } else {
            suggest()
        }
    }

    private func suggest() {
        let running = candidates.filter { frozen[$0.pid] == nil }
        guard Date().timeIntervalSince(lastSuggestion) > 600, let top = running.first else { return }
        lastSuggestion = Date()
        let list = running.prefix(3).map { "\($0.name) (\(formatBytes($0.footprint)))" }.joined(separator: ", ")
        Notifier.shared.post(title: "Speicherdruck \(level.label.lowercased()): \(top.name) beenden?", body: "Größte Kandidaten: \(list)", quitPID: top.pid)
    }

    private func record(_ text: String) {
        log.insert("\(Date().formatted(date: .omitted, time: .shortened))  \(text)", at: 0)
        log = Array(log.prefix(5))
    }
}

extension SMAppService.Status {
    var label: String {
        switch self {
        case .enabled: "an"
        case .requiresApproval: "wartet auf Freigabe in Systemeinstellungen › Allgemein › Anmeldeobjekte"
        case .notRegistered: "aus"
        case .notFound: "nicht gefunden"
        @unknown default: "unbekannt"
        }
    }
}

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    // UNUserNotificationCenter crashes outside an app bundle (e.g. plain `swift run`).
    private var center: UNUserNotificationCenter? { Bundle.main.bundleIdentifier == nil ? nil : .current() }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        let quit = UNNotificationAction(identifier: "QUIT", title: "Beenden")
        center.setNotificationCategories([UNNotificationCategory(identifier: "SUGGEST", actions: [quit], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, quitPID: pid_t? = nil) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let quitPID {
            content.categoryIdentifier = "SUGGEST"
            content.userInfo = ["pid": Int(quitPID)]
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "QUIT", let pid = response.notification.request.content.userInfo["pid"] as? Int {
            NSRunningApplication(processIdentifier: pid_t(pid))?.terminate()
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
