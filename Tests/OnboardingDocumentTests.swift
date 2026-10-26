import Foundation
import Testing
@testable import Pad

@MainActor
@Suite struct OnboardingDocumentTests {
    @Test func constructionAndHeadlessSummonsDoNotImplicitlyPresentOnboarding() throws {
        let fixture = try OnboardingDocumentFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        #expect(!document.onboarding.isPresented)
        #expect(!document.isActive)
        document.showCurrent()
        document.toggle()
        document.commandNew()
        #expect(!document.onboarding.isPresented)
        #expect(!document.onboarding.hasCompleted)
        #expect(document.text.isEmpty)
    }

    @Test func explicitReplayCapturesDirtyDocumentWithoutSavingOrChangingIdentity() async throws {
        let fixture = try OnboardingDocumentFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        let file = fixture.root.appending(path: "my-document.md")
        try Data("saved version".utf8).write(to: file)
        document.open(file)
        document.saveAutomatically = true
        document.onboarding.complete()
        let id = document.documentID
        let source = "# Latest edit\r\n\n**Still unsaved**\n"
        document.editorSnapshot = { source }
        await document.restartOnboarding()
        #expect(document.onboarding.isPresented)
        #expect(!document.onboarding.hasCompleted)
        #expect(!fixture.defaults.bool(forKey: "pad.onboardingCompleted"))
        #expect(!document.isActive)
        #expect(document.text == source)
        #expect(document.savedText == "saved version")
        #expect(document.url == file)
        #expect(document.documentID == id)
        #expect(document.isDirty)
        document.finishOnboarding(includeExample: true)
        #expect(!document.onboarding.isPresented)
        #expect(document.onboarding.hasCompleted)
        #expect(document.text == source)
        #expect(document.documentID == id)
        #expect(document.url == file)
        #expect(document.saveAutomatically)
        #expect(try String(contentsOf: file, encoding: .utf8) == "saved version")
    }

    @Test func replaySnapshotFailureKeepsDocumentAndDoesNotPresentWelcome() async throws {
        let fixture = try OnboardingDocumentFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "Keep my scratch"
        let id = document.documentID
        document.editorSnapshot = { throw CocoaError(.fileReadUnknown) }
        await document.restartOnboarding()
        #expect(!document.onboarding.isPresented)
        #expect(document.text == "Keep my scratch")
        #expect(document.documentID == id)
        #expect(document.error == expectedMessage(CocoaError(.fileReadUnknown), during: .snapshot))
        #expect(try fixture.savedFiles().isEmpty)
    }

    @Test func practiceShortcutNeverCompletesOrHidesOnboarding() async throws {
        let fixture = try OnboardingDocumentFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        await document.restartOnboarding()
        document.handleGlobalShortcut()
        #expect(document.onboarding.stage == .intro)
        #expect(document.onboarding.practiceCount == 0)
        document.onboarding.startPractice()
        document.handleGlobalShortcut()
        document.handleGlobalShortcut()
        #expect(document.onboarding.stage == .practice)
        #expect(document.onboarding.practiceCount >= 1)
        #expect(document.onboarding.isPresented)
        #expect(!document.onboarding.hasCompleted)
        #expect(!document.isActive)
        #expect(document.text.isEmpty)
    }

    @Test func exampleUsesMarkdownWithoutChangingDefaultOrSavingFile() async throws {
        let fixture = try OnboardingDocumentFixture(defaultFormat: .txt)
        defer { fixture.cleanUp() }
        let document = fixture.document
        let id = document.documentID
        await document.restartOnboarding()
        document.finishOnboarding(includeExample: true)
        #expect(document.currentFormat == .md)
        #expect(document.text.hasPrefix("# "))
        #expect(document.text.contains("- [ ]"))
        #expect(document.text.contains("**Keep what matters.**"))
        #expect(document.format == .txt)
        #expect(fixture.defaults.string(forKey: "pad.format") == "txt")
        #expect(document.url == nil)
        #expect(document.documentID == id)
        #expect(document.isDirty)
        #expect(try fixture.savedFiles().isEmpty)
    }

    @Test func skipLeavesPristineEditorEmptyAndCompletesWelcome() async throws {
        let fixture = try OnboardingDocumentFixture(defaultFormat: .txt)
        defer { fixture.cleanUp() }
        let document = fixture.document
        await document.restartOnboarding()
        document.finishOnboarding(includeExample: false)
        #expect(document.text.isEmpty)
        #expect(document.currentFormat == .txt)
        #expect(document.onboarding.hasCompleted)
        #expect(!document.onboarding.isPresented)
        #expect(!document.isDirty)
    }

    @Test func closingReplayUsesNormalScratchExpiryWithoutCompletingWelcome() async throws {
        let fixture = try OnboardingDocumentFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "A retained scratch"
        let id = document.documentID
        await document.restartOnboarding()
        let now = Date(timeIntervalSince1970: 1_790_113_017)
        document.close(now: now)
        #expect(!document.onboarding.isPresented)
        #expect(!document.onboarding.hasCompleted)
        #expect(document.text == "A retained scratch")
        #expect(try fixture.savedFiles().isEmpty)
        document.showCurrent(now: now.addingTimeInterval(899))
        #expect(document.text == "A retained scratch")
        #expect(document.documentID == id)
        document.close(now: now.addingTimeInterval(900))
        document.showCurrent(now: now.addingTimeInterval(1800))
        #expect(document.text.isEmpty)
    }

    @Test func closingReplayHonorsAutomaticSaving() async throws {
        let fixture = try OnboardingDocumentFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "Save when closing"
        document.saveAutomatically = true
        await document.restartOnboarding()
        document.close()
        #expect(!document.onboarding.hasCompleted)
        #expect(!document.onboarding.isPresented)
        let file = try #require(document.url)
        #expect(try String(contentsOf: file, encoding: .utf8) == "Save when closing")
    }

    @Test func closingPristineWelcomeHidesWithoutCompletingOrCreatingFile() async throws {
        let fixture = try OnboardingDocumentFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        await document.restartOnboarding()
        document.close()
        #expect(!document.onboarding.isPresented)
        #expect(!document.onboarding.hasCompleted)
        #expect(!document.isActive)
        #expect(document.text.isEmpty)
        #expect(try fixture.savedFiles().isEmpty)
    }

    @Test func openingAFileBypassesPresentedOnboarding() async throws {
        let fixture = try OnboardingDocumentFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        let file = fixture.root.appending(path: "opened.txt")
        try Data("An existing file".utf8).write(to: file)
        await document.restartOnboarding()
        document.open(file)
        #expect(!document.onboarding.isPresented)
        #expect(!document.onboarding.hasCompleted)
        #expect(document.url == file)
        #expect(document.text == "An existing file")
    }

    @Test func failedFileOpenLeavesOnboardingAndAlertsOverTheRetainedDocument() async throws {
        let fixture = try OnboardingDocumentFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "Keep this draft"
        let id = document.documentID
        await document.restartOnboarding()
        document.open(fixture.root.appending(path: "missing.txt"))
        #expect(!document.onboarding.isPresented)
        #expect(fixture.alerts.last == expectedAlert(CocoaError(.fileReadNoSuchFile), during: .open))
        #expect(document.text == "Keep this draft")
        #expect(document.documentID == id)
        #expect(document.url == nil)
    }
}

@MainActor
private struct OnboardingDocumentFixture {
    let root: URL
    let defaults: UserDefaults
    let document: PadDocument
    let alerts = AlertRecorder()
    private let suite: String

    init(defaultFormat: PadFormat = .md) throws {
        suite = "pad-onboarding-document-tests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(defaultFormat.rawValue, forKey: "pad.format")
        root = FileManager.default.temporaryDirectory.appending(path: suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        document = PadDocument(defaults: defaults, defaultFolder: root, presentsWindow: false,
                               copyPath: { _ in }, resolveUnsavedChanges: { .cancel }, presentAlert: alerts.present)
        document.saveAutomatically = false
    }

    func savedFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}
