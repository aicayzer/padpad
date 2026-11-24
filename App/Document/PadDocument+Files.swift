import AppKit
import Darwin

// Reading, saving, renaming and sharing files, and the save folder.
extension PadDocument {
    func prepareToTerminate() async -> Bool {
        guard !isBusy else { return false }
        operation = .transition
        let captured = await captureLatestEditor()
        operation = nil
        return captured && canTerminate()
    }

    func chooseFolder(parent: NSWindow? = nil) async {
        guard !isBusy else { return }
        operation = .filePanel
        defer { operation = nil }
        let chosen: URL?
        if let selectSaveFolder {
            chosen = selectSaveFolder(folder)
        } else {
            let picker = saveFolderPicker(directory: folder)
            chosen = await present(picker, parent: parent ?? dialogParent) == .OK ? picker.url : nil
        }
        guard let chosen else { return }
        do {
            try rememberSaveFolder(chosen)
            folderError = nil
        } catch { folderError = "PadPad can’t use this folder. Choose another one." }
    }

    private func saveFolderPicker(directory: URL) -> NSOpenPanel {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        picker.prompt = "Use Folder"
        picker.message = "Choose a folder for quick-pad files. PadPad will remember your choice."
        picker.directoryURL = directory
        return picker
    }

    private func rememberSaveFolder(_ chosen: URL) throws {
        let accessing = chosen.startAccessingSecurityScopedResource()
        do {
            guard try chosen.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw PadError.missingFolder
            }
            let data = try chosen.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            folderScope?.stopAccessingSecurityScopedResource()
            defaults.set(data, forKey: Self.folderBookmarkKey)
            folder = chosen
            folderScope = accessing ? chosen : nil
        } catch {
            if accessing { chosen.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    private func obtainSaveFolderAccess() throws -> Bool {
        guard !hasSaveFolderAccess else { return true }
        // Close, New Draft, and Quit wait synchronously for a save decision.
        // Keep their transition locked while the native folder chooser runs.
        let previousOperation = operation
        operation = .filePanel
        defer { operation = previousOperation }
        let chosen: URL?
        if let selectSaveFolder {
            chosen = selectSaveFolder(folder)
        } else {
            NSApp.activate()
            let picker = saveFolderPicker(directory: folder)
            chosen = picker.runModal() == .OK ? picker.url : nil
        }
        guard let chosen else { return false }
        try rememberSaveFolder(chosen)
        guard hasSaveFolderAccess else { throw PadError.missingFolder }
        return true
    }

    func forgetSaveFolder() {
        folderScope?.stopAccessingSecurityScopedResource()
        folderScope = nil
        defaults.removeObject(forKey: Self.folderBookmarkKey)
        folder = Self.downloadsFolder
    }

    func openPicker() async {
        guard !isBusy else { return }
        operation = .filePanel
        defer { operation = nil }
        guard await captureLatestEditor() else { return }
        let chosen = if let selectOpenFile { await selectOpenFile() } else { await presentOpenPanel() }
        guard let chosen else { return }
        if let workspace { workspace.open(chosen) } else { openDocument(chosen) }
    }

    private func presentOpenPanel() async -> URL? {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = PadFormat.allCases.map(\.contentType)
        picker.allowsOtherFileTypes = false
        guard await present(picker, parent: dialogParent) == .OK else { return nil }
        return picker.url
    }

    func open(_ file: URL) {
        if let workspace { workspace.open(file); return }
        if synchronizeEditorThen({ self.open(file) }) { return }
        guard !isBusy else { return }
        operation = .transition
        defer { operation = nil }
        openDocument(file)
    }

    /// Loads a file into this document. The workspace opens each file in a new file window; tests also load
    /// files into a quick pad without a workspace. Onboarding belongs to the quick pad, which the workspace never
    /// opens a file into, so opening never involves it.
    @discardableResult
    func openDocument(_ file: URL) -> Bool {
        // RTFD packages are not supported; their extension is refused like any other type.
        guard let format = PadFormat(rawValue: file.pathExtension.lowercased()) else {
            if isQuickPad || url != nil { show() }
            report(PadError.unsupported, during: .open)
            return false
        }
        if file.standardizedFileURL == url?.standardizedFileURL {
            refreshCurrentFile()
            show()
            return true
        }
        let accessing = file.startAccessingSecurityScopedResource()
        do {
            // An RTF file that holds content PadPad can't keep throws here, before anything is replaced.
            let (bytes, content) = try format.read(file)
            guard finishCurrent() else {
                if accessing { file.stopAccessingSecurityScopedResource() }
                return false
            }
            documentScope?.stopAccessingSecurityScopedResource()
            documentScope = accessing ? file : nil
            startsInReadingMode = true
            documentID = UUID()
            url = file
            pendingReadingDocumentID = currentFormat.usesEditor ? documentID : nil
            text = content
            savedText = content
            baseline = bytes
            dismissedAt = nil
            pendingName = nil
            error = nil
            reportedReadFailure = nil
            notice = nil
            panel?.prepareReading()
            reloadEditor()
            show()
            return true
        } catch {
            if accessing { file.stopAccessingSecurityScopedResource() }
            if isQuickPad || url != nil { show() }
            report(error, during: .open)
            return false
        }
    }

    func refreshIfNeeded() {
        guard url != nil, !isBusy, !onboarding.isPresented else { return }
        // A newly mounted web editor has already received the disk contents.
        if let editor = markdownEditor, !editor.isReady { return }
        if synchronizeEditorThen({ self.refreshIfNeeded() }) { return }
        refreshCurrentFile()
    }

    private func refreshCurrentFile() {
        guard let url else { return }
        var observedBytes: Data?
        do {
            let bytes = try Data(contentsOf: url)
            observedBytes = bytes
            if isDirty {
                if currentFormat != .rtf, String(data: bytes, encoding: .utf8) == nil { throw PadError.encoding }
                guard bytes == baseline else { throw PadError.changed }
            } else if currentFormat == .rtf, bytes == baseline {
                // Converting unchanged bytes again would only reset the editor.
            } else {
                // A refused RTF change keeps the old baseline, so a later save reports the conflict.
                let content = try currentFormat.decode(bytes)
                text = content
                savedText = content
                baseline = bytes
                notice = nil
                reloadEditor()
            }
            error = nil
            reportedReadFailure = nil
        } catch {
            let failure = error as NSError
            // Only a confirmed missing file permits discarding a clean quick pad.
            // Permission, decoding and snapshot failures retain recoverable text.
            if isQuickPad, !isDirty, failure.domain == NSCocoaErrorDomain,
               failure.code == NSFileReadNoSuchFileError {
                resetDocument()
                return
            }
            report(error, during: .read, observedBytes: observedBytes)
        }
    }

    func save() {
        if synchronizeEditorThen({ self.save() }) { return }
        // A draft with nothing in it never becomes a file, including through the keyboard shortcut.
        guard !isBusy, url != nil || isDirty else { return }
        saveCurrent()
    }

    /// A file window has a path to copy. A draft with text saves first, as Save does.
    var canCopyPath: Bool { url != nil || isDirty }

    func copyFilePath() {
        if let url {
            guard !isBusy else { return }
            copyPath(url.path)
            announceFile("Path copied")
            return
        }
        guard isDirty else { return }
        if synchronizeEditorThen({ self.copyFilePath() }) { return }
        guard !isBusy, isDirty else { return }
        saveCurrent(copyingPath: true)
    }

    private func saveCurrent(copyingPath: Bool = false) {
        recordDiagnostic(.save)
        let namesFile = url == nil && pendingName == nil
        var observedBytes: Data?
        do {
            if let url {
                let bytesOnDisk = try Data(contentsOf: url)
                observedBytes = bytesOnDisk
                guard bytesOnDisk == baseline else { throw PadError.changed }
                // An up-to-date file is never rewritten; for RTF, writing would also restyle the whole file.
                if !isDirty {
                    announceFile("Saved")
                    error = nil
                    reportedReadFailure = nil
                    recordDiagnostic(.saveSucceeded)
                    return
                }
                // Conversion finishes before the atomic write, so a failure never leaves partial bytes.
                let bytes = try currentFormat.encode(text)
                try bytes.write(to: url, options: .atomic)
                baseline = bytes
                savedText = text
                announceFile("Saved")
            } else {
                guard try obtainSaveFolderAccess() else { return }
                let bytes = try currentFormat.encode(text)
                let destination: URL
                if let pendingName {
                    destination = folder.appending(path: try PadFilename.filename(stem: pendingName, extension: currentFormat.rawValue))
                    guard !FileManager.default.fileExists(atPath: destination.path) else { throw PadError.nameExists }
                    try bytes.write(to: destination, options: .withoutOverwriting)
                } else {
                    destination = try saveGeneratedFile(bytes)
                }
                url = destination
                pendingName = nil
                baseline = bytes
                savedText = text
                documentScope = folder.startAccessingSecurityScopedResource() ? folder : nil
                if copyingPath || drafts.copiesPathOnSave {
                    copyPath(destination.path)
                    announceFile("Saved. Path copied.")
                } else {
                    announceFile("Saved")
                }
            }
            error = nil
            reportedReadFailure = nil
            updateTitle()
            recordDiagnostic(.saveSucceeded)
        } catch { report(error, during: namesFile ? .nameFormat : .save, observedBytes: observedBytes) }
    }

    func saveAs(targetFormat: PadFormat? = nil) async {
        guard !isBusy else { return }
        operation = .filePanel
        defer { operation = nil }
        guard await captureLatestEditor() else { return }
        let previousFormat = currentFormat
        let saveFormat = targetFormat ?? currentFormat
        let id = documentID
        var content = text
        let directory = url?.deletingLastPathComponent() ?? folder
        let suggestion: (name: String, number: Int?)
        do {
            if let url {
                let name = targetFormat == nil ? url.lastPathComponent
                    : url.deletingPathExtension().appendingPathExtension(saveFormat.rawValue).lastPathComponent
                suggestion = (name, nil)
            } else if let pendingName {
                suggestion = (try PadFilename.filename(stem: pendingName, extension: saveFormat.rawValue), nil)
            } else {
                let now = currentDate()
                let generated = try PadFilename.available(in: directory, parts: drafts.nameParts, format: saveFormat,
                                                             now: now, number: drafts.startingNumber(on: now))
                guard generated.number < Int.max else { throw PadError.invalidName }
                suggestion = (generated.url.lastPathComponent, generated.number)
            }
        } catch {
            report(error, during: url == nil && pendingName == nil ? .nameFormat : .saveAs)
            return
        }
        let destination = if let selectSaveFile {
            await selectSaveFile(directory, suggestion.name)
        } else {
            await presentSavePanel(directory: directory, name: suggestion.name, targetFormat: targetFormat)
        }
        guard let destination, documentID == id else { return }
        let accessing = destination.startAccessingSecurityScopedResource()
        var observedBytes: Data?
        do {
            guard let destinationFormat = PadFormat(rawValue: destination.pathExtension.lowercased()) else { throw PadError.unsupported }
            guard workspace?.document(at: destination, excluding: self) == nil else { throw PadError.nameExists }
            if let targetFormat {
                guard destinationFormat == targetFormat else { throw PadError.unsupported }
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw PadError.nameExists }
            }
            if destination.standardizedFileURL == url?.standardizedFileURL {
                let bytes = try Data(contentsOf: destination)
                observedBytes = bytes
                guard bytes == baseline else { throw PadError.changed }
            }
            let unchangedCopy = destinationFormat == previousFormat && content == savedText ? baseline : nil
            var converted = false
            if destinationFormat != previousFormat {
                // The copy converts; the original file keeps its format and bytes.
                guard let conversion = await confirmedConversion(of: content, to: destinationFormat, savingCopy: url != nil),
                      documentID == id else {
                    if accessing { destination.stopAccessingSecurityScopedResource() }
                    return
                }
                converted = conversion.text != content
                content = conversion.text
            }
            // An unedited copy keeps the original bytes, including RTF fonts and colors.
            let bytes = try unchangedCopy ?? destinationFormat.encode(content)
            try bytes.write(to: destination, options: targetFormat == nil ? .atomic : .withoutOverwriting)
            documentScope?.stopAccessingSecurityScopedResource()
            documentScope = accessing ? destination : nil
            url = destination
            pendingName = nil
            baseline = bytes
            // A converted copy replaces the text; otherwise a late edit stays unsaved.
            if converted { text = content }
            savedText = content
            // A retained web editor must follow native edits when Save As changes formats.
            if currentFormat != previousFormat {
                reloadEditor()
                show()
                panel?.resumeEditor()
            }
            if let number = suggestion.number, destination.lastPathComponent == suggestion.name {
                drafts.advanceGeneratedNumber(after: number, on: currentDate())
            }
            error = nil
            reportedReadFailure = nil
            announceFile("Saved")
            updateTitle()
        } catch {
            if accessing { destination.stopAccessingSecurityScopedResource() }
            report(error, during: .saveAs, observedBytes: observedBytes)
        }
    }

    private func presentSavePanel(directory: URL, name: String, targetFormat: PadFormat? = nil) async -> URL? {
        let picker = NSSavePanel()
        picker.allowedContentTypes = PadFormat.allCases.map(\.contentType)
        if let targetFormat {
            picker.allowedContentTypes = [targetFormat.contentType]
            picker.allowsOtherFileTypes = false
        }
        picker.directoryURL = directory
        picker.nameFieldStringValue = name
        guard await present(picker, parent: dialogParent) == .OK else { return nil }
        return picker.url
    }

    func share(from anchor: NSView? = nil) {
        if synchronizeEditorThen({ self.share(from: anchor) }) { return }
        guard canShare, let view = anchor ?? panel?.contentView else { return }
        operation = .sharing
        do {
            let picker = NSSharingServicePicker(items: [try shareableURL()])
            let delegate = PadSharePickerDelegate { [weak self] in
                self?.operation = nil
                self?.sharePicker = nil
                self?.shareDelegate = nil
                if self?.panel?.isKeyWindow == false { self?.lostFocus() }
            }
            picker.delegate = delegate
            sharePicker = picker
            shareDelegate = delegate
            let rect = anchor == nil
                ? NSRect(x: view.bounds.maxX - 90, y: view.bounds.maxY - 38, width: 32, height: 24)
                : view.bounds
            picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
            error = nil
        } catch {
            operation = nil
            report(error, during: .share)
        }
    }

    /// The file to share: the saved file when it is up to date, otherwise a copy of the current text. An empty
    /// draft shares an empty file, named as the draft would be saved.
    func shareableURL(in temporaryFolder: URL = FileManager.default.temporaryDirectory) throws -> URL {
        if let url, !isDirty, let current = try? Data(contentsOf: url), current == baseline { return url }
        let directory = temporaryFolder.appending(path: "PadShare-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name: String
        if let url { name = url.lastPathComponent }
        else if let pendingName { name = "\(pendingName).\(currentFormat.rawValue)" }
        else { name = drafts.nextName(format: currentFormat, now: currentDate()) ?? "Draft.\(currentFormat.rawValue)" }
        let snapshot = directory.appending(path: name)
        try currentFormat.encode(text).write(to: snapshot, options: .atomic)
        return snapshot
    }

    func finishCurrent(retainingDocument: Bool = false) -> Bool {
        guard isDirty else { return true }
        if isQuickPad && drafts.saveAutomatically {
            saveCurrent()
            return !isDirty
        }
        // Hiding retains both scratch and file edits. Only destructive transitions need a decision.
        if retainingDocument { return true }
        if url != nil || !text.isEmpty {
            switch resolveUnsavedChanges?() ?? confirmUnsavedChanges() {
            case .cancel: return false
            case .save:
                saveCurrent()
                return !isDirty
            case .discard:
                text = savedText
                reloadEditor()
            }
        } else {
            resetDocument()
        }
        return true
    }

    func canTerminate() -> Bool {
        guard !isBusy else { return false }
        operation = .transition
        defer { operation = nil }
        return finishCurrent()
    }

    func revealInFinder() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func captureForReset() async -> Bool {
        guard !isBusy else { return false }
        operation = .transition
        defer { operation = nil }
        return await captureLatestEditor()
    }

    func closeFileWindow() async {
        guard !isBusy else { return }
        operation = .transition
        let captured = await captureLatestEditor()
        operation = nil
        guard captured else { return }
        operation = .transition
        defer { operation = nil }
        if isDirty {
            let decision: PadUnsavedChangesDecision
            if let resolveUnsavedChanges { decision = resolveUnsavedChanges() }
            else { decision = await confirmFileClose() }
            switch decision {
            case .cancel: show(); return
            case .save:
                saveCurrent()
                guard !isDirty else { show(); return }
            case .discard:
                text = savedText
            }
        }
        isActive = false
        markdownEditor?.allowsFocus = false
        panel?.finishClosing()
        panel = nil
        documentScope?.stopAccessingSecurityScopedResource()
        documentScope = nil
        folderScope?.stopAccessingSecurityScopedResource()
        folderScope = nil
        workspace?.didClose(self)
    }

    func requestRename() {
        guard isActive, !isBusy, !onboarding.isPresented else { return }
        renameRequest += 1
    }

    @discardableResult
    func rename(to input: String) -> Bool {
        guard !isBusy else { return false }
        var observedBytes: Data?
        do {
            let fileExtension = url?.pathExtension ?? currentFormat.rawValue
            let stem = try PadFilename.validatedStem(input)
            let name = try PadFilename.filename(stem: stem, extension: fileExtension)
            if let source = url {
                let destination = source.deletingLastPathComponent().appending(path: name)
                if destination != source {
                    guard canRenameInContainingFolder(source) else { throw PadError.renamePermission }
                    let bytes = try Data(contentsOf: source)
                    observedBytes = bytes
                    guard bytes == baseline else { throw PadError.changed }
                    // Exclusive rename prevents an existing destination from being replaced, including races.
                    let result = source.withUnsafeFileSystemRepresentation { sourcePath in
                        destination.withUnsafeFileSystemRepresentation { destinationPath in
                            renameatx_np(AT_FDCWD, sourcePath!, AT_FDCWD, destinationPath!, UInt32(RENAME_EXCL))
                        }
                    }
                    guard result == 0 else {
                        switch errno {
                        case EEXIST: throw PadError.nameExists
                        case EACCES, EPERM: throw PadError.renamePermission
                        default: throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                        }
                    }
                    url = destination
                    if documentScope?.standardizedFileURL == source.standardizedFileURL {
                        documentScope?.stopAccessingSecurityScopedResource()
                        documentScope = nil
                    }
                }
            } else {
                let destination = folder.appending(path: name)
                // Draft names refer to the configured save folder. Reject a
                // collision now, while Save still guards against later races.
                var attributes = stat()
                let exists = destination.withUnsafeFileSystemRepresentation { lstat($0!, &attributes) == 0 }
                guard !exists else { throw PadError.nameExists }
                pendingName = stem
            }
            error = nil
            announceFile("Renamed")
            updateTitle()
            return true
        } catch {
            report(error, during: .rename, observedBytes: observedBytes)
            return false
        }
    }

    private func canRenameInContainingFolder(_ source: URL) -> Bool {
        guard documentScope?.standardizedFileURL == source.standardizedFileURL else { return true }
        // A grant for one file does not authorize its new sibling name. Save As can request that grant.
        let directory = source.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
        let authorizedFolders = [FileManager.default.temporaryDirectory] + [folderScope].compactMap { $0 }
        return authorizedFolders.contains { directory.starts(with: $0.resolvingSymlinksInPath().pathComponents) }
    }

    private func saveGeneratedFile(_ bytes: Data) throws -> URL {
        let now = currentDate()
        while true {
            let candidate = try PadFilename.available(in: folder, parts: drafts.nameParts, format: currentFormat,
                                                         now: now, number: drafts.startingNumber(on: now))
            guard candidate.number < Int.max else { throw PadError.invalidName }
            do {
                try bytes.write(to: candidate.url, options: .withoutOverwriting)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
            drafts.advanceGeneratedNumber(after: candidate.number, on: now)
            return candidate.url
        }
    }

    private func present(_ picker: NSSavePanel, parent: NSWindow?) async -> NSApplication.ModalResponse {
        NSApp.activate()
        if let parent, parent.isVisible {
            parent.makeKeyAndOrderFront(nil)
            return await picker.beginSheetModal(for: parent)
        }
        return await picker.begin()
    }

    private func confirmFileClose() async -> PadUnsavedChangesDecision {
        guard let parent = dialogParent else { return confirmUnsavedChanges() }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(displayName)”?"
        alert.informativeText = "Your changes haven’t been saved."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: parent) { response in
                switch response {
                case .alertFirstButtonReturn: continuation.resume(returning: .save)
                case .alertSecondButtonReturn: continuation.resume(returning: .discard)
                default: continuation.resume(returning: .cancel)
                }
            }
        }
    }

    private func confirmUnsavedChanges() -> PadUnsavedChangesDecision {
        let alert = NSAlert()
        alert.messageText = "Save changes?"
        alert.informativeText = "Save your changes to “\(displayName)” before continuing."
        alert.addButton(withTitle: "Save Changes")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        // Lay out before attaching: resizing an attached alert can offset it from its owner.
        alert.layout()
        let parent = dialogParent
        let screen = parent?.screen ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            alert.window.setFrameOrigin(NSPoint(x: frame.midX - alert.window.frame.width / 2,
                                                y: frame.midY - alert.window.frame.height / 2))
        }
        // Keep the alert above a floating Pad without raising unrelated windows.
        parent?.addChildWindow(alert.window, ordered: .above)
        defer { parent?.removeChildWindow(alert.window) }
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
}

final class PadSharePickerDelegate: NSObject, NSSharingServicePickerDelegate {
    let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        onDismiss()
    }
}
