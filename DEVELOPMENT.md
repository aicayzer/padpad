# Development

PadPad is a native SwiftUI/AppKit app with an offline InkKit editor for Markdown and RTF. RTF files convert through the `InkKitRTF` Swift package from the InkKit repository, at the same version as the bundled `@aicayzer/inkkit` package. Read [AGENTS.md](AGENTS.md) for architecture and contribution conventions, and [RELEASING.md](RELEASING.md) for distribution.

## Requirements

- macOS 27 and Xcode 27
- XcodeGen
- Node.js and pnpm

## Build

The committed Xcode project is generated from `project.yml`. After changing project configuration, regenerate it with:

```sh
xcodegen generate
```

Open `Pad.xcodeproj` and select the shared **Pad** scheme. Debug builds use **PadPad Dev**, with separate preferences and identity. The app build installs and bundles the editor through its build script.

Signing configuration is local and ignored, so a fresh clone or isolated source copy does not include it. Before running the app or native tests, use the repository's credential-manager mapping to run `scripts/render-local-signing.sh`. Use the existing Apple Development identity, rather than ad-hoc signing, for interactive development checks; changing an untrusted build can trigger another macOS approval prompt.

When the development identity lives in a dedicated signing keychain, unlock that existing keychain within the build/test session through the mapped credentials and explicitly select it with `OTHER_CODE_SIGN_FLAGS`. Follow the private keychain handling in `scripts/archive-testflight.sh`; never print the injected password or change the machine's security policy to make a test launch work.

Do not commit credentials, signing identities, or personal paths.

## Verification

Run editor checks in `editor/`:

```sh
pnpm install --frozen-lockfile
pnpm typecheck
pnpm test
pnpm build
```

Build and test natively through the shared schemes. Each scheme carries test plans in `TestPlans/`, generated into the project from `project.yml`, with a per-test time allowance so a hung test fails instead of stalling a run.

| Scheme | Plan | Covers |
| --- | --- | --- |
| Pad | Native | Unit suites, plus the suites that open windows when `PAD_WINDOW_TESTS=1` |
| Pad UI Tests | UIEditor | Editing, formatting, clipboard, tables, find and RTF files (`MarkdownUITests`) |
| Pad UI Tests | UIShell | Quick pad lifecycle, rename, save, Dock and menu bar access (`PadUITests`) |
| Pad UI Tests | UISettings | Onboarding, Settings, toolbar, the global shortcut over Finder and the test identity |

```sh
xcodebuild -project Pad.xcodeproj -scheme Pad -testPlan Native -destination 'platform=macOS' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

### Window and UI tests

Window tests and UI tests take over the keyboard, mouse and windows of the session they run in, so run them only in an isolated GUI session on a machine you are not using. Each refuses to run unless the session declares itself isolated:

- `TEST_RUNNER_PAD_WINDOW_TESTS=1` enables the unit suites that open windows. Without it they report as skipped.
- `TEST_RUNNER_PAD_UI_TESTS=1` is required by every UI test. Without it they fail at once with an explanation.

```sh
TEST_RUNNER_PAD_UI_TESTS=1 xcodebuild -project Pad.xcodeproj -scheme 'Pad UI Tests' -testPlan UIEditor \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

UI tests launch the Debug build, `PadPad Dev` (`me.cyzr.pad.dev`), with its own preferences, shortcut and icon, and a test confirms this identity. UI tests launch the app with macOS inline predictions off (`UITests/UITestSupport.swift`), because the prediction panel consumes synthesized key events and can duplicate a typed character. Use disposable files, never personal documents.

XCTest waits about ten seconds for an application it did not launch, such as Finder, each time a test sends it a key that the application does not receive; the first event after a SwiftUI menu opens costs about the same. A global shortcut is consumed by the hotkey system, and a plain key goes to the quick pad's key panel while it is visible, so neither reaches Finder and XCTest waits for Finder to idle. No setting removes the wait. Each global-shortcut press therefore costs about ten seconds: keep one only where the test must prove the shortcut, merge show and hide cycles, open drafts with `app.typeKey("n", modifierFlags: .command)` and send plain keys to the app, not to Finder. Press shortcuts through `FinderKeyboard` only in tests that need Finder in front. Posting `CGEvent` keys would avoid the wait, but needs Accessibility access that the test runner lacks.

`GlobalShortcutUITests` opens a Finder window titled `pad-shortcut-cover-<id>` to cover the quick pad. It closes any such window by title before and after each test, so a leftover cannot cover the pad in later tests.

Screenshots attach with `deleteOnSuccess`, so a passing run keeps no images.

### Continuous integration

Workflow `CI` runs on pull requests, not on pushes to `main`. A superseded run is cancelled, and a draft pull request runs the fast lanes only. The required check is **CI result**, which passes when every lane passed or was skipped by scope.

| Lane | Runs when | What it does |
| --- | --- | --- |
| Changes | Always | `scripts/ci-scope.mjs` lists the changed paths and picks the lanes below. Prose, `Design/`, `marfa/` and repository metadata run none. |
| Editor | `editor/` changed | Typecheck, test and build the editor on Linux. |
| App | Anything that can change the app | Release tag rules, generated-project check, the Native plan with window suites, and a Release build. |
| ui (UIEditor), ui (UIShell), ui (UISettings) | Anything that can change what the UI tests drive, and the pull request is not a draft | One job per plan, in parallel. |

A failing lane uploads its logs and `.xcresult` bundles for seven days. Passing runs upload nothing.

Public pull requests use hosted CI. Do not attach personal persistent runners. Required CI must pass before merging; native interaction checks are also needed for changes to focus, save, rename, close, or window behavior.

### CI runtime

Before the lane split (30 October 2026), one `App` job ran everything:

| | Before |
| --- | --- |
| Per pull request | About 37 min |
| After merge | The same job again on `main`, about 35 min |
| UI tests | 27 min for about 40 tests and 48 app launches |
| Unit tests | 183 cases in 3 s |

After the lane split:

| | After |
| --- | --- |
| Per pull request | About 12 min wall time: App about 3 min, and the three UI shards about 11 to 12 min in parallel |
| Documentation-only pull request | No build runs |
| After merge | No second run on `main` |
