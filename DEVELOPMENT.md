# Development

PadPad is a native SwiftUI/AppKit app with an offline Markdown editor. Read [AGENTS.md](AGENTS.md) for architecture and contribution conventions, and [RELEASING.md](RELEASING.md) for distribution.

## Requirements

- macOS 27 and Xcode 27
- XcodeGen
- Node.js and pnpm

## Build

The committed Xcode project is generated from `project.yml`. After changing project configuration, regenerate it with:

```sh
xcodegen generate
```

Open `Pad.xcodeproj` and select the shared **Pad** scheme. Debug builds use **PadPad Dev**, with separate preferences and identity. The app build installs and bundles the Markdown editor through its build script.

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

Use the shared Pad scheme for native build and tests. Window tests require an isolated GUI session and `PAD_WINDOW_TESTS` in the test host environment. UI tests launch the app with macOS inline predictions off (`UITests/UITestLaunch.swift`), because the prediction panel consumes synthesized key events and can duplicate a typed character. Use disposable files, never personal documents. Required CI must pass before merging a pull request; native interaction checks are also needed for changes to focus, save, rename, close, or window behavior.

Public pull requests use hosted CI. Do not attach personal persistent runners.
