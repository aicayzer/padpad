import AppKit
import Foundation
import Testing
@testable import Pad

@MainActor
@Suite struct DiagnosticTests {
    private func fixture() -> (UserDefaults, URL, String) {
        let suite = "pad-diagnostics-tests-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appending(path: suite).appending(path: "report.json")
        return (UserDefaults(suiteName: suite)!, url, suite)
    }

    @Test func optInPersistsAndDisablingDeletesActivityAndCache() async throws {
        let (defaults, cache, suite) = fixture()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cache.deletingLastPathComponent())
        }
        let diagnostics = PadDiagnostics(defaults: defaults, cacheURL: cache)
        #expect(!diagnostics.enabled)
        let source = DiagnosticSource()
        diagnostics.register(source)
        #expect(source.toggles == [false])
        diagnostics.record(.error, scope: UUID(), format: .txt)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        diagnostics.enabled = true
        #expect(PadDiagnostics(defaults: defaults, cacheURL: cache).enabled)
        diagnostics.record(.error, scope: UUID(), format: .txt)
        #expect(FileManager.default.fileExists(atPath: cache.path))
        let restarted = PadDiagnostics(defaults: defaults, cacheURL: cache)
        let resumed = try #require(await restarted.report())
        #expect(String(decoding: resumed, as: UTF8.self).contains("previousIncident"))
        diagnostics.enabled = false
        #expect(source.toggles == [false, true, false])
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        let raw = try #require(await diagnostics.report())
        let report = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect((report["events"] as? [Any])?.isEmpty == true)
        #expect(report["incident"] == nil)
        #expect(report["previousIncident"] == nil)
        #expect(!PadDiagnostics(defaults: defaults, cacheURL: cache).enabled)
    }

    @Test func nativeHistoryIsBoundedAndReportDoesNotAskForWriting() async throws {
        let (defaults, cache, suite) = fixture()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cache.deletingLastPathComponent())
        }
        let diagnostics = PadDiagnostics(defaults: defaults, cacheURL: cache)
        diagnostics.enabled = true
        let source = DiagnosticSource()
        diagnostics.register(source)
        let scope = UUID()
        for _ in 0..<260 { diagnostics.record(.edit, scope: scope, format: .txt) }
        let data = try #require(await diagnostics.report())
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((report["events"] as? [Any])?.count == 200)
        #expect(source.reportRequests == 1)
        #expect(!String(decoding: data, as: UTF8.self).contains(DiagnosticSource.canary))
        #expect(data.count <= PadDiagnostics.maximumBytes)
    }

    @Test func bridgeValidatorDropsWritingAndUnknownMetadataAtEveryLevel() throws {
        var raw = DiagnosticSource.payload()
        raw["presentation"] = ["fontFamily": DiagnosticSource.canary, "fontSize": 15, "fontWeight": 400,
                               "fontStyle": "normal", "caretColor": DiagnosticSource.canary,
                               "viewport": ["width": 700, "height": 400, "text": DiagnosticSource.canary],
                               "caret": ["left": 10, "top": Double.infinity]]
        let report = try #require(PadDiagnosticSanitizer.report(raw))
        let data = try JSONSerialization.data(withJSONObject: report)
        #expect(!String(decoding: data, as: UTF8.self).contains(DiagnosticSource.canary))
        let events = try #require(report["events"] as? [[String: Any]])
        #expect(events.count == 200)
        #expect(events.last?["kind"] as? String == "preservation")
        #expect(events.last?["reason"] as? String == "reopen-mismatch")
        let incident = try #require(report["incident"] as? [String: Any])
        #expect((incident["events"] as? [Any])?.count == 200)
        #expect((incident["tail"] as? [Any])?.count == 40)
        #expect(PadDiagnosticSanitizer.report(["schemaVersion": 2, "enabled": true]) == nil)
    }

    @Test func failedDiagnosticCopyRestoresTheClipboard() async throws {
        let (defaults, cache, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let diagnostics = PadDiagnostics(defaults: defaults, cacheURL: cache)
        diagnostics.enabled = true
        defer { diagnostics.enabled = false }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try PadClipboardContents(text: "Previous", html: "<p>Previous</p>").write(to: board)
        await diagnostics.copyReport(to: board, writer: { _ in false })
        #expect(board.string(forType: .string) == "Previous")
        #expect(board.string(forType: .html) == "<p>Previous</p>")
        #expect(diagnostics.exportError != nil)
    }

    @Test func disabledDiagnosticCopyDoesNotTouchTheClipboardOrAskEditors() async throws {
        let (defaults, cache, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let diagnostics = PadDiagnostics(defaults: defaults, cacheURL: cache)
        let source = DiagnosticSource()
        diagnostics.register(source)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try PadClipboardContents(text: "Previous", html: "<p>Previous</p>").write(to: board)
        let count = board.changeCount
        var writes = 0
        await diagnostics.copyReport(to: board, writer: { _ in writes += 1; return true })
        #expect(writes == 0)
        #expect(source.reportRequests == 0)
        #expect(board.changeCount == count)
        #expect(board.string(forType: .string) == "Previous")
        #expect(board.string(forType: .html) == "<p>Previous</p>")
    }

    @Test func reportTimeoutKeepsNativeIncidentAndIgnoresLateJavaScriptCompletion() async throws {
        let (defaults, cache, suite) = fixture()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cache.deletingLastPathComponent())
        }
        let diagnostics = PadDiagnostics(defaults: defaults, cacheURL: cache)
        diagnostics.enabled = true
        let source = DiagnosticSource()
        var lateCompletion: (@MainActor ([String: Any]?) -> Void)?
        source.collectReport = {
            await PadDiagnosticReportRequest.collect(timeout: .milliseconds(10)) { lateCompletion = $0 }
        }
        diagnostics.register(source)
        diagnostics.record(.error, scope: source.diagnosticScope, format: .md, code: "preservation")
        let data = try #require(await diagnostics.report())
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(report["nativeIncident"] != nil)
        #expect((report["editors"] as? [Any])?.isEmpty == true)
        #expect(source.reportRequests == 1)
        lateCompletion?(DiagnosticSource.payload())
        #expect(!String(decoding: data, as: UTF8.self).contains(DiagnosticSource.canary))
        diagnostics.enabled = false
    }

    @Test func oversizedCacheIsIgnoredBeforeReading() async throws {
        let (defaults, cache, suite) = fixture()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cache.deletingLastPathComponent())
        }
        defaults.set(true, forKey: PadDiagnostics.preferenceKey)
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"schemaVersion\":1}".utf8).write(to: cache)
        let handle = try FileHandle(forWritingTo: cache)
        try handle.truncate(atOffset: UInt64(PadDiagnostics.maximumBytes) * 1024)
        try handle.close()
        let diagnostics = PadDiagnostics(defaults: defaults, cacheURL: cache)
        let data = try #require(await diagnostics.report())
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(report["previousIncident"] == nil)
        diagnostics.enabled = false
    }

    @Test func firstNativeIncidentKeepsItsHistoryAndFortyFollowupEvents() async throws {
        let (defaults, cache, suite) = fixture()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cache.deletingLastPathComponent())
        }
        let diagnostics = PadDiagnostics(defaults: defaults, cacheURL: cache)
        diagnostics.enabled = true
        let scope = UUID()
        for _ in 0..<240 { diagnostics.record(.edit, scope: scope, format: .md) }
        diagnostics.record(.error, scope: scope, format: .md, code: "preservation")
        for _ in 0..<60 { diagnostics.record(.edit, scope: scope, format: .md) }
        diagnostics.record(.error, scope: scope, format: .md, code: "internal")
        let data = try #require(await diagnostics.report())
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let incident = try #require(report["nativeIncident"] as? [String: Any])
        #expect(incident["triggerSequence"] as? Int == 241)
        let events = try #require(incident["events"] as? [[String: Any]])
        #expect(events.count == 200)
        #expect(events.last?["code"] as? String == "preservation")
        let tail = try #require(incident["tail"] as? [[String: Any]])
        #expect(tail.count == 40)
        #expect(tail.last?["sequence"] as? Int == 281)
        diagnostics.enabled = false
    }

    @Test func reportUsesTheBundledEditorVersion() async throws {
        let (defaults, cache, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = try #require(Bundle.main.url(forResource: "editor-version", withExtension: "json", subdirectory: "Editor"))
        let metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let diagnostics = PadDiagnostics(defaults: defaults, cacheURL: cache)
        let data = try #require(await diagnostics.report())
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(report["editorVersion"] as? String == metadata["editorVersion"] as? String)
    }

    @Test(arguments: [false, true]) func cancellationDuringReportLeavesClipboardUntouched(reenable: Bool) async throws {
        let (defaults, cache, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let diagnostics = PadDiagnostics(defaults: defaults, cacheURL: cache)
        diagnostics.enabled = true
        let source = DiagnosticSource()
        source.onReport = {
            diagnostics.enabled = false
            if reenable { diagnostics.enabled = true }
        }
        diagnostics.register(source)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try PadClipboardContents(text: "Previous").write(to: board)
        let count = board.changeCount
        await diagnostics.copyReport(to: board)
        #expect(board.string(forType: .string) == "Previous")
        #expect(board.changeCount == count)
    }

    @Test func lateIncidentCaptureDoesNotAttachToANewerDocumentGeneration() async throws {
        let (defaults, cache, suite) = fixture()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cache.deletingLastPathComponent())
        }
        let diagnostics = PadDiagnostics(defaults: defaults, cacheURL: cache)
        diagnostics.enabled = true
        let source = DiagnosticSource()
        source.onReport = { [weak source] in source?.diagnosticGeneration += 1 }
        diagnostics.register(source)
        diagnostics.captureIncident(from: source)
        for _ in 0..<20 { await Task.yield() }
        #expect(source.reportRequests == 1)
        source.onReport = nil
        let data = try #require(await diagnostics.report())
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(report["engine"] == nil)
    }

    @Test func resetPreferencesDisablesDiagnostics() {
        let (defaults, cache, suite) = fixture()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cache.deletingLastPathComponent())
        }
        let settings = AppSettings(defaults: defaults, diagnosticCacheURL: cache)
        settings.diagnostics.enabled = true
        settings.diagnostics.record(.error, scope: UUID(), format: .txt)
        #expect(FileManager.default.fileExists(atPath: cache.path))
        settings.resetPreferences(from: nil)
        #expect(!settings.diagnostics.enabled)
        #expect(!defaults.bool(forKey: PadDiagnostics.preferenceKey))
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func reportStaysAvailableWhenDocumentSnapshotsFail() async throws {
        let (defaults, cache, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let workspace = PadWorkspace(settings: settings, defaults: defaults, presentsWindows: false,
                                     defaultFolder: cache.deletingLastPathComponent())
        var snapshots = 0
        workspace.quickPad.editorSnapshot = {
            snapshots += 1
            throw PadMarkdownEditorError.composing
        }
        settings.diagnostics.enabled = true
        #expect(await settings.diagnostics.report() != nil)
        #expect(snapshots == 0)
        settings.diagnostics.enabled = false
    }

    @Test func reportTrimsHistoryInsteadOfFailingWhenSeveralWindowsFillIt() async throws {
        let (defaults, cache, suite) = fixture()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cache.deletingLastPathComponent())
        }
        let diagnostics = PadDiagnostics(defaults: defaults, cacheURL: cache)
        diagnostics.enabled = true
        let sources = (0..<4).map { _ in DiagnosticSource() }
        for source in sources { diagnostics.register(source) }
        let data = try #require(await diagnostics.report())
        #expect(data.count <= PadDiagnostics.maximumBytes)
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(report["truncated"] as? Bool == true)
        #expect((report["editors"] as? [Any])?.count == 4)
    }

    @Test func cachedReportIsSanitizedAgainOnRelaunch() async throws {
        let (defaults, cache, suite) = fixture()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cache.deletingLastPathComponent())
        }
        defaults.set(true, forKey: PadDiagnostics.preferenceKey)
        let raw: [String: Any] = ["schemaVersion": 1, "writing": DiagnosticSource.canary,
                                 "engine": ["scope": UUID().uuidString, "report": DiagnosticSource.payload()]]
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: raw).write(to: cache)
        let diagnostics = PadDiagnostics(defaults: defaults, cacheURL: cache)
        let data = try #require(await diagnostics.report())
        #expect(!String(decoding: data, as: UTF8.self).contains(DiagnosticSource.canary))
        #expect(String(decoding: data, as: UTF8.self).contains("reopen-mismatch"))
    }
}

@MainActor
private final class DiagnosticSource: PadDiagnosticSource {
    static let canary = "PRIVATE-WRITING-/private/document.md-DO-NOT-EXPORT"
    let diagnosticScope = UUID()
    var diagnosticGeneration = 0
    var toggles: [Bool] = []
    var reportRequests = 0
    var onReport: (() -> Void)?
    var collectReport: (() async -> [String: Any]?)?
    func setDiagnosticsEnabled(_ enabled: Bool) { toggles.append(enabled) }
    func diagnosticReport() async -> [String: Any]? {
        reportRequests += 1
        onReport?()
        if let collectReport { return await collectReport() }
        return Self.payload()
    }
    static func payload() -> [String: Any] {
        let event: [String: Any] = ["sequence": 1, "elapsedMs": 20, "kind": "preservation", "reason": "reopen-mismatch",
                                    "code": "preservation", "message": canary, "key": canary, "data": canary,
                                    "state": ["ready": true, "revision": 2, "format": "md", "generation": 3,
                                              "composing": true, "pending": true, "documentId": canary, "text": canary]]
        return ["schemaVersion": 1, "enabled": true, "sessionId": UUID().uuidString, "documentId": canary,
                "events": Array(repeating: event, count: 220), "state": event["state"]!,
                "incident": ["triggerSequence": 1, "events": Array(repeating: event, count: 220),
                             "tail": Array(repeating: event, count: 50), "message": canary]]
    }
}
