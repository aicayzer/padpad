# PadPad

PadPad is a native macOS app for editing individual text and Markdown files. It has no note library, CLI, updater, or integration with another app.

## Product behavior

- Initial application launch stays hidden, including login launch. The global shortcut always targets the quick pad. Opening a supported file creates an independent document window without replacing quick-pad text; reopening the same file brings its existing window forward. Open file windows keep the app in the Dock, including while minimized; closing the last one restores the saved access preference.
- The Aa control beside Share opens the Markdown formatting menu at every window width. The centered toolbar is retained behind the disabled `usesCenteredFormattingToolbar` internal switch for possible future use. Formatting shortcuts continue to work independently of the menu. The right header orders Share, Aa and Save; window and file actions stay in their native menus. Use neutral adaptive foreground colors for formatting, not the chosen accent. Restore Default Size and Copy All Contents use configurable local shortcut recorders.
- Scratch text is intentionally temporary, including clipboard cleanup. With automatic saving off, closing hides the scratch pad; reopening within its configured time away restores the text. Reopening after expiry starts empty, without a recovery archive or discard prompt. Start the interval on dismissal and restart it after every reopen/dismiss cycle. Never expire active text or treat Settings and owned dialogs as dismissal. Do not discard scratch text immediately on close or focus loss. Scratch stays in memory only; app termination does not preserve it.
- Automatic saving and explicit Save preserve work as files. Scratch expiry must never delete saved files or silently discard edits to an opened file.
- Markdown editing displays editable formatted content without automatic source-mode fallback. Preserve unsupported constructs as literal content and retain the exact source until edited. Display soft line breaks as line breaks without converting their source syntax. Preserve authored empty paragraphs across saving and reopening. Plain text remains a separate supported format; no RTF or image management.
- Ordinary Copy and Copy All Contents export readable text plus semantic HTML, never Markdown-escaped plain text. Copy as Markdown explicitly exports source. Copy All preserves selection, respects existing shortcut bindings, and leaves the clipboard untouched if content retrieval fails.
- Obtain a current, document-scoped editor snapshot before saving, sharing, replacing, closing or quitting. Snapshot and save failures retain the document and show an error.
- Onboarding appears on the first intentional opening of an empty draft, never on background launch or file opening. Next opens shortcut practice. Done stays disabled until the configured global shortcut succeeds; Return performs the enabled primary action, and arrow keys navigate the two pages without completing practice. Skip remains available without a configured shortcut. Replay preserves the current document.
- The MD/TXT footer switches unsaved quick-pad drafts without losing source. File-backed windows respect their extension and omit the footer switch; explicit Save As can convert a copy while retaining the original.
- Quick-pad defaults are 740 × 480 points; file-window defaults are 800 × 860 points, constrained to the screen. Defaults and centered reading width are configurable. Initial placement and restoration use AppKit optical centering; native file-window controls align with the custom header. Restore Default Size restores the appropriate dimensions; only the quick pad uses optional center snapping and its 1,200-point width ceiling.
- Reset App resets preferences, shortcuts and onboarding without deleting writing or saved files. Capture every live editor before reset or termination.
- Discarded-draft recovery is deferred; do not add an archive or retention mechanism implicitly.

## Working conventions

- American English in repository content. Short, scoped Conventional Commits.
- Feature branches and pull requests. Required CI must pass before squash merging; delete merged branches.
- Preserve unrelated changes and supplied artwork. No compatibility aliases, legacy code, or preference migrations.
- Keep credentials, signing identities, personal paths, and machine details out of the repository. Local signing is rendered into ignored configuration.
- Delegate independent work with explicit file ownership. Serialize GUI verification on an isolated test machine; never launch previews or run tests on an actively used workstation.

## Architecture

- `App/Document/` owns document state, persistence, naming and the native editor panel. `App/Editor/` owns the offline Markdown bridge and focus helpers. `editor/` is a thin host bootstrap for `@aicayzer/inkkit`, bundled offline; shared engine fixes and regression tests belong in InkKit.
- The app delegate owns lifecycle through `PadWorkspace`, which retains the quick pad and independent file documents. Menus target the focused document; Settings configure the quick pad and shared preferences. Keep file operations independent of UI presentation for testing.
- `project.yml` is the identity and build configuration source. The generated Xcode project and shared scheme are committed for Xcode Cloud; regenerate and verify together.
- Release uses PadPad and its standard icon. Debug uses PadPad Dev, a separate identity, preferences and shortcut, the DEV icon. Test hosts use disposable storage and disable global shortcuts.

## Build and verification

Requires Xcode 27, macOS 27, XcodeGen, Node.js and pnpm. See `DEVELOPMENT.md` and `RELEASING.md` for current commands.

- In `editor/`, run `pnpm install --frozen-lockfile`, `pnpm typecheck`, `pnpm test` and `pnpm build` on the isolated test machine. The app build bundles the editor offline.
- Generate with `xcodegen generate`; CI checks the generated project matches the source.
- Build/test through the shared Pad scheme. Run window tests only in an isolated GUI session with `PAD_WINDOW_TESTS` passed to the test host.
- Exercise changed behavior, especially focus, file dialogs, close/discard, naming collisions and external edits. Unit tests do not prove window behavior.
- Do not replace or quit a running development preview without checking whether it is in use. Never test against personal documents.
- Public PRs use hosted CI only; never attach personal persistent runners.

## Delivery

App Store/TestFlight distribution only. Start at 1.0.0; subsequent releases increment the patch version unless explicitly agreed otherwise. Use monotonic build numbers and version-matching tags. An upload is not completion: verify processing, internal tester availability and installation. Xcode Cloud workflow setup is separate from repository preparation.

## Shared editor integration

InkKit owns Markdown preservation, editable tables, clipboard conversion, and optional managed images. Keep native storage and document lifecycle in this app. Await a fresh, scoped snapshot before actions that depend on current text; script failures retain the document and clipboard. Consumer tests validate the package facade; engine regression tests belong in InkKit. See `editor/BRIDGE.md`.
