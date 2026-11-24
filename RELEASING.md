# Releasing

PadPad starts at 1.0.0. Subsequent public releases increment the patch version unless a format or installation change has been agreed. TestFlight candidates for the same planned public release keep the same version and receive a new build number. `project.yml` owns product identity, icons, version, and build configuration. Regenerate and commit the Xcode project, shared scheme, generated plist, and entitlements whenever it changes.

## Versions, candidates, and publication

- **Version:** the planned App Store release, such as `1.1.8`. Keep it unchanged while testing candidates. It is normal for the App Store to remain on an earlier version, and not every TestFlight version needs to reach the App Store. Do not renumber or reuse an already published version to fill gaps.
- **Build:** Xcode Cloud assigns a strictly increasing number to every run. For example, `1.1.8 (24)`, `1.1.8 (25)`, and `1.1.8 (26)` are different candidates for one release. Failed runs may leave gaps. Never reset the Cloud counter or infer the next number from a Git tag.
- **Candidate tag:** use immutable `vMAJOR.MINOR.PATCH-beta.N` tags, starting at `1` and increasing for each candidate of that version. The suffix identifies the source candidate, not the Cloud build number, and does not enter the app's version string. Legacy `vMAJOR.MINOR.PATCH` tags remain supported. Never move an existing tag to a new commit.
- **Acceptance:** confirm the Cloud commit and build number, processing, internal group assignment, and TestFlight installation. The owner tests the candidate before authorizing App Store submission. Submit that exact accepted build; do not rebuild it merely to publish it. Apple describes this in [Distributing your app for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases).
- **GitHub Releases:** create a prerelease on the candidate tag with its version, actual build number, and testing notes. When that exact build is publicly available on the App Store, promote its GitHub release to a stable release titled `PadPad MAJOR.MINOR.PATCH` and mark it Latest. Keep its tag unchanged, including any beta suffix. Older candidates remain prereleases. Do not create a new distribution tag just to update GitHub metadata.

The Xcode Cloud workflow already matches tags beginning with `v`, so candidate tags use the same archive and internal-testing workflow. Validate each tag before pushing it. Source changes require a reviewed, green pull request; a GitHub prerelease is not evidence of TestFlight availability or public App Store publication.

Xcode may rewrite shared schemes when opening the project. Keep the committed XcodeGen output as the source of truth. The ignored `Pad.xcodeproj/xcshareddata/xcodecloud/` directory contains local Cloud association identifiers; it is not unfinished app code or the server-side workflow configuration.

## Verification

Use a dedicated development Mac running macOS 27 and Xcode 27 for builds and interactive checks. Never replace or quit an installed app to test a development build. `scripts/build_and_run.sh` builds the isolated Debug product and refuses to replace it while running; `--build-only` skips opening it.

Pull requests use GitHub-hosted `xcode-27` runners, never persistent personal runners. GitHub's [image announcement](https://github.com/actions/runner-images/issues/14404) confirms its macOS 27 base. CI checks generated-project consistency, Debug tests, and a Release build. Window suites use `PAD_WINDOW_TESTS=1`; with xcodebuild, pass `TEST_RUNNER_PAD_WINDOW_TESTS=1`. Leave it unset on an occupied desktop. CI runs the `Native` test plan with the window suites enabled; [DEVELOPMENT.md](DEVELOPMENT.md) lists the plans.

The shared `Pad UI Tests` scheme exercises real keyboard and window interactions in an isolated desktop session. It uses launch-argument preferences to discard disposable scratch text, and keeps screenshots only from failing tests. Run it separately from all other GUI tests; it requires macOS UI testing permission. An in-process panel test does not establish that macOS accepted a foreground activation request.

## Signing

`scripts/render-local-signing.sh` writes the ignored `Config/Local.xcconfig` from variables that your credential manager supplies. Never edit or commit that file. Rerun the script, then `xcodegen generate`, whenever the signing setup changes.

| Variable | Use |
| --- | --- |
| `APPLE_DEVELOPMENT_TEAM` | Required. The signing team. |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY` | The App Store Connect team API key, for provisioning and upload. Use the existing key; don't create another. |
| `PAD_SIGNING_KEYCHAIN`, `PAD_KEYCHAIN_PASSWORD` | Optional. A dedicated keychain for signing over SSH. |
| `APPLE_PROVISIONING_PROFILE`, `APPLE_DISTRIBUTION_IDENTITY`, `APPLE_INSTALLER_IDENTITY` | Archives only. The installed App Store profile, and certificate names if they differ from Apple Distribution and 3rd Party Mac Developer Installer. |

- **On a Mac that you're signed in to,** builds sign from the login keychain. Pass the API key to `xcodebuild` with `-allowProvisioningUpdates`, `-authenticationKeyPath`, `-authenticationKeyID`, and `-authenticationKeyIssuerID`, so that Xcode creates or renews the certificate there.
- **Over SSH,** the login keychain is locked, so name a dedicated keychain. The script unlocks the keychain and selects it with `OTHER_CODE_SIGN_FLAGS`. The keychain locks again in each new session, so build in the same credential-manager session. Keep the keychain in the user keychain search list, so that export finds its certificates. If the named keychain doesn't exist on the Mac, builds use the login keychain.

## First internal TestFlight build

1. Set the version and initial build number in `project.yml`, regenerate, and merge a reviewed pull request after CI passes. On the dedicated Mac, verify files, keyboard shortcuts, focus restoration, settings, sharing, external edits, and development and release isolation.
2. Register the distribution bundle identifier from `project.yml` in the developer account. Create the macOS app record in App Store Connect with the same identifier, name, primary language, and a stable SKU. Complete the compliance and beta metadata, and create an internal testing group.
3. Archive with an unused build number:

   ```sh
   scripts/archive-testflight.sh BUILD_NUMBER
   ```

   The script renders distribution signing, archives, and exports a package to `build/TestFlight-BUILD_NUMBER/Export`. It refuses an existing output directory, checks that every file in the app is readable by all users, and keeps logs and signing options private. It never uploads. Afterward, rerun `scripts/render-local-signing.sh` without `--distribution` to return to development signing.
4. Upload the package, as described in the next section.
5. Wait for App Store Connect to process the build, answer any compliance questions, and add the build to the internal group. Install it with TestFlight on the dedicated Mac, repeat the smoke check, and record the build, group, and installation privately.

An uploaded build isn't done until the internal tester can install it. App Store publication and external beta review are separate steps.

## Upload with the API key

Upload only after the final commit, verification, and archive, because this command uploads immediately:

```sh
python3 scripts/upload-testflight.py build/TestFlight-BUILD_NUMBER/Export/PadPad.pkg --wait
```

Use the exported package's actual filename. The script uses the `altool` that comes with Xcode, writes the key to a private temporary file that it removes, never prints the key or token, and strips `PAD_`, `ASC_`, `APPLE_`, and `INFISICAL_` variables from the uploader's environment. If the command fails or disconnects, check App Store Connect and the delivery log before you retry: an unclear response doesn't mean that the upload failed.

After processing, confirm the app, version, build number, internal group, invitation, and TestFlight installation. Keep the key's source and account identifiers in private notes, not in this repository.

## Xcode Cloud owner checklist

1. Open the committed project in Xcode 27 on the dedicated Mac. In the Report navigator choose **Cloud → Get Started**. Select the distribution PadPad product and the shared **Pad** scheme, then grant Xcode Cloud access to this GitHub repository and connect the existing App Store Connect record. Initial enablement must happen in Xcode; subsequent workflow edits can use App Store Connect. Start with a Release build-only onboarding run so it cannot upload a duplicate build number. [Apple onboarding guide](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow)
2. In App Store Connect, open PadPad → **TestFlight**, create an internal testing group if it does not yet exist, and add the intended internal tester. A group must exist before it can be selected as a Cloud distribution post-action. Do not assume repository or app creation also created this group. [Apple TestFlight workflow guide](https://developer.apple.com/documentation/xcode/distributing-your-xcode-cloud-builds-through-testflight)
3. Open PadPad → **Xcode Cloud → Settings → Build Number → Edit** beside **Next Build Number**. Set it above the highest manually uploaded or already allocated release build. For example, if build 2 is the highest manual build, use 3 or higher. Do this before the first distribution run; the number must keep increasing across macOS app versions. [Apple build-number guide](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds)
4. Edit the release workflow in **Xcode Cloud → Manage Workflows**. Set its environment to **Latest Release** for both Xcode and macOS; a pinned version stops working when Apple retires its image. If a run fails within seconds and shows no actions, the run page in App Store Connect names the cause, which the API doesn't report. Replace the default branch-change start condition with **Tag Changes**, matching tags that **begin with `v`**; use `v*` only if the interface asks for a glob pattern. Remove branch, pull-request, and scheduled triggers from this distribution workflow. In Environment Variables, set `APPLE_DEVELOPMENT_TEAM` to the signing team identifier from your existing signing configuration. Keep the value in the workflow, not in the repository. The repository hook accepts `vMAJOR.MINOR.PATCH` and `vMAJOR.MINOR.PATCH-beta.N` (positive `N`), and rejects tags whose version does not match the project. [Apple workflow reference](https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference)
5. Add a **macOS Archive** action using the shared **Pad** scheme and its **Release** archive configuration. Choose **TestFlight and App Store** distribution, retaining eligibility for later App Store review without submitting it. Add an **Internal TestFlight Testing** post-action and select the group from step 2. Do not select an external-testing group or configure an App Store submission. [Apple distribution workflow guide](https://developer.apple.com/documentation/xcode/creating-a-workflow-that-builds-your-app-for-distribution)
6. Save the workflow. On a reviewed, green commit, validate the release tag with `scripts/validate-release.sh vX.Y.Z`, then push that tag. Confirm the Cloud archive succeeds, App Store Connect finishes processing, the internal group receives the build, and TestFlight installation works. Record the build number and installation evidence privately. A pushed tag or uploaded archive is not a delivered build.

`ci_scripts/ci_post_clone.sh` uses Cloud's `CI_BUILD_NUMBER` with `agvtool`. Its ignored `Config/Cloud.xcconfig` explicitly enables automatic signing, sets the team from the workflow's `APPLE_DEVELOPMENT_TEAM`, and clears the app-only manual provisioning profile. The app's Release `CODE_SIGN_STYLE` references `PAD_DISTRIBUTION_SIGNING_STYLE`, which the hook also sets to Automatic. No private local keychain, certificate export, provisioning profile, or credential-manager environment is needed in Cloud. Apple documents predefined and custom workflow variables in its [environment reference](https://developer.apple.com/documentation/xcode/environment-variable-reference).

The committed project and shared scheme require no XcodeGen installation in Cloud. Source configuration is prepared; only a successful Cloud archive and distribution run verifies that the account and workflow signing work end to end.

For later public releases, update the patch version, regenerate and commit the project, and merge a green PR. For each TestFlight candidate, keep that planned version, merge any fixes through a green PR, and push a new matching candidate tag. Cloud owns the distribution counter after handoff; never reset it or reuse a manual build number.

Do not configure Sparkle, notarized direct downloads, a CLI, or a second update pipeline for the initial release.
