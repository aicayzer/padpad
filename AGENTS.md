# PadPad

PadPad is a native macOS app for editing individual plain text, Markdown and RTF files. It has no note library, CLI, updater, or integration with another app.

Commands, tests and CI are in [DEVELOPMENT.md](DEVELOPMENT.md); distribution is in [RELEASING.md](RELEASING.md). This file holds the rules and product behavior those files do not.

## Product behavior

### Launch, windows and access

- Initial launch stays hidden, including login launch. The global shortcut always targets the quick pad.
- Opening a supported file creates an independent document window and leaves quick-pad text alone. Reopening the same file brings its window forward.
- Open file windows keep the app in the Dock, including while minimized. Closing the last one restores the saved access preference. Hidden access omits the Dock and menu bar icons; reopening the app or using the global shortcut still shows the quick pad.
- Defaults: quick pad 740 × 480 points, file windows 800 × 860 points, constrained to the screen. Defaults and the centered reading width are configurable. Initial placement and restoration use AppKit optical centering, and native file-window controls align with the custom header.
- Restore Default Size restores the dimensions for that window type. Only the quick pad uses optional center snapping and its 1,200-point width ceiling.

### Header and formatting

- The Aa control beside Share opens the formatting menu at every window width. It lists only the commands the loaded format supports, taken from InkKit command state: RTF shows alignment instead of headings, quotes and code blocks.
- The right header orders Share, Aa and Save. Window and file actions stay in the native menus.
- Formatting controls use neutral adaptive foreground colors, not the accent color.
- Formatting shortcuts work independently of the menu. Restore Default Size and Copy All Contents use configurable local shortcut recorders.
- The centered formatting toolbar stays behind the disabled `usesCenteredFormattingToolbar` switch in `App/Document/PadPanel.swift` for possible future use.

### Scratch text

Scratch text is intentionally temporary, because the quick pad is a scratch surface and not a library.

- With automatic saving off, closing hides the quick pad. Reopening within the configured time away restores the text; reopening after expiry starts empty, with no recovery archive or discard prompt.
- Start the interval on dismissal and restart it after every reopen and dismiss cycle. Never expire active text. Settings and owned dialogs are not dismissal.
- Do not discard scratch text on close or focus loss. It lives in memory only, so quitting does not preserve it.
- Automatic saving and explicit Save preserve work as files. Expiry must never delete a saved file or silently discard edits to an opened file.
- Discarded-draft recovery is deferred. Do not add an archive or retention mechanism.

### Formats

- **Markdown** shows editable formatted content with no automatic fallback to source mode. Keep unsupported constructs as literal content and the exact source until edited. Show soft line breaks as line breaks without rewriting their source syntax. Keep authored empty paragraphs across saving and reopening. There is no image management.
- **Plain text** is a separate supported format.
- **RTF** opens through `InkKitRTF` and edits in InkKit's formatted mode. `PadDocument.text` holds RTF as canonical `RichTextDocument` JSON (`PadRichText`). If the converter refuses a file (pictures, RTFD, merged cells and other content it cannot keep), leave it closed with an alert; never open it in a way a later save could overwrite. An unedited RTF file is never rewritten, and an unedited Save As copies its bytes. RTFD packages are an unsupported type.
- The footer format button cycles unsaved quick-pad drafts through the enabled formats in MD, TXT, RTF order. MD and TXT keep the exact source. A switch to or from RTF converts, and any conversion that loses something, including every RTF to TXT switch, needs confirmation first.
- File-backed windows respect their extension and omit the footer switch. Explicit Save As can convert a copy and keep the original.
- Settings: Files groups the enabled quick-pad formats under Formats and puts the default format at the top of Drafts. Editor controls format-button visibility under Text.

### Clipboard

- Ordinary Copy and Copy All Contents export readable text plus semantic HTML, never Markdown-escaped plain text. Copy as Markdown explicitly exports source.
- Copy All preserves the selection and respects existing shortcut bindings. If content retrieval fails, it leaves the clipboard untouched.

### Messages

`PadProblem` in `App/Document/PadMessages.swift` alone decides the tier.

- Confirmations and small problems with an obvious fix share one pill at the bottom left of the editor card. Confirmations clear themselves; a problem clears when clicked or when its cause goes away.
- Problems that need a decision or block work are an NSAlert, shown as a sheet on the document window and offering the next step through an existing command.
- A file that fails to open has no window, so its alert is a sheet on the window in use, or on the quick pad, which it shows. An unattached app-modal alert can open out of sight.
- Copy follows the Writing section of Apple's Human Interface Guidelines.

### Onboarding and reset

- Onboarding appears on the first intentional opening of an empty draft, never on background launch or file opening. Next opens shortcut practice. Done stays disabled until the configured global shortcut succeeds, Return performs the enabled primary action, and arrow keys move between the two pages without completing practice. Skip stays available without a configured shortcut. Replay preserves the current document.
- Reset App resets preferences, shortcuts and onboarding without deleting writing or saved files. Capture every live editor before reset or termination.

## Document safety

- Obtain a current, document-scoped editor snapshot before saving, sharing, replacing, closing or quitting. Await it; a script failure must retain the document and the clipboard, and show an error.
- Keep file operations independent of UI presentation, so tests can reach them.

## Architecture

- `App/Document/` owns document state, persistence, naming, format conversion and the native editor panel. `App/Editor/` owns the offline InkKit bridge (Markdown and RTF) and focus helpers.
- `editor/` is a thin host bootstrap for `@aicayzer/inkkit`, bundled offline. [editor/BRIDGE.md](editor/BRIDGE.md) defines the bridge protocol. InkKit owns Markdown preservation, tables, clipboard conversion and optional managed images, so a shared-engine fix and its regression test belong in the InkKit repository. Tests here check the package facade.
- The app delegate owns the lifecycle through `PadWorkspace`, which retains the quick pad and the independent file documents. Menus target the focused document; Settings configure the quick pad and shared preferences.
- `project.yml` is the source for identity and build configuration. The generated `Pad.xcodeproj` and shared schemes are committed for Xcode Cloud; regenerate and commit them together, because CI fails if they differ.
- Release is PadPad with the standard icon. Debug is PadPad Dev, with its own identity, preferences, shortcut and DEV icon. Test hosts use disposable storage and disable global shortcuts.

## Verification

- Unit tests do not prove window behavior. For changes to focus, file dialogs, close and discard, naming collisions, external edits, save, rename or windows, run the native interaction checks in [DEVELOPMENT.md](DEVELOPMENT.md).
- Window and UI tests take over the keyboard, mouse and windows of their session. Run them only in an isolated GUI session on a machine nobody is using, never on an occupied workstation.
- Use disposable files, never personal documents.
- A running Debug preview may be in use. Check before quitting or replacing it; `scripts/build_and_run.sh` refuses to rebuild a running one.

## Conventions

- American English in repository content. Short, scoped Conventional Commits.
- Use feature branches and pull requests. Required CI must pass before a squash merge; delete the merged branch.
- Public pull requests use hosted CI only; never attach a persistent personal runner.
- Preserve unrelated changes and supplied artwork. Add no compatibility aliases, legacy code or preference migrations.
- Keep credentials, signing identities, personal paths and machine details out of the repository. Local signing is rendered into the ignored `Config/Local.xcconfig`; never hand-edit it.

## Delivery

PadPad ships through TestFlight and the App Store only. Treat a request for a "new release" or "new version" as a TestFlight candidate unless App Store submission is explicitly requested. Read [RELEASING.md](RELEASING.md) and the current App Store Connect state before choosing numbers.

- Keep the planned public version across successive candidates. Xcode Cloud increments the build number; each candidate gets a new immutable `vMAJOR.MINOR.PATCH-beta.N` tag.
- Start the next public version with a patch increment unless the change warrants an agreed larger one. Never bump the public version only to upload another candidate.
- After upload, verify processing and internal tester availability, then hand the exact version and build over for TestFlight acceptance. Submit that build to the App Store only after acceptance and explicit authorization.
- Keep GitHub candidates marked prerelease. Mark a release stable and Latest only when its exact build is public on the App Store.
