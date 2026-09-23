import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - Model

/// One subscription rate-limit window ("5h", "7d") as last reported by the agent.
struct DepottUsageWindow: Equatable, Identifiable {
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    var id: String { label }
}

/// App-wide status for one agent family (all Claude panes, or all Codex panes).
struct DepottAgentFamilyStatus: Equatable {
    var running = 0
    var waiting = 0
    var idle = 0
    var windows: [DepottUsageWindow] = []
    /// When the rate-limit numbers were written by the agent.
    var limitsAsOf: Date?

    var liveCount: Int { running + waiting + idle }
}

/// Feeds the Depott bottom status bar.
///
/// - Live counts come from every window's workspaces (agent hook lifecycle).
/// - Claude limits come from `~/.depott/status/claude-latest.json`, which the
///   user's Claude Code statusline command writes on every render.
/// - Codex limits come from the newest `~/.codex/sessions` rollout's last
///   `rate_limits` event.
@MainActor
final class DepottStatusBarModel: ObservableObject {
    static let shared = DepottStatusBarModel()

    @Published private(set) var claude = DepottAgentFamilyStatus()
    @Published private(set) var codex = DepottAgentFamilyStatus()

    private var timer: Timer?
    private var limitsRefreshInFlight = false
    private var tick = 0

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        refreshLiveCounts()
        // Limits change slowly and need file IO: every 5th tick, off-main.
        if tick % 5 == 0 { refreshLimits() }
        tick += 1
    }

    private func refreshLiveCounts() {
        var claudeCounts = (running: 0, waiting: 0, idle: 0)
        var codexCounts = (running: 0, waiting: 0, idle: 0)
        for tabManager in AppDelegate.shared?.depottAllTabManagers() ?? [] {
            for workspace in tabManager.tabs {
                for (_, states) in workspace.agentLifecycleStatesByPanelId {
                    for (key, state) in states {
                        let lowered = key.lowercased()
                        if lowered == "claude_code" || lowered == "claude" {
                            Self.count(state, into: &claudeCounts)
                        } else if lowered.hasPrefix("codex") {
                            Self.count(state, into: &codexCounts)
                        }
                    }
                }
            }
        }
        var nextClaude = claude
        nextClaude.running = claudeCounts.running
        nextClaude.waiting = claudeCounts.waiting
        nextClaude.idle = claudeCounts.idle
        var nextCodex = codex
        nextCodex.running = codexCounts.running
        nextCodex.waiting = codexCounts.waiting
        nextCodex.idle = codexCounts.idle
        if nextClaude != claude { claude = nextClaude }
        if nextCodex != codex { codex = nextCodex }
    }

    private static func count(
        _ state: AgentHibernationLifecycleState,
        into counts: inout (running: Int, waiting: Int, idle: Int)
    ) {
        switch state {
        case .running: counts.running += 1
        case .needsInput: counts.waiting += 1
        case .idle: counts.idle += 1
        case .unknown: break
        }
    }

    private func refreshLimits() {
        guard !limitsRefreshInFlight else { return }
        limitsRefreshInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let claudeLimits = DepottUsageReader.claudeLimits()
            let codexLimits = DepottUsageReader.codexLimits()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.limitsRefreshInFlight = false
                var nextClaude = self.claude
                nextClaude.windows = claudeLimits.windows
                nextClaude.limitsAsOf = claudeLimits.asOf
                var nextCodex = self.codex
                nextCodex.windows = codexLimits.windows
                nextCodex.limitsAsOf = codexLimits.asOf
                if nextClaude != self.claude { self.claude = nextClaude }
                if nextCodex != self.codex { self.codex = nextCodex }
            }
        }
    }
}

// MARK: - Readers

enum DepottUsageReader {
    typealias Limits = (windows: [DepottUsageWindow], asOf: Date?)

    private static var home: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }

    /// Claude Code statusline input: `rate_limits.five_hour` / `seven_day`.
    static func claudeLimits() -> Limits {
        let url = home.appendingPathComponent(".depott/status/claude-latest.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return ([], nil) }
        let asOf = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        var windows: [DepottUsageWindow] = []
        for (key, label) in [("five_hour", "5h"), ("seven_day", "7d")] {
            guard let window = limits[key] as? [String: Any],
                  let used = (window["used_percentage"] as? NSNumber)?.doubleValue else { continue }
            windows.append(DepottUsageWindow(
                label: label,
                usedPercent: used,
                resetsAt: (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            ))
        }
        return (windows, asOf)
    }

    /// Codex rollout JSONL: last `"rate_limits":{primary,secondary}` in the newest session.
    static func codexLimits() -> Limits {
        guard let newest = newestCodexRollout(),
              let tail = readTail(of: newest, maxBytes: 512 * 1024) else { return ([], nil) }
        // Walk lines from the end; the last event that carries rate_limits wins.
        for line in tail.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let limits = findRateLimits(in: object) else { continue }
            var windows: [DepottUsageWindow] = []
            for key in ["primary", "secondary"] {
                guard let window = limits[key] as? [String: Any],
                      let used = (window["used_percent"] as? NSNumber)?.doubleValue else { continue }
                let minutes = (window["window_minutes"] as? NSNumber)?.intValue ?? 0
                windows.append(DepottUsageWindow(
                    label: windowLabel(minutes: minutes),
                    usedPercent: used,
                    resetsAt: (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                ))
            }
            let asOf = (try? newest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (windows.sorted { $0.label.count == $1.label.count ? $0.label < $1.label : $0.label.count < $1.label.count }, asOf)
        }
        return ([], nil)
    }

    private static func windowLabel(minutes: Int) -> String {
        if minutes <= 0 { return "?" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    private static func findRateLimits(in object: Any) -> [String: Any]? {
        if let dict = object as? [String: Any] {
            if let limits = dict["rate_limits"] as? [String: Any] { return limits }
            for value in dict.values {
                if let found = findRateLimits(in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = findRateLimits(in: value) { return found }
            }
        }
        return nil
    }

    /// Newest rollout under `~/.codex/sessions/YYYY/MM/DD`, checking the last few days only.
    private static func newestCodexRollout() -> URL? {
        let fileManager = FileManager.default
        let root = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let calendar = Calendar(identifier: .gregorian)
        var best: (url: URL, date: Date)?
        for dayOffset in 0..<14 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { continue }
            let directory = root
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", dayOfMonth))
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if best == nil || modified > best!.date { best = (file, modified) }
            }
            // Directories are per day; once one has files, older days can't be newer
            // unless an old session was continued, so scan a couple more days then stop.
            if best != nil && dayOffset >= 2 { break }
        }
        return best?.url
    }

    private static func readTail(of url: URL, maxBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - View

/// Depott's app-level bottom bar: one segment for Claude, one for Codex.
struct DepottStatusBar: View {
    @ObservedObject private var model = DepottStatusBarModel.shared

    var body: some View {
        HStack(spacing: 14) {
            DepottAgentFamilySegment(name: "Claude", tint: Color(red: 0.85, green: 0.47, blue: 0.34), status: model.claude)
            Divider().frame(height: 14)
            DepottAgentFamilySegment(name: "Codex", tint: Color(red: 0.30, green: 0.62, blue: 0.95), status: model.codex)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
        .onAppear { model.start() }
    }
}

private struct DepottAgentFamilySegment: View {
    let name: String
    let tint: Color
    let status: DepottAgentFamilyStatus

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            if status.liveCount > 0 {
                HStack(spacing: 6) {
                    if status.running > 0 { countLabel(status.running, "running", .green) }
                    if status.waiting > 0 { countLabel(status.waiting, "waiting", .orange) }
                    if status.idle > 0 { countLabel(status.idle, "idle", .secondary) }
                }
            } else {
                Text("no agents")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(status.windows) { window in
                DepottUsageGauge(window: window)
            }
        }
        .help(tooltip)
    }

    private func countLabel(_ count: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count) \(label)").font(.system(size: 12)).foregroundStyle(.primary)
        }
    }

    private var tooltip: String {
        var lines = ["\(name): \(status.running) running, \(status.waiting) waiting, \(status.idle) idle"]
        for window in status.windows {
            var line = "\(window.label) limit: \(Int(window.usedPercent.rounded()))% used"
            if let resetsAt = window.resetsAt { line += ", resets \(Self.relative(resetsAt))" }
            lines.append(line)
        }
        if let asOf = status.limitsAsOf { lines.append("limits as of \(Self.relative(asOf))") }
        if status.windows.isEmpty { lines.append("no limit data yet") }
        return lines.joined(separator: "\n")
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct DepottUsageGauge: View {
    let window: DepottUsageWindow

    private var fraction: Double { min(max(window.usedPercent / 100, 0), 1) }
    private var color: Color {
        switch window.usedPercent {
        case ..<60: return .green
        case ..<85: return .yellow
        default: return .red
        }
    }

    /// Time left until the window resets: "12m", "3h 2m", "4d 5h".
    private func timeLeft(now: Date) -> String? {
        guard let resetsAt = window.resetsAt else { return nil }
        let seconds = Int(resetsAt.timeIntervalSince(now))
        guard seconds > 0 else { return nil }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color).frame(width: 44 * fraction)
            }
            .frame(width: 44, height: 6)
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(window.usedPercent >= 85 ? Color.red : Color.primary)
            if window.usedPercent >= 85 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let left = timeLeft(now: context.date) {
                    Text(left)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .help("\(window.label) window · time until reset")
    }
}
