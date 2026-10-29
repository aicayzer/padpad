import AppKit
import InkKitRTF
import Testing
@testable import Pad

@MainActor
@Suite struct PadTests {
    private func fixture(
        defaults suppliedDefaults: UserDefaults? = nil,
        format: PadFormat? = .txt,
        noticeDuration: Duration = .seconds(2),
        selectOpenFile: (@MainActor () async -> URL?)? = nil,
        selectSaveFile: (@MainActor (URL, String) async -> URL?)? = nil,
        resolveUnsavedChanges: @escaping @MainActor () -> PadUnsavedChangesDecision = { .cancel },
        alerts: AlertRecorder? = nil
    ) throws -> (PadDocument, URL, UserDefaults, () -> String?) {
        let root = FileManager.default.temporaryDirectory.appending(path: "pad-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "pad-tests-\(UUID().uuidString)"
        let defaults = suppliedDefaults ?? UserDefaults(suiteName: suite)!
        if suppliedDefaults == nil, let format { defaults.set(format.rawValue, forKey: "pad.format") }
        var copiedPath: String?
        let files = PadDocument(defaults: defaults, defaultFolder: root,
                            presentsWindow: false, noticeDuration: noticeDuration, copyPath: { copiedPath = $0 },
                            selectOpenFile: selectOpenFile, selectSaveFile: selectSaveFile,
                            resolveUnsavedChanges: resolveUnsavedChanges, presentAlert: alerts?.present)
        return (files, root, defaults, { copiedPath })
    }

    @Test func cancelingFirstFolderSelectionRetainsDraftAndBlocksReplacement() throws {
        let suite = "pad-folder-cancel-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("txt", forKey: "pad.format")
        var requests = 0
        let document = PadDocument(defaults: defaults, presentsWindow: false, copyPath: { _ in },
                                   selectSaveFolder: { _ in requests += 1; return nil })
        #expect(document.needsFolderSelection)
        document.text = "Keep this draft"
        document.save()
        document.close()
        document.newFile()
        #expect(!document.canTerminate())
        #expect(requests == 4)
        #expect(document.url == nil)
        #expect(document.text == "Keep this draft")
        #expect(document.isDirty)
        #expect(!document.isBusy)
        #expect(document.error == nil)
        #expect(defaults.data(forKey: "pad.folderBookmark") == nil)
    }

    @Test func firstSaveRemembersSelectedFolderAndLaterSavesReuseIt() throws {
        let suite = "pad-folder-save-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set("txt", forKey: "pad.format")
        var requests = 0
        let document = PadDocument(defaults: defaults, presentsWindow: false, copyPath: { _ in },
                                   selectSaveFolder: { _ in requests += 1; return root })
        document.text = "First draft"
        document.save()
        let first = try #require(document.url)
        #expect(first.deletingLastPathComponent() == root)
        #expect(try String(contentsOf: first, encoding: .utf8) == "First draft")
        #expect(defaults.data(forKey: "pad.folderBookmark") != nil)
        #expect(!document.needsFolderSelection)
        document.newFile()
        document.text = "Second draft"
        document.close()
        #expect(requests == 1)
        #expect(!document.isDirty)
        let restored = PadDocument(defaults: defaults, presentsWindow: false, copyPath: { _ in })
        #expect(restored.folder.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path)
        #expect(!restored.needsFolderSelection)
        document.resetQuickPadPreferences()
        #expect(defaults.data(forKey: "pad.folderBookmark") == nil)
        #expect(document.needsFolderSelection)
        #expect(document.text == "Second draft")
        #expect(try String(contentsOf: first, encoding: .utf8) == "First draft")
    }

    @Test func successfulNoticesExpireButErrorsPersist() async throws {
        let (files, root, _, _) = try fixture(noticeDuration: .milliseconds(30))
        defer { try? FileManager.default.removeItem(at: root) }
        files.text = "draft"
        files.save()
        #expect(files.notice == "Saved. Path copied.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(files.notice == nil)
        #expect(!files.rename(to: "../invalid"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(files.error == PadError.invalidName.message())
    }

    @Test func replacingDocumentCancelsPreviousNotice() async throws {
        let (files, root, _, _) = try fixture(noticeDuration: .milliseconds(30))
        defer { try? FileManager.default.removeItem(at: root) }
        files.text = "first"
        files.save()
        files.newFile()
        #expect(files.notice == nil)
        #expect(!files.rename(to: "../invalid"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(files.error == PadError.invalidName.message())
    }

    @Test func commandLineBooleanOverridesDoNotPersistPreferences() throws {
        let suite = "pad-argument-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suite)
        }
        for (argument, expected) in [("NO", false), ("YES", true)] {
            defaults.setVolatileDomain([
                "pad.saveAutomatically": argument,
                "pad.floating": argument,
                "showInDock": argument,
                "menuBarItem": argument
            ], forName: UserDefaults.argumentDomain)
            let document = PadDocument(defaults: defaults, presentsWindow: false)
            let settings = AppSettings(defaults: defaults)
            #expect(document.saveAutomatically == expected)
            #expect(document.floating == expected)
            #expect(settings.showInDock == expected)
            #expect(settings.menuBarItem == expected)
            #expect(defaults.persistentDomain(forName: suite)?.isEmpty != false)
        }
    }

    @Test func defaultsAndPreferencesPersist() throws {
        let (files, root, defaults, _) = try fixture(format: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(files.format == .md)
        #expect(files.saveAutomatically)
        #expect(files.reusePeriod == .fifteenMinutes)
        files.format = .txt
        files.saveAutomatically = false
        files.reusePeriod = .fiveMinutes
        #expect(defaults.string(forKey: "pad.format") == "txt")
        #expect(defaults.bool(forKey: "pad.saveAutomatically") == false)
        #expect(defaults.integer(forKey: "pad.reusePeriod") == 5)
        let (restored, restoredRoot, _, _) = try fixture(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: restoredRoot) }
        #expect(restored.format == .txt)
        #expect(restored.currentFormat == .txt)
    }

    @Test func dateNameAvoidsExistingFileAndCopiesPath() async throws {
        let (files, root, _, copiedPath) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_790_113_017)
        let first = try PadFilename.available(in: root, parts: PadFilename.defaultParts,
                                                 format: .md, now: now, number: 1).url
        try Data("existing".utf8).write(to: first)
        let second = try PadFilename.available(in: root, parts: PadFilename.defaultParts,
                                                  format: .md, now: now, number: 1).url
        #expect(second.lastPathComponent.hasSuffix("-002.md"))
        files.format = .md
        files.newFile()
        files.text = "# Direct file\n"
        files.save()
        let saved = try #require(files.url)
        #expect(saved.pathExtension == "md")
        #expect(try String(contentsOf: saved, encoding: .utf8) == "# Direct file\n")
        #expect(copiedPath() == saved.path)
    }

    @Test func openedTextRoundTripsAndRefusesExternalOverwrite() throws {
        let alerts = AlertRecorder()
        let (files, root, _, _) = try fixture(alerts: alerts)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "opened.txt")
        try Data("first\n".utf8).write(to: url)
        files.open(url)
        #expect(files.text == "first\n")
        files.text = "second\n"
        files.save()
        #expect(try String(contentsOf: url, encoding: .utf8) == "second\n")
        try Data("outside\n".utf8).write(to: url)
        files.text = "my edit\n"
        files.save()
        #expect(alerts.last == PadError.changed.alert())
        #expect(files.error == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "outside\n")
    }

    @Test(arguments: ["new", "quit"], ["cancel", "save", "discard"])
    func unsavedScratchRequiresADecisionBeforeDestructiveTransitions(_ action: String, _ choice: String) throws {
        var prompts = 0
        let (files, root, _, _) = try fixture(resolveUnsavedChanges: {
            prompts += 1
            switch choice {
            case "save": return .save
            case "discard": return .discard
            default: return .cancel
            }
        })
        defer { try? FileManager.default.removeItem(at: root) }
        files.saveAutomatically = false
        files.newFile()
        #expect(files.rename(to: "Retained thought"))
        files.text = "Keep this unsaved scratch text"
        let identity = files.documentID
        if action == "new" {
            files.commandNew()
        } else {
            #expect(files.canTerminate() == (choice != "cancel"))
        }
        #expect(prompts == 1)
        #expect(!files.isBusy)
        if choice == "cancel" {
            #expect(files.documentID == identity)
            #expect(files.url == nil)
            #expect(files.text == "Keep this unsaved scratch text")
            #expect(files.editableName == "Retained thought")
            #expect(files.isDirty)
        } else if action == "new" {
            #expect(files.documentID != identity)
            #expect(files.text.isEmpty)
            #expect(files.url == nil)
        } else if choice == "save" {
            #expect(files.documentID == identity)
            #expect(files.text == "Keep this unsaved scratch text")
            #expect(!files.isDirty)
        } else {
            #expect(files.text.isEmpty)
            #expect(!files.isDirty)
        }
        let saved = root.appending(path: "Retained thought.txt")
        if choice == "save" {
            #expect(try String(contentsOf: saved, encoding: .utf8) == "Keep this unsaved scratch text")
        } else {
            #expect(!FileManager.default.fileExists(atPath: saved.path))
        }
    }

    @Test func hidingAndExpiringTemporaryScratchDoesNotAskForDestructiveConfirmation() throws {
        var prompts = 0
        let (files, root, _, _) = try fixture(resolveUnsavedChanges: {
            prompts += 1
            return .cancel
        })
        defer { try? FileManager.default.removeItem(at: root) }
        files.saveAutomatically = false
        files.reusePeriod = .fiveMinutes
        let now = Date.now
        files.newFile(now: now)
        files.text = "Temporary writing"
        let identity = files.documentID
        files.close(now: now)
        #expect(files.text == "Temporary writing")
        files.showCurrent(now: now.addingTimeInterval(60))
        #expect(files.documentID == identity)
        #expect(files.text == "Temporary writing")
        files.close(now: now.addingTimeInterval(60))
        files.showCurrent(now: now.addingTimeInterval(60 + 301))
        #expect(files.text.isEmpty)
        #expect(files.documentID != identity)
        #expect(prompts == 0)
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test func commandNewAlwaysCreatesFreshDocument() throws {
        let (files, root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_790_113_017)
        files.newFile(now: start)
        files.text = "first"
        files.commandNew(now: start.addingTimeInterval(14 * 60))
        #expect(files.text.isEmpty)
        files.commandNew(now: start.addingTimeInterval(15 * 60))
        #expect(files.text.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count == 1)
    }

    @Test func shortcutKeepsSavedDocumentPastDraftInterval() throws {
        let (files, root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_790_113_017)
        files.newFile(now: start)
        files.text = "hello world"
        files.close(now: start)
        let saved = try #require(files.url)
        files.toggle(now: start.addingTimeInterval(14 * 60))
        #expect(files.text == "hello world")
        #expect(files.url == saved)
        files.close(now: start.addingTimeInterval(14 * 60))
        files.toggle(now: start.addingTimeInterval(29 * 60))
        #expect(files.text == "hello world")
        #expect(files.url == saved)
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count == 1)
    }

    @Test func sharingDirtyTextUsesTemporaryCopyWithoutChangingOriginal() throws {
        let (files, root, _, _) = try fixture()
        let temporary = FileManager.default.temporaryDirectory.appending(path: "pad-share-tests-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: temporary)
        }
        files.text = "scratch"
        let unsaved = try files.shareableURL(in: temporary)
        #expect(files.url == nil)
        #expect(unsaved.pathExtension == "txt")
        #expect(try String(contentsOf: unsaved, encoding: .utf8) == "scratch")

        files.save()
        let original = try #require(files.url)
        #expect(try files.shareableURL(in: temporary) == original)
        files.text = "changed"
        let shared = try files.shareableURL(in: temporary)
        #expect(shared != original)
        #expect(try String(contentsOf: shared, encoding: .utf8) == "changed")
        #expect(try String(contentsOf: original, encoding: .utf8) == "scratch")
    }

    @Test func freshTriggerSavesPreviousFileWhileCloseRetainsUnsavedScratch() throws {
        let (files, root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        files.newFile()
        files.text = "keep"
        files.newFile()
        #expect(files.text.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count == 1)

        files.saveAutomatically = false
        files.text = "scratch"
        files.close()
        #expect(files.text == "scratch")
        #expect(files.url == nil)
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count == 1)
    }

    @Test func reopeningCleanFileReloadsExternalChanges() throws {
        let (files, root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "external.md")
        try Data("original".utf8).write(to: url)
        files.open(url)
        try Data("external edit".utf8).write(to: url)
        files.open(url)
        #expect(files.text == "external edit")
        #expect(!files.isDirty)
        files.text = "my next edit"
        files.save()
        #expect(files.error == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "my next edit")
    }

    @Test func reopeningDirtyFileKeepsLocalTextAndReportsConflict() throws {
        let alerts = AlertRecorder()
        let (files, root, _, _) = try fixture(alerts: alerts)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "external.txt")
        try Data("original".utf8).write(to: url)
        files.open(url)
        files.text = "local edit"
        files.open(url)
        #expect(files.text == "local edit")
        #expect(files.error == nil)
        try Data("external edit".utf8).write(to: url)
        files.open(url)
        #expect(files.text == "local edit")
        #expect(files.savedText == "original")
        #expect(alerts.alerts == [PadError.changed.alert()])
        // Rereading the same conflict on focus does not alert again; an explicit Save does.
        files.open(url)
        #expect(alerts.alerts.count == 1)
        files.save()
        #expect(alerts.alerts.count == 2)
        #expect(!files.isBusy)
        #expect(try String(contentsOf: url, encoding: .utf8) == "external edit")
    }

    @Test func shortcutRefreshesSavedFiles() throws {
        let (files, root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date.now
        files.newFile(now: now)
        files.text = "scratch"
        files.close()
        let saved = try #require(files.url)
        try Data("changed scratch".utf8).write(to: saved)
        files.toggle(now: now.addingTimeInterval(1))
        #expect(files.text == "changed scratch")
        let opened = root.appending(path: "opened.txt")
        try Data("disk file".utf8).write(to: opened)
        files.open(opened)
        files.close()
        try Data("changed disk file".utf8).write(to: opened)
        files.toggle()
        #expect(files.text == "changed disk file")
        #expect(!files.isDirty)
        try FileManager.default.removeItem(at: opened)
        files.toggle()
        #expect(files.text.isEmpty)
        #expect(files.url == nil)
        #expect(files.error == nil)
    }

    @Test func hidingSavedScratchRetainsEditsAndReplacementRequiresConfirmation() throws {
        let decision = PadDiscardDecision()
        let (files, root, _, _) = try fixture(resolveUnsavedChanges: {
            decision.confirmations += 1
            return decision.discard ? .discard : .cancel
        })
        defer { try? FileManager.default.removeItem(at: root) }
        files.saveAutomatically = false
        files.newFile()
        files.text = "saved scratch"
        files.save()
        let saved = try #require(files.url)
        files.text = "unsaved edit"
        files.close()
        #expect(files.text == "unsaved edit")
        #expect(files.isDirty)
        #expect(decision.confirmations == 0)
        files.newFile()
        #expect(decision.confirmations == 1)
        #expect(files.text == "unsaved edit")
        decision.discard = true
        #expect(files.canTerminate())
        #expect(decision.confirmations == 2)
        #expect(files.text == "saved scratch")
        #expect(files.url == saved)
        #expect(!files.isDirty)
    }

    @Test(arguments: [PadFormat.txt, .md], [false, true])
    func hiddenFileEditsSurviveExpiryAndExternalChanges(_ format: PadFormat, _ opened: Bool) throws {
        var prompts = 0
        let alerts = AlertRecorder()
        let (files, root, _, _) = try fixture(format: format, resolveUnsavedChanges: {
            prompts += 1
            return .cancel
        }, alerts: alerts)
        defer { try? FileManager.default.removeItem(at: root) }
        files.saveAutomatically = false
        files.reusePeriod = .alwaysNew
        let start = Date.now
        if opened {
            let source = root.appending(path: "opened.\(format.rawValue)")
            try Data("original".utf8).write(to: source)
            files.open(source)
        } else {
            files.text = "original"
            files.save()
        }
        let saved = try #require(files.url)
        let identity = files.documentID
        files.text = "unsaved edits"
        files.close(now: start)
        files.showCurrent(now: start.addingTimeInterval(86_400))
        #expect(files.url == saved)
        #expect(files.documentID == identity)
        #expect(files.text == "unsaved edits")
        #expect(files.isDirty)
        #expect(prompts == 0)
        #expect(try String(contentsOf: saved, encoding: .utf8) == "original")
        files.close(now: start)
        try Data("external edit".utf8).write(to: saved)
        files.toggle(now: start.addingTimeInterval(86_400))
        #expect(files.text == "unsaved edits")
        #expect(alerts.last == PadError.changed.alert())
        #expect(prompts == 0)
        #expect(try String(contentsOf: saved, encoding: .utf8) == "external edit")
    }

    @Test(arguments: ["new", "open", "quit"], [false, true])
    func saveDecisionProtectsFileOnDestructiveTransitions(_ action: String, _ conflicting: Bool) throws {
        let alerts = AlertRecorder()
        let (files, root, _, _) = try fixture(resolveUnsavedChanges: { .save }, alerts: alerts)
        defer { try? FileManager.default.removeItem(at: root) }
        files.saveAutomatically = false
        files.text = "original"
        files.save()
        let saved = try #require(files.url)
        let other = root.appending(path: "other.txt")
        try Data("other".utf8).write(to: other)
        files.text = "latest edit"
        if conflicting { try Data("external edit".utf8).write(to: saved) }
        switch action {
        case "new": files.newFile()
        case "open": files.open(other)
        default: #expect(files.canTerminate() == !conflicting)
        }
        #expect(try String(contentsOf: saved, encoding: .utf8) == (conflicting ? "external edit" : "latest edit"))
        if conflicting {
            #expect(files.url == saved)
            #expect(files.text == "latest edit")
            #expect(files.isDirty)
            #expect(alerts.last == PadError.changed.alert())
        } else {
            #expect(!files.isDirty)
            #expect(files.error == nil)
        }
    }

    @Test func pendingSaveAsGuardsDocumentAndSavesTheRequestedSnapshot() async throws {
        let selection = PendingPadSelection()
        let (files, root, _, _) = try fixture(selectSaveFile: { _, _ in await selection.select() })
        defer { try? FileManager.default.removeItem(at: root) }
        files.text = "original"
        files.save()
        let original = try #require(files.url)
        let destination = root.appending(path: "save-as.md")
        let other = root.appending(path: "other.txt")
        try Data("other".utf8).write(to: other)
        files.text = "save this"
        let task = Task { await files.saveAs() }
        await selection.waitUntilPresented()
        #expect(files.isBusy)
        files.save()
        files.close()
        files.newFile()
        files.commandNew()
        files.toggle()
        #expect(!files.rename(to: "blocked rename"))
        files.open(other)
        await files.openPicker()
        await files.saveAs()
        #expect(!files.canTerminate())
        #expect(files.url == original)
        #expect(files.text == "save this")
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        // A late programmatic edit must remain dirty after the requested snapshot is saved.
        files.text = "later edit"
        selection.complete(destination)
        await task.value
        #expect(!files.isBusy)
        #expect(files.url == destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "save this")
        #expect(files.text == "later edit")
        #expect(files.isDirty)
    }

    @Test func canceledAndFailedSaveAsPreserveDocument() async throws {
        let selection = PendingPadSelection()
        let alerts = AlertRecorder()
        let (files, root, _, _) = try fixture(selectSaveFile: { _, _ in await selection.select() }, alerts: alerts)
        defer { try? FileManager.default.removeItem(at: root) }
        files.text = "original"
        files.save()
        let original = try #require(files.url)
        files.text = "local edit"
        let canceled = Task { await files.saveAs() }
        await selection.waitUntilPresented()
        selection.complete(nil)
        await canceled.value
        #expect(!files.isBusy)
        #expect(files.url == original)
        #expect(files.text == "local edit")
        let failed = Task { await files.saveAs() }
        await selection.waitUntilPresented()
        selection.complete(root.appending(path: "missing/fail.txt"))
        await failed.value
        #expect(!files.isBusy)
        #expect(files.url == original)
        #expect(files.isDirty)
        #expect(alerts.last?.action == .saveAs)
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
    }

    @Test func openPanelCancellationAndAcceptanceProtectCurrentEdits() async throws {
        let selection = PendingPadSelection()
        let (files, root, _, _) = try fixture(selectOpenFile: { await selection.select() })
        defer { try? FileManager.default.removeItem(at: root) }
        files.text = "original"
        files.save()
        let original = try #require(files.url)
        let other = root.appending(path: "other.txt")
        try Data("other".utf8).write(to: other)
        files.text = "local edit"
        let canceled = Task { await files.openPicker() }
        await selection.waitUntilPresented()
        files.newFile()
        files.open(other)
        files.save()
        files.close()
        #expect(!files.canTerminate())
        #expect(files.text == "local edit")
        selection.complete(nil)
        await canceled.value
        #expect(!files.isBusy)
        #expect(files.url == original)
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        let accepted = Task { await files.openPicker() }
        await selection.waitUntilPresented()
        selection.complete(other)
        await accepted.value
        #expect(!files.isBusy)
        #expect(files.url == other)
        #expect(files.text == "other")
        #expect(try String(contentsOf: original, encoding: .utf8) == "local edit")
    }

    @Test func discardPromptPreventsReentrantTransitions() throws {
        let decision = PadDiscardDecision()
        let (files, root, _, _) = try fixture(resolveUnsavedChanges: {
            decision.confirmations += 1
            decision.current?.newFile()
            decision.current?.close()
            decision.current?.save()
            #expect(decision.current?.canTerminate() == false)
            return .cancel
        })
        decision.current = files
        defer { try? FileManager.default.removeItem(at: root) }
        files.saveAutomatically = false
        files.text = "saved"
        files.save()
        let saved = try #require(files.url)
        files.text = "unsaved"
        files.newFile()
        #expect(decision.confirmations == 1)
        #expect(!files.isBusy)
        #expect(files.url == saved)
        #expect(files.text == "unsaved")
        #expect(try String(contentsOf: saved, encoding: .utf8) == "saved")
    }

    @Test func failedAutosaveBlocksCloseAndDocumentReplacement() throws {
        let alerts = AlertRecorder()
        let (files, root, _, _) = try fixture(alerts: alerts)
        defer { try? FileManager.default.removeItem(at: root) }
        files.text = "saved"
        files.save()
        let saved = try #require(files.url)
        try Data("external".utf8).write(to: saved)
        files.text = "local"
        files.close()
        files.newFile()
        #expect(!files.canTerminate())
        #expect(files.url == saved)
        #expect(files.text == "local")
        #expect(alerts.last == PadError.changed.alert())
        #expect(try String(contentsOf: saved, encoding: .utf8) == "external")
    }

    @Test(.opensWindows) func nonactivatingPanelRoutesCommandNewDirectly() throws {
        let (files, root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        files.reusePeriod = .alwaysNew
        files.newFile()
        files.text = "previous"
        let panel = PadPanel(files: files)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45
        ))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.performKeyEquivalent(with: event))
        #expect(files.text.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count == 1)
        panel.orderOut(nil)
    }

    @Test(.opensWindows) func nonactivatingPanelRoutesOpenAndProtectsPendingSelection() async throws {
        let selection = PendingPadSelection()
        let (files, root, _, _) = try fixture(selectOpenFile: { await selection.select() })
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "opened.txt")
        try Data("opened document".utf8).write(to: url)
        let panel = PadPanel(files: files)
        defer { panel.orderOut(nil) }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: "o", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31
        ))
        #expect(panel.performKeyEquivalent(with: event))
        await selection.waitUntilPresented()
        #expect(files.isBusy)
        files.commandNew()
        selection.complete(url)
        // The picker task resumes on the next main-actor turn.
        while files.isBusy { await Task.yield() }
        #expect(files.url == url)
        #expect(files.text == "opened document")
    }

    @Test(.opensWindows) func panelRoutesSettingsCloseAndQuitToPad() throws {
        let (files, root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var settingsRequests = 0
        var quitRequests = 0
        files.showSettings = { settingsRequests += 1 }
        let panel = PadPanel(files: files, quit: { quitRequests += 1 })
        defer { panel.orderOut(nil) }
        func send(_ character: String) throws -> Bool {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0
            ))
            return panel.performKeyEquivalent(with: event)
        }
        #expect(try send(","))
        #expect(settingsRequests == 1)
        #expect(files.settingsPresented)
        #expect(try send("q"))
        #expect(quitRequests == 1)
        files.text = "save on close"
        #expect(try send("w"))
        let url = try #require(files.url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "save on close")
        files.text = "save on escape"
        panel.cancelOperation(nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "save on escape")
    }

    @Test func generatedNumberAdvancesOnlyForSuccessfulNewFilesAndPersists() throws {
        let (files, root, defaults, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date.now
        files.newFile(now: now)
        #expect(files.namePreview.hasSuffix("-001.txt"))
        #expect(files.namePreview.hasSuffix("-001.txt"))
        files.text = "first"
        files.save()
        #expect(files.displayName.hasSuffix("-001.txt"))
        #expect(defaults.integer(forKey: "pad.nextNumber") == 2)
        files.text = "first edited"
        files.save()
        files.commandNew(now: now.addingTimeInterval(1))
        #expect(defaults.integer(forKey: "pad.nextNumber") == 2)
        files.newFile()
        files.text = "second"
        files.save()
        #expect(files.displayName.hasSuffix("-002.txt"))
        #expect(defaults.integer(forKey: "pad.nextNumber") == 3)
        files.nameParts = [.literal("Note "), .token(.number)]
        let (reopened, otherRoot, _, _) = try fixture(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        #expect(reopened.nameParts == files.nameParts)
        #expect(reopened.namePreview == "Note 003.txt")
    }

    @Test func generatedNamesSkipCollisionsWithoutReplacingFiles() throws {
        let (files, root, defaults, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        files.nameParts = [.literal("Note-"), .token(.number)]
        let first = root.appending(path: "Note-001.txt")
        try Data("keep".utf8).write(to: first)
        files.text = "new"
        files.save()
        #expect(files.displayName == "Note-002.txt")
        #expect(defaults.integer(forKey: "pad.nextNumber") == 3)
        #expect(try String(contentsOf: first, encoding: .utf8) == "keep")
        files.nameParts = [.literal("Plain")]
        files.newFile()
        files.text = "third"
        files.save()
        files.newFile()
        files.text = "fourth"
        files.save()
        #expect(files.displayName == "Plain-2.txt")
        #expect(try String(contentsOf: root.appending(path: "Plain.txt"), encoding: .utf8) == "third")
        #expect(defaults.integer(forKey: "pad.nextNumber") == 5)
    }

    @Test func saveAsConsumesNumberOnlyForSuccessfulUnchangedGeneratedSuggestion() async throws {
        let (files, root, defaults, _) = try fixture(selectSaveFile: { directory, name in
            directory.appending(path: name)
        })
        defer { try? FileManager.default.removeItem(at: root) }
        files.nameParts = [.literal("Note-"), .token(.number)]
        let existing = root.appending(path: "Note-001.txt")
        try Data("keep existing".utf8).write(to: existing)
        files.text = "new"
        await files.saveAs()
        #expect(files.displayName == "Note-002.txt")
        #expect(defaults.integer(forKey: "pad.nextNumber") == 3)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep existing")
        files.text = "edited"
        await files.saveAs()
        #expect(defaults.integer(forKey: "pad.nextNumber") == 3)
        #expect(!files.isDirty)
        files.newFile()
        files.text = "next"
        await files.saveAs()
        #expect(files.displayName == "Note-003.txt")
        #expect(defaults.integer(forKey: "pad.nextNumber") == 4)
    }

    @Test func canceledGeneratedSaveAsDoesNotConsumeNumber() async throws {
        let (files, root, defaults, _) = try fixture(selectSaveFile: { _, _ in nil })
        defer { try? FileManager.default.removeItem(at: root) }
        files.text = "unsaved"
        await files.saveAs()
        #expect(defaults.integer(forKey: "pad.nextNumber") == 0)
        #expect(files.url == nil)
        #expect(files.isDirty)
        #expect(!files.isBusy)
    }

    @Test func failedGeneratedSaveAsDoesNotConsumeNumber() async throws {
        let alerts = AlertRecorder()
        let (files, root, defaults, _) = try fixture(selectSaveFile: { directory, name in
            directory.appending(path: "missing").appending(path: name)
        }, alerts: alerts)
        defer { try? FileManager.default.removeItem(at: root) }
        files.text = "unsaved"
        await files.saveAs()
        #expect(defaults.integer(forKey: "pad.nextNumber") == 0)
        #expect(files.url == nil)
        #expect(files.isDirty)
        #expect(alerts.last?.action == .saveAs)
        #expect(!files.isBusy)
    }

    @Test func customSaveAsNameDoesNotConsumeNumber() async throws {
        let (files, root, defaults, _) = try fixture(selectSaveFile: { directory, _ in
            directory.appending(path: "Custom.txt")
        })
        defer { try? FileManager.default.removeItem(at: root) }
        files.text = "custom"
        await files.saveAs()
        #expect(files.displayName == "Custom.txt")
        #expect(defaults.integer(forKey: "pad.nextNumber") == 0)
        #expect(!files.isDirty)
        #expect(try String(contentsOf: root.appending(path: "Custom.txt"), encoding: .utf8) == "custom")
    }

    @Test func invalidGeneratedSaveAsPatternDoesNotPresentPicker() async throws {
        let (files, root, defaults, _) = try fixture(selectSaveFile: { _, _ in
            Issue.record("An invalid generated name must be rejected before presenting Save As")
            return nil
        })
        defer { try? FileManager.default.removeItem(at: root) }
        files.nameParts = [.literal("../invalid")]
        files.text = "keep this"
        await files.saveAs()
        #expect(files.error == PadError.invalidName.message(during: .nameFormat))
        #expect(files.url == nil)
        #expect(files.isDirty)
        #expect(!files.isBusy)
        #expect(defaults.integer(forKey: "pad.nextNumber") == 0)
    }

    @Test func failedSaveAndInvalidPatternDoNotConsumeNumbers() throws {
        let (files, root, defaults, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        files.text = "keep this"
        files.nameParts = [.literal("../unsafe")]
        #expect(files.namePreview == "Invalid filename")
        files.save()
        #expect(files.url == nil)
        #expect(files.error == PadError.invalidName.message(during: .nameFormat))
        #expect(defaults.integer(forKey: "pad.nextNumber") == 0)
        files.nameParts = PadFilename.defaultParts
        try FileManager.default.removeItem(at: root)
        files.save()
        #expect(files.url == nil)
        #expect(defaults.integer(forKey: "pad.nextNumber") == 0)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        files.save()
        #expect(files.displayName.hasSuffix("-001.txt"))
        #expect(defaults.integer(forKey: "pad.nextNumber") == 2)
    }

    @Test func scratchRenameKeepsExtensionAndDoesNotConsumeGeneratedNumber() throws {
        let (files, root, defaults, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        files.format = .md
        files.newFile()
        #expect(files.displayName == "Untitled")
        #expect(files.editableName == "Untitled")
        #expect(files.rename(to: "Trip notes"))
        #expect(files.displayName == "Trip notes.md")
        #expect(files.editableName == "Trip notes")
        #expect(files.url == nil)
        files.text = "draft"
        files.save()
        #expect(files.url?.lastPathComponent == "Trip notes.md")
        #expect(defaults.integer(forKey: "pad.nextNumber") == 0)
        #expect(files.rename(to: "Travel"))
        #expect(files.displayName == "Travel.md")
        #expect(defaults.integer(forKey: "pad.nextNumber") == 0)
        files.newFile()
        #expect(files.displayName == "Untitled")
    }

    @Test func renamingDirtyFileMovesSavedBytesAndPreservesEdits() throws {
        let (files, root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "Original.txt")
        let renamed = root.appending(path: "Renamed.txt")
        try Data("saved version".utf8).write(to: original)
        files.open(original)
        files.text = "unsaved edits"
        #expect(files.rename(to: "Renamed"))
        #expect(files.url == renamed)
        #expect(files.editableName == "Renamed")
        #expect(files.text == "unsaved edits")
        #expect(files.savedText == "saved version")
        #expect(files.isDirty)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try String(contentsOf: renamed, encoding: .utf8) == "saved version")
        files.save()
        #expect(files.error == nil)
        #expect(try String(contentsOf: renamed, encoding: .utf8) == "unsaved edits")
    }

    @Test func unchangedRenamePreservesAStemThatContainsTheExtension() throws {
        let (files, root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "notes.txt.txt")
        try Data("keep".utf8).write(to: original)
        files.open(original)
        #expect(files.editableName == "notes.txt")
        #expect(files.rename(to: files.editableName))
        #expect(files.url == original)
        #expect(files.displayName == "notes.txt.txt")
        #expect(try String(contentsOf: original, encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "notes.txt").path))
    }

    @Test func documentIdentityChangesOnlyWhenDocumentIsReplaced() throws {
        let (files, root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = files.documentID
        files.newFile()
        let scratch = files.documentID
        #expect(scratch != initial)
        #expect(files.rename(to: "Scratch"))
        #expect(files.documentID == scratch)
        files.text = "saved"
        files.save()
        #expect(files.documentID == scratch)
        let saved = try #require(files.url)
        files.open(saved)
        #expect(files.documentID == scratch)
        let other = root.appending(path: "other.txt")
        try Data("other".utf8).write(to: other)
        files.open(other)
        let opened = files.documentID
        #expect(opened != scratch)
        #expect(files.rename(to: "Renamed"))
        #expect(files.documentID == opened)
        files.open(root.appending(path: "missing.txt"))
        #expect(files.documentID == opened)
    }

    @Test func renameRefusesCollisionsInvalidNamesAndExternalChanges() throws {
        let alerts = AlertRecorder()
        let (files, root, _, _) = try fixture(alerts: alerts)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "original.txt")
        let existing = root.appending(path: "existing.txt")
        try Data("original".utf8).write(to: original)
        try Data("keep".utf8).write(to: existing)
        files.open(original)
        files.text = "local edit"
        #expect(!files.rename(to: "existing"))
        #expect(files.error == PadError.nameExists.message())
        #expect(files.url == original)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
        for invalid in ["", "   ", ".", "..", "../escape", "a/b", "a\\b", "a:b", "a\n", String(repeating: "x", count: 253)] {
            #expect(!files.rename(to: invalid))
            let expected: PadError = invalid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .emptyName : invalid.utf8.count > 252 ? .nameTooLong : .invalidName
            #expect(files.error == expected.message())
            #expect(files.url == original)
        }
        try Data("external edit".utf8).write(to: original)
        #expect(!files.rename(to: "new"))
        #expect(alerts.last == PadError.changed.alert())
        #expect(files.error == nil)
        #expect(files.text == "local edit")
        #expect(files.savedText == "original")
        #expect(try String(contentsOf: original, encoding: .utf8) == "external edit")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "new.txt").path))
    }

    @Test func scratchCustomNameNeverOverwritesAnExistingFile() throws {
        let (files, root, defaults, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appending(path: "existing.txt")
        try Data("keep".utf8).write(to: existing)
        files.text = "scratch"
        #expect(!files.rename(to: "existing"))
        #expect(files.url == nil)
        #expect(files.displayName == "Untitled")
        #expect(files.isDirty)
        #expect(files.error == PadError.nameExists.message())
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
        #expect(defaults.integer(forKey: "pad.nextNumber") == 0)
        // A unique name is accepted; a later collision is still caught by Save.
        #expect(files.rename(to: "Unique"))
        let unique = root.appending(path: "Unique.txt")
        try Data("arrived later".utf8).write(to: unique)
        files.save()
        #expect(files.url == nil)
        #expect(files.displayName == "Unique.txt")
        #expect(files.error == PadError.nameExists.message())
        #expect(try String(contentsOf: unique, encoding: .utf8) == "arrived later")
    }

    // MARK: RTF documents

    /// Copies an Inkkit fixture into a disposable folder.
    private func rtfFixture(_ name: String, in root: URL, as fileName: String? = nil) throws -> URL {
        let source = try #require(Bundle(for: PadFixtureBundle.self).url(forResource: name, withExtension: nil),
                                  "Missing fixture \(name)")
        let destination = root.appending(path: fileName ?? name)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    @Test(arguments: ["textedit-marks.rtf", "textedit-lists.rtf", "textedit-table.rtf", "textedit-layout.rtf",
                      "word-style.rtf", "web-copy.rtf"])
    func rtfFileOpensEditsSavesAndReopens(_ name: String) throws {
        let (files, root, _, _) = try fixture(format: .md)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try rtfFixture(name, in: root)
        let original = try Data(contentsOf: url)
        files.open(url)
        #expect(files.url == url)
        #expect(files.currentFormat == .rtf)
        #expect(!files.isDirty)
        var document = try PadRichText.document(from: files.text)
        #expect(document == (try RTFConverter.document(fromRTF: original)))
        document.blocks.append(.paragraph(.init([.text("Added in PadPad", marks: [.underline])], align: .right)))
        files.text = try PadRichText.text(for: document)
        #expect(files.isDirty)
        files.save()
        #expect(files.error == nil)
        #expect(!files.isDirty)
        let written = try Data(contentsOf: url)
        #expect(written != original)
        #expect(try RTFConverter.document(fromRTF: written) == document)

        let (reopened, otherRoot, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        reopened.open(url)
        #expect(reopened.currentFormat == .rtf)
        #expect(try PadRichText.document(from: reopened.text) == document)
        #expect(!reopened.isDirty)
    }

    @Test func uneditedRTFFileIsNeverRewritten() async throws {
        let (files, root, _, _) = try fixture(selectSaveFile: { directory, _ in directory.appending(path: "copy.rtf") })
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try rtfFixture("word-style.rtf", in: root)
        let original = try Data(contentsOf: url)
        let modified = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        files.open(url)
        // An explicit Save, a focus refresh, closing and quitting leave the file alone.
        files.save()
        files.refreshIfNeeded()
        #expect(files.canTerminate())
        files.close()
        #expect(files.error == nil)
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == modified)
        // Save As of an unedited document copies the original bytes, fonts and colors included.
        await files.saveAs()
        #expect(files.url == root.appending(path: "copy.rtf"))
        #expect(try Data(contentsOf: root.appending(path: "copy.rtf")) == original)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func refusedRTFFilesDoNotOpen() throws {
        let alerts = AlertRecorder()
        let (files, root, _, _) = try fixture(format: .md, alerts: alerts)
        defer { try? FileManager.default.removeItem(at: root) }
        files.text = "Keep this draft"
        let picture = try rtfFixture("tm-image-rtfd-text.rtf", in: root)
        let package = try rtfFixture("tm-image.rtfd", in: root)
        let disguisedPackage = try rtfFixture("tm-image.rtfd", in: root, as: "disguised.rtf")
        let notRTF = root.appending(path: "plain.rtf")
        try Data("Just text".utf8).write(to: notRTF)
        let damaged = root.appending(path: "damaged.rtf")
        try Data(#"{\rtf1\ansi {\b unbalanced"#.utf8).write(to: damaged)
        let cases: [(URL, PadAlert)] = [
            (picture, PadAlert(title: "PadPad can’t open this document",
                               message: "This document has pictures or other content PadPad can’t keep. Open it in TextEdit instead.")),
            (package, try #require(PadError.unsupported.alert(during: .open))),
            (disguisedPackage, PadAlert(title: "This file isn’t an RTF document",
                                        message: "It has the .rtf extension but contains another format. Open it in TextEdit instead.")),
            (notRTF, PadAlert(title: "This file isn’t an RTF document",
                              message: "It has the .rtf extension but contains another format. Open it in TextEdit instead.")),
            (damaged, PadAlert(title: "This RTF document is damaged", message: "PadPad can’t read it. Try opening it in TextEdit.")),
        ]
        for (url, alert) in cases {
            #expect(!files.openDocument(url), "\(url.lastPathComponent) must not open")
            #expect(alerts.last == alert, "\(url.lastPathComponent)")
            #expect(files.url == nil)
            #expect(files.text == "Keep this draft")
            #expect(files.currentFormat == .md)
        }
        #expect(PadError.unsupported.alert(during: .open)?.message == "Choose a Markdown (.md), plain text (.txt), or RTF (.rtf) file.")

        // A workspace never makes a window for a refused file.
        let settingsSuite = "pad-rtf-refused-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: settingsSuite))
        defer { defaults.removePersistentDomain(forName: settingsSuite) }
        let workspace = PadWorkspace(settings: AppSettings(defaults: defaults), defaults: defaults,
                                     presentsWindows: false, defaultFolder: root, presentAlert: alerts.present)
        workspace.open(picture)
        #expect(workspace.documents.isEmpty)
        #expect(workspace.document(at: picture) == nil)
    }

    @Test func externalEditsToRTFFilesNeverOverwriteOrLoseContent() throws {
        let alerts = AlertRecorder()
        let (files, root, _, _) = try fixture(alerts: alerts)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try rtfFixture("textedit-marks.rtf", in: root)
        files.open(url)
        // A clean document follows a readable external change.
        let external = RichTextDocument(blocks: [.paragraph(.init([.text("Changed elsewhere", marks: [.italic])]))])
        let externalBytes = try RTFConverter.rtfData(from: external)
        try externalBytes.write(to: url)
        files.open(url)
        #expect(try PadRichText.document(from: files.text) == external)
        #expect(!files.isDirty)

        // A clean document refuses an external change it can't keep and keeps the file safe from Save.
        let pictureBytes = try Data(contentsOf: try rtfFixture("tm-image-rtfd-text.rtf", in: root, as: "picture.rtf"))
        try pictureBytes.write(to: url)
        files.open(url)
        #expect(alerts.last == PadAlert(title: "PadPad can’t reload this document",
                                        message: "It was changed elsewhere and now has pictures or other content PadPad can’t keep. Open it in TextEdit instead."))
        #expect(try PadRichText.document(from: files.text) == external)
        files.text = try PadRichText.text(for: RichTextDocument(blocks: [.paragraph(.init([.text("Local edit")]))]))
        files.save()
        #expect(alerts.last == PadError.changed.alert())
        #expect(try Data(contentsOf: url) == pictureBytes)

        // A dirty document reports the conflict and leaves the external bytes alone.
        let laterBytes = try RTFConverter.rtfData(from: RichTextDocument(blocks: [.paragraph(.init([.text("Later")]))]))
        try laterBytes.write(to: url)
        let count = alerts.alerts.count
        files.save()
        #expect(alerts.alerts.count == count + 1)
        #expect(alerts.last == PadError.changed.alert())
        #expect(files.isDirty)
        #expect(try Data(contentsOf: url) == laterBytes)
    }

    @Test func rtfWriteFailureKeepsTheDocumentAndTheFile() throws {
        let alerts = AlertRecorder()
        let (files, root, _, _) = try fixture(alerts: alerts)
        let locked = root.appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        let url = try rtfFixture("textedit-lists.rtf", in: locked, as: "lists.rtf")
        let original = try Data(contentsOf: url)
        files.open(url)

        // A document the converter refuses fails before anything is written.
        files.text = #"{"version":2,"blocks":[]}"#
        files.save()
        #expect(alerts.last == expectedAlert(RTFConversionError.invalidDocument("version"), during: .save))
        #expect(alerts.last?.title == "Couldn’t save your changes")
        #expect(files.isDirty)
        #expect(try Data(contentsOf: url) == original)

        // A folder that refuses the atomic write keeps the document open and edited.
        let edited = try PadRichText.text(for: RichTextDocument(blocks: [.paragraph(.init([.text("Edited")]))]))
        files.text = edited
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        files.save()
        #expect(alerts.last?.action == .saveAs)
        #expect(files.url == url)
        #expect(files.text == edited)
        #expect(files.isDirty)
        #expect(try Data(contentsOf: url) == original)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: locked.path)
        #expect(leftovers == ["lists.rtf"])
    }

    @Test func sharingAnEditedRTFDocumentWritesRTF() throws {
        let (files, root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try rtfFixture("textedit-marks.rtf", in: root)
        files.open(url)
        #expect(try files.shareableURL(in: root) == url)
        let edited = RichTextDocument(blocks: [.paragraph(.init([.text("Shared", marks: [.bold])]))])
        files.text = try PadRichText.text(for: edited)
        let shared = try files.shareableURL(in: root)
        #expect(shared.lastPathComponent == "textedit-marks.rtf")
        #expect(shared != url)
        #expect(try RTFConverter.document(contentsOf: shared) == edited)
    }
}

@MainActor
private final class PadDiscardDecision {
    var discard = false
    var confirmations = 0
    weak var current: PadDocument?
}

@MainActor
private final class PendingPadSelection {
    private var selection: CheckedContinuation<URL?, Never>?
    private var presentation: CheckedContinuation<Void, Never>?

    func select() async -> URL? {
        await withCheckedContinuation { continuation in
            selection = continuation
            presentation?.resume()
            presentation = nil
        }
    }

    func waitUntilPresented() async {
        guard selection == nil else { return }
        await withCheckedContinuation { presentation = $0 }
    }

    func complete(_ url: URL?) {
        selection?.resume(returning: url)
        selection = nil
    }
}

/// Finds the test bundle, which holds the RTF fixtures copied from Inkkit.
private final class PadFixtureBundle {}
