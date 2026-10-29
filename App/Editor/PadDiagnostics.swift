import AppKit
import CoreFoundation
import Observation
import OSLog

@MainActor
protocol PadDiagnosticSource: AnyObject {
    var diagnosticScope: UUID { get }
    var diagnosticGeneration: Int { get }
    func setDiagnosticsEnabled(_ enabled: Bool)
    func diagnosticReport() async -> [String: Any]?
}

/// Accepts only metadata described by the diagnostic schema. Never serialize bridge objects directly.
enum PadDiagnosticSanitizer {
    static let codes: Set<String> = ["not-ready", "stale-document", "composition", "operation-pending", "preservation", "invalid-argument", "destroyed", "internal", "clipboard-unavailable", "diagram-unavailable", "image-unavailable", "read-only", "invalid-range", "file-unavailable", "slash-command-failed", "unsupported-format", "unavailable", "invalid-response", "script", "native"]
    static let reasons: Set<String> = ["matching-budget", "source-location", "reopen-mismatch", "parse-refusal", "unexpected"]

    static func code(_ value: String?) -> String { value.flatMap { codes.contains($0) ? $0 : nil } ?? "native" }

    static func report(_ raw: Any) -> [String: Any]? {
        guard let input = raw as? [String: Any], input["schemaVersion"] as? Int == 1,
              let enabled = input["enabled"] as? Bool else { return nil }
        var output: [String: Any] = ["schemaVersion": 1, "enabled": enabled]
        if let id = input["sessionId"] as? String, UUID(uuidString: id) != nil { output["sessionId"] = id }
        output["events"] = events(input["events"], limit: 200)
        if let state = input["state"] as? [String: Any] { output["state"] = metadata(state) }
        if let incident = input["incident"] as? [String: Any] {
            var clean: [String: Any] = ["events": events(incident["events"], limit: 200), "tail": events(incident["tail"], limit: 40)]
            copyNumbers(incident, into: &clean, keys: ["triggerSequence"])
            output["incident"] = clean
        }
        if let presentation = input["presentation"] as? [String: Any] {
            output["presentation"] = presentationMetadata(presentation)
        }
        return output
    }

    private static func events(_ raw: Any?, limit: Int) -> [[String: Any]] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.suffix(limit).map { metadata($0) }
    }

    private static func metadata(_ raw: [String: Any], depth: Int = 0) -> [String: Any] {
        var clean: [String: Any] = [:]
        copyNumbers(raw, into: &clean, keys: ["sequence", "time", "elapsedMs", "timestamp", "revision", "generation", "pending", "selectionFrom", "selectionTo", "count", "durationMs"])
        for key in ["ready", "editable", "composing", "pending", "trusted", "repeat", "defaultPrevented", "cancelable", "isComposing", "changed"] {
            if let value = raw[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { clean[key] = value }
        }
        let choices: [String: Set<String>] = [
            "format": ["md", "rtf", "txt"], "mode": ["formatted", "source"],
            "code": codes, "reason": reasons,
            "kind": ["input", "composition", "focus", "selection", "operation", "preservation", "error", "enabled"],
            "phase": ["before", "after", "start", "end", "in", "out", "begin", "success", "refused"],
            "input": ["text", "composition", "delete", "paste", "drop", "history", "format", "other"],
            "operation": ["snapshot", "edit", "history", "load", "configuration", "output", "selection", "lifecycle", "other"],
            "path": ["unchanged", "local", "regions", "whole"]
        ]
        for (key, values) in choices {
            if let value = raw[key] as? String, values.contains(value) { clean[key] = value }
        }
        if depth == 0, let state = raw["state"] as? [String: Any] { clean["state"] = metadata(state, depth: 1) }
        if let selection = raw["selection"] as? [String: Any] {
            var range: [String: Any] = [:]
            copyNumbers(selection, into: &range, keys: ["from", "to"])
            clean["selection"] = range
        }
        return clean
    }

    private static func presentationMetadata(_ raw: [String: Any]) -> [String: Any] {
        var clean: [String: Any] = [:]
        copyNumbers(raw, into: &clean, keys: ["fontSize", "fontWeight", "headingLevel", "lineHeight", "devicePixelRatio", "scrollTop", "scrollLeft", "scrollWidth", "scrollHeight", "clientWidth", "clientHeight", "width", "height"])
        for key in ["caret", "viewport", "scroll", "font"] {
            if let group = raw[key] as? [String: Any] {
                var values: [String: Any] = [:]
                copyNumbers(group, into: &values, keys: ["x", "y", "top", "left", "right", "bottom", "width", "height", "fontSize", "lineHeight", "size", "scrollTop", "scrollLeft", "scrollWidth", "scrollHeight", "clientWidth", "clientHeight"])
                clean[key] = values
            }
        }
        if let style = raw["fontStyle"] as? String, ["normal", "italic", "oblique", "other"].contains(style) { clean["fontStyle"] = style }
        if let block = raw["block"] as? String, ["paragraph", "heading", "code", "other", "literal"].contains(block) { clean["block"] = block }
        if let marks = raw["marks"] as? [String] {
            clean["marks"] = Array(marks.filter { ["strong", "emphasis", "inlineCode", "strike_through", "link", "highlight", "other"].contains($0) }.prefix(7))
        }
        if let family = raw["fontFamily"] as? String, family.count <= 512 {
            let allowed: Set<String> = ["system-ui", "ui-rounded", "Times New Roman", "Georgia", "-apple-system", "BlinkMacSystemFont", "sans-serif", "serif", "monospace", "ui-monospace", "SFMono-Regular", "SF Pro", "SF Pro Text", "Helvetica Neue", "Helvetica", "Arial", "Menlo", "Monaco", "Courier New"]
            let families = family.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            clean["fontFamily"] = !families.isEmpty && families.count <= 12 && families.allSatisfy(allowed.contains) ? family : "other"
        }
        if let color = raw["caretColor"] as? String, color.count <= 64,
           color.range(of: "^(#[0-9a-fA-F]{3,8}|rgba?\\([0-9., %]+\\)|transparent|auto)$", options: .regularExpression) != nil { clean["caretColor"] = color }
        return clean
    }

    private static func copyNumbers(_ raw: [String: Any], into clean: inout [String: Any], keys: [String]) {
        for key in keys {
            guard let value = raw[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, abs(value.doubleValue) <= 1_000_000_000_000 else { continue }
            clean[key] = value
        }
    }
}

@MainActor
@Observable
final class PadDiagnostics {
    enum Activity: String { case focus, load, snapshot, snapshotSucceeded, save, saveSucceeded, edit, buffer, refusal, error }
    private struct Source { weak var value: (any PadDiagnosticSource)? }
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PadPad", category: "editor")
    static let preferenceKey = "recordDiagnosticActivity"
    static let maximumBytes = 256 * 1024
    private let defaults: UserDefaults
    private let cacheURL: URL
    private var sources: [Source] = []
    private var sessionID = UUID()
    private var sequence = 0
    private var started = ProcessInfo.processInfo.systemUptime
    private var events: [[String: Any]] = []
    private var latestEngine: [String: Any]?
    private var nativeIncident: [String: Any]?
    private var previousReport: [String: Any]?
    private var epoch = 0
    private var incidentRequest = 0
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    private(set) var exportError: String?
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.preferenceKey)
            epoch += 1
            cacheTask?.cancel()
            cacheTask = nil
            events.removeAll()
            latestEngine = nil
            nativeIncident = nil
            previousReport = nil
            sessionID = UUID()
            sequence = 0
            started = ProcessInfo.processInfo.systemUptime
            deleteCache()
            for source in sources { source.value?.setDiagnosticsEnabled(enabled) }
        }
    }

    init(defaults: UserDefaults = .standard, cacheURL: URL? = nil) {
        self.defaults = defaults
        self.cacheURL = cacheURL ?? (defaults === UserDefaults.standard
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "PadPad/diagnostic-report.json")
            : FileManager.default.temporaryDirectory.appending(path: "PadPad-diagnostics-\(UUID().uuidString)/report.json"))
        enabled = defaults.bool(forKey: Self.preferenceKey)
        if enabled, let size = try? self.cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= Self.maximumBytes, let data = try? Data(contentsOf: self.cacheURL), data.count <= Self.maximumBytes,
           let raw = try? JSONSerialization.jsonObject(with: data), let report = Self.sanitizedEnvelope(raw) {
            previousReport = report
        } else if !enabled { try? FileManager.default.removeItem(at: self.cacheURL) }
    }

    func reset() {
        enabled = false
        cacheTask?.cancel()
        cacheTask = nil
        events.removeAll()
        nativeIncident = nil
        latestEngine = nil
        previousReport = nil
        exportError = nil
        deleteCache()
    }

    private func deleteCache() {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        do { try FileManager.default.removeItem(at: cacheURL) }
        catch { exportError = "Couldn’t delete local diagnostic activity. Reset PadPad to try again." }
    }

    func register(_ source: any PadDiagnosticSource) {
        sources.removeAll { $0.value == nil || $0.value === source }
        sources.append(Source(value: source))
        source.setDiagnosticsEnabled(enabled)
    }

    func record(_ activity: Activity, scope: UUID, format: PadFormat, generation: Int? = nil,
                count: Int? = nil, code: String? = nil, reason: String? = nil) {
        guard enabled else { return }
        sequence += 1
        var event: [String: Any] = ["sequence": sequence, "elapsedMs": Int((ProcessInfo.processInfo.systemUptime - started) * 1000), "activity": activity.rawValue,
                                   "scope": scope.uuidString, "format": format.rawValue]
        if let generation { event["generation"] = max(0, generation) }
        if let count { event["count"] = min(1_000_000, max(0, count)) }
        if let code { event["code"] = PadDiagnosticSanitizer.code(code) }
        if let reason, PadDiagnosticSanitizer.reasons.contains(reason) { event["reason"] = reason }
        events.append(event)
        if var incident = nativeIncident, var tail = incident["tail"] as? [[String: Any]], tail.count < 40 {
            tail.append(event)
            incident["tail"] = tail
            nativeIncident = incident
        }
        if events.count > 200 { events.removeFirst(events.count - 200) }
        if activity == .refusal || activity == .error || activity == .save || activity == .saveSucceeded || activity == .snapshot || activity == .snapshotSucceeded {
            Self.logger.info("Editor \(activity.rawValue, privacy: .public) format=\(format.rawValue, privacy: .public) code=\(code.map { PadDiagnosticSanitizer.code($0) } ?? "none", privacy: .public)")
        }
        if activity == .refusal || activity == .error {
            if nativeIncident == nil, !["composition", "not-ready", "stale-document", "operation-pending"].contains(PadDiagnosticSanitizer.code(code)) {
                nativeIncident = ["triggerSequence": sequence, "events": events, "tail": [[String: Any]]()]
            }
            persist(envelope())
        }
        if nativeIncident != nil || latestEngine != nil { scheduleCacheRefresh() }
    }

    private func scheduleCacheRefresh() {
        cacheTask?.cancel()
        let expectedEpoch = epoch
        let source = sources.compactMap(\.value).first { $0.diagnosticScope.uuidString == latestEngine?["scope"] as? String }
        let expectedGeneration = source?.diagnosticGeneration
        cacheTask = Task { [weak self, weak source] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.enabled, self.epoch == expectedEpoch else { return }
            if let source, source.diagnosticGeneration == expectedGeneration,
               let raw = await source.diagnosticReport(), let report = PadDiagnosticSanitizer.report(raw),
               !Task.isCancelled, self.enabled, self.epoch == expectedEpoch,
               source.diagnosticGeneration == expectedGeneration {
                self.latestEngine = ["scope": source.diagnosticScope.uuidString, "report": report]
            }
            guard !Task.isCancelled, self.enabled, self.epoch == expectedEpoch else { return }
            self.persist(self.envelope())
            self.cacheTask = nil
        }
    }

    func captureIncident(from source: any PadDiagnosticSource) {
        guard enabled else { return }
        let expectedEpoch = epoch
        let expectedGeneration = source.diagnosticGeneration
        incidentRequest += 1
        let expectedRequest = incidentRequest
        Task { [weak self, weak source] in
            guard let source, let raw = await source.diagnosticReport(), let report = PadDiagnosticSanitizer.report(raw), let self,
                  self.enabled, self.epoch == expectedEpoch, self.incidentRequest == expectedRequest,
                  source.diagnosticGeneration == expectedGeneration else { return }
            self.latestEngine = ["scope": source.diagnosticScope.uuidString, "report": report]
            self.persist(self.envelope())
            self.scheduleCacheRefresh()
        }
    }

    func report() async -> Data? {
        exportError = nil
        let expectedEpoch = epoch
        if enabled {
            sources.removeAll { $0.value == nil }
            // The incident remains available after its window closes; current editors have separate scopes.
            var current: [[String: Any]] = []
            for source in sources.compactMap(\.value).suffix(4) {
                let expectedGeneration = source.diagnosticGeneration
                let raw = await source.diagnosticReport()
                guard enabled, epoch == expectedEpoch else { return nil }
                if source.diagnosticGeneration == expectedGeneration, let raw, let report = PadDiagnosticSanitizer.report(raw) {
                    current.append(["scope": source.diagnosticScope.uuidString, "report": report])
                    if self.latestEngine?["scope"] as? String == source.diagnosticScope.uuidString {
                        self.latestEngine = ["scope": source.diagnosticScope.uuidString, "report": report]
                    }
                }
            }
            guard enabled, epoch == expectedEpoch else { return nil }
            var result = envelope()
            result["editors"] = current
            guard let data = encoded(result) else { exportError = "Couldn’t create the diagnostic report. Try again."; return nil }
            persist(result)
            return data
        }
        return encoded(envelope())
    }

    func copyReport(to pasteboard: NSPasteboard = .general, writer: (([NSPasteboardWriting]) -> Bool)? = nil) async {
        guard enabled else { return }
        let expectedEpoch = epoch
        guard let data = await report(), enabled, epoch == expectedEpoch,
              let text = String(data: data, encoding: .utf8) else { return }
        do { try PadClipboardContents(text: text).write(to: pasteboard, writer: writer) }
        catch { exportError = "Couldn’t copy the diagnostic report. Try again." }
    }

    private var editorVersion: String {
        guard let url = Bundle.main.url(forResource: "editor-version", withExtension: "json", subdirectory: "Editor"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = raw["editorVersion"] as? String, version.count <= 40,
              version.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil else { return "unknown" }
        return version
    }

    private func envelope() -> [String: Any] {
        var result: [String: Any] = ["schemaVersion": 1, "app": "PadPad", "appVersion": Bundle.main.shortVersion,
                                   "appBuild": Bundle.main.buildNumber, "editorVersion": editorVersion, "enabled": enabled,
                                   "sessionId": sessionID.uuidString, "events": events]
        if enabled {
            if let latestEngine { result["engine"] = latestEngine }
            if let nativeIncident { result["nativeIncident"] = nativeIncident }
            if let previousReport { result["previousIncident"] = previousReport }
        }
        return result
    }

    private func encoded(_ report: [String: Any]) -> Data? {
        var bounded = report
        for _ in 0..<32 {
            guard let data = try? JSONSerialization.data(withJSONObject: bounded, options: [.prettyPrinted, .sortedKeys]) else { return nil }
            if data.count <= Self.maximumBytes { return data }
            bounded["truncated"] = true
            if bounded.removeValue(forKey: "previousIncident") != nil { continue }
            Self.trimHistory(&bounded)
        }
        return nil
    }

    private static func trimHistory(_ report: inout [String: Any]) {
        for key in ["events", "tail"] {
            if let events = report[key] as? [[String: Any]], events.count > 1 {
                report[key] = Array(events.suffix(max(1, events.count / 2)))
            }
        }
        for key in ["incident", "nativeIncident", "engine"] {
            if var incident = report[key] as? [String: Any] {
                trimHistory(&incident)
                report[key] = incident
            }
        }
        if var engine = report["report"] as? [String: Any] {
            trimHistory(&engine)
            report["report"] = engine
        }
        if var editors = report["editors"] as? [[String: Any]] {
            for index in editors.indices { trimHistory(&editors[index]) }
            report["editors"] = editors
        }
    }

    private func persist(_ report: [String: Any]) {
        guard enabled else { return }
        var report = latestEngine == nil && nativeIncident == nil ? previousReport ?? report : report
        report.removeValue(forKey: "previousIncident")
        report.removeValue(forKey: "editors")
        guard let data = encoded(report) else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
        } catch { exportError = "Couldn’t retain the diagnostic report for the next launch." }
    }

    private static func sanitizedEnvelope(_ raw: Any) -> [String: Any]? {
        guard let input = raw as? [String: Any], input["schemaVersion"] as? Int == 1 else { return nil }
        var clean: [String: Any] = ["schemaVersion": 1, "app": "PadPad"]
        for key in ["appVersion", "appBuild", "editorVersion"] {
            if let value = input[key] as? String, value.count <= 40,
               value.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil { clean[key] = value }
        }
        if let session = input["sessionId"] as? String, UUID(uuidString: session) != nil { clean["sessionId"] = session }
        if let incident = input["engine"] as? [String: Any],
           let report = incident["report"].flatMap(PadDiagnosticSanitizer.report),
           let scope = incident["scope"] as? String, UUID(uuidString: scope) != nil {
            clean["engine"] = ["scope": scope, "report": report]
        }
        // Revalidate the on-disk cache too; older or externally altered files cannot introduce prose.
        clean["events"] = nativeEvents(input["events"])
        if let incident = input["nativeIncident"] as? [String: Any] {
            var frozen: [String: Any] = ["events": nativeEvents(incident["events"]), "tail": Array(nativeEvents(incident["tail"]).prefix(40))]
            if let trigger = incident["triggerSequence"] as? Int, (0...1_000_000_000).contains(trigger) { frozen["triggerSequence"] = trigger }
            clean["nativeIncident"] = frozen
        }
        return clean
    }

    private static func nativeEvents(_ raw: Any?) -> [[String: Any]] {
        return (raw as? [[String: Any]] ?? []).suffix(200).compactMap { event -> [String: Any]? in
            guard let rawActivity = event["activity"] as? String, Activity(rawValue: rawActivity) != nil,
                  let scope = event["scope"] as? String, UUID(uuidString: scope) != nil,
                  let format = event["format"] as? String, ["md", "rtf", "txt"].contains(format) else { return nil }
            var result: [String: Any] = ["activity": rawActivity, "scope": scope, "format": format]
            for key in ["sequence", "elapsedMs", "generation", "count"] {
                if let number = event[key] as? Int, (0...1_000_000_000).contains(number) { result[key] = number }
            }
            if let code = event["code"] as? String { result["code"] = PadDiagnosticSanitizer.code(code) }
            if let reason = event["reason"] as? String, PadDiagnosticSanitizer.reasons.contains(reason) { result["reason"] = reason }
            return result
        }
    }
}
