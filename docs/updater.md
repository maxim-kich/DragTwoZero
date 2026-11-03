# In-app updates

Drag 2.0 uses Sparkle **2.10.1**, pinned in `Package.swift` and `Package.resolved`. Implementation follows Sparkle’s [setup](https://sparkle-project.org/documentation/), [custom user interface](https://sparkle-project.org/documentation/custom-user-interfaces/), [configuration](https://sparkle-project.org/documentation/customization/), and [user-driver API](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUserDriver.html) documentation.

## User flow and safety

In **Settings → About**, choose **Check for Updates → Download & Install → Restart**. The first confirmation authorizes downloading, signature verification, and preparing installation. The second authorizes final installation and restart. Closing either confirmation leaves the current app running. There is a Cancel button during checking, download, verification, and while waiting for restart. Verification/extraction cannot be interrupted inside Sparkle; cancellation waits for that step to finish, then cancels the staged installer.

**Notify about updates** retains the existing `checkForUpdates` preference (on by default). The existing hourly timer checks whether a day has elapsed since `lastUpdateCheck`; manual checks work with periodic checks disabled. Sparkle’s independent scheduling and automatic downloading/installing are disabled. A periodic check offers the update in About and can send the existing authorized macOS notification; it never downloads the app archive without confirmation. Cancelling an offer leaves future checks available. The existing last-notified-version preference prevents duplicate system notifications.

Restart is blocked while a capture/selection, native drag, delivery, validation, or pending clipboard verification is active, and while Buffer holds an item, including hidden recovery content. Use or explicitly clear Buffer before restarting. State is checked again after the confirmation dialog and at termination; new capture gestures are gated once restart is authorized. Ordinary Quit is blocked while an authorized update is staged until the user restarts or cancellation finishes. Sparkle’s `.skip` response cancels the staged installer; `.dismiss` is deliberately avoided because it can install on quit. Force Quit, crashes, and system shutdown remain outside the app’s normal termination guard.

After Restart confirmation, the updater captures activation intent once, pauses new input, and invalidates queued capture results before allowing Sparkle to install. It does not call Turn Off (which clears Buffer), change the saved capture preference, unregister a login item, or reset permissions. Delivery's main-thread completion acknowledgement must have settled, including clipboard restoration. An uncertain posted paste with an owned clipboard backup blocks restart until a newer copy releases that revision; the updater never forces restoration or discards the backup. Existing Buffer/gesture ownership must be resolved explicitly.

The replacement consumes a one-shot receipt scoped to the bundle ID, bundle path and target version, expiring after ten minutes. It restores only activation intent and the input-interruption pause, then opens the existing Settings controller on About. The normal Accessibility, event-tap and onboarding input gates still apply; a previous input interruption still requires explicit Resume. No Buffer content, capture, clipboard payload or pending completion is persisted or replayed. Mismatched/expired receipts are discarded. Cancellation and update failure clear the receipt and release the temporary pause; preparation/termination retries retain the original intent rather than sampling temporary stopped state.

The bundle identifier remains `com.maximkich.drop-to-t3`; existing preferences, app name, and permission keys are retained. `CFBundleVersion` now follows numeric `VERSION`, matching `CFBundleShortVersionString`, so Sparkle can compare successive versions. Releases must increase VERSION. Builds made before this updater used build number `1` and the browser flow; their first updater-enabled installation remains manual.

## Ordinary GitHub releases and signed feeds

The updater first queries `https://api.github.com/repos/maxim-kich/dragtwozero/releases/latest`. It rejects drafts, prereleases, nonnumeric tags, older/equal versions, unexpected repositories/URLs, missing assets, and empty/unuploaded assets. A newer release must contain both:

- `Drag-2.0-vVERSION-macOS-arm64.zip`
- `appcast.xml`

The feed is fetched from the **selected versioned release**, rather than following a changing latest URL during a check. Its selected item must match the API’s archive URL, byte length, numeric build/display versions, and application installation type. The feed has one full ZIP update; no deltas, phased rollouts, or installer packages are offered. Sparkle performs its normal macOS/hardware compatibility and installed-version checks, verifies Ed25519 signatures before extraction, validates the app’s signature/identity, and performs installation/relaunch. Validation failures do not fall back to opening an unsigned download or running an installer script.

`SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` are enabled. `SUSignedFeedFailureExpirationInterval=0` prevents fallback to unsigned metadata. `SUFeedURL` contains the ordinary-release discovery URL `https://github.com/maxim-kich/dragtwozero/releases/latest/download/appcast.xml`; the delegate pins each actual check to the API-selected release’s appcast. Do not edit a signed feed after generation.

Publish Alpha builds as **ordinary releases**, with the GitHub prerelease checkbox **off** and numeric tags such as `v0.0.2`. Attach the ZIP and signed appcast to the same release before publishing. A DMG may additionally be offered for manual installation. GitHub’s source archives are not update packages.

## Signing setup

The public Ed25519 key is in `config/sparkle-public-key.txt`. The matching private key was generated locally using Sparkle and is stored in the login Keychain under account **`com.maximkich.dragtwozero.updates`**. It is never embedded in the app or repository. Developer ID signing/notarization credentials remain separate; `drag2-notary` is the existing notarization profile.

To inspect the existing public key after resolving packages:

```sh
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.maximkich.dragtwozero.updates -p
```

For a new independent signing setup, Sparkle’s `generate_keys --account ACCOUNT` creates a key in Keychain or reuses an existing one. Put only its public key into the public-key file. Keep a secure backup/transfer of the private key outside the repository using Sparkle’s documented procedure. Losing this key is significant: strict ZIP verification prevents ordinary ZIP-based key rotation; read Sparkle’s [key rotation guidance](https://sparkle-project.org/documentation/#rotating-signing-keys) before changing it. Never rotate the embedded key accidentally between releases.

Build/package overrides are file/account references, not inline secrets:

- `DRAGTWOZERO_SPARKLE_ACCOUNT`: Keychain signing account (default above).
- `DRAGTWOZERO_UPDATE_PUBLIC_KEY_FILE`: public-key file (default `config/sparkle-public-key.txt`).
- Existing signing identity, notarization profile, app output, and scratch-path overrides still apply.

The package script verifies the Keychain public key matches the embedded key before submitting anything to Apple. It does not export the private key. CI builds and verifies bundles with the public key and needs no signing secrets for update generation.

## Build and release integration

```sh
swift test
./scripts/build-app.sh
./scripts/verify-build.sh
# Only when preparing a notarized release:
./scripts/package-release.sh
```

The build embeds Sparkle’s complete versioned framework, helper executables/apps, XPC services, and license notices, preserving symlinks and executable permissions. Helpers are signed inside-out with the selected app identity; release signing uses Hardened Runtime and a secure timestamp. Bundle checks verify nested signatures, updater settings, architecture, linking/runpath, and existing resources. No sandbox or permission entitlements are added to Drag 2.0.

After notarization/stapling, packaging creates the final ZIP, then `generate-update-feed.sh` uses Sparkle’s `generate_appcast` to sign the archive and appcast for its versioned GitHub URL. A fresh temporary staging directory ensures only the final ZIP enters the feed. Feed generation verifies the signed feed, refuses to overwrite an existing output, and produces `appcast.xml` beside the ZIP. `SHA256SUMS.txt` covers both. No script uploads, pushes, tags, publishes, or replaces the installed app. See [releases](releases.md) for the existing manual publication gate.

## Privacy

Only release metadata, the signed feed, and the user-approved archive are requested. GitHub and its download CDN receive normal connection information. No captured text, URLs, clipboard data, screenshots, usage analytics, system profile, extra feed parameters, or installation identifiers are sent. Both scheduled and manual checks use Sparkle’s manual API with the quiet custom driver: Sparkle’s background API otherwise creates a persistent phased-rollout identifier even for unphased feeds. Phased rollouts are rejected before downloading. The updater uses a fixed generic User-Agent, does not download release notes, and disables JavaScript and system profiling even if old Sparkle preferences exist. Check preference/time and notification/version state remain local; Sparkle keeps its normal local cache and installer state.

The bundled privacy notice and [hosted app privacy notice](https://dragtwozero.com/legal#app-privacy) describe this implementation. Keep both aligned when updater behavior changes.

## Isolated local validation

```sh
./scripts/test-updater-local.sh success
./scripts/test-updater-local.sh success-off
./scripts/test-updater-local.sh download-cancel
./scripts/test-updater-local.sh staged-cancel
./scripts/test-updater-local.sh bad-archive
./scripts/test-updater-local.sh bad-feed
./scripts/test-updater-local.sh incompatible
```

These scripts compile the production updater sources into a disposable native fixture under `.local/updater-MODE.XXXXXX/`. They use two versions, **9.0.1 → 9.0.2**, a unique fixture bundle ID/preferences domain, loopback HTTP with a fixture-only ATS exception, and a temporary Ed25519 key outside the repository that is deleted on exit. The production app has no local-feed override or ATS exception. A local Apple Development identity is required. Confirmation responses and transfer/Buffer states are scripted in the fixture; the real Sparkle framework verifies, replaces, and relaunches the fixture app. The installed Drag 2.0 app and its preferences are untouched.

Evidence includes lifecycle events, archive/feed, signing/build logs, and the old/replaced fixture bundle. Failure cases must retain 9.0.1; success must launch 9.0.2 with the existing test setting and disabled daily-check preference. Both success modes also wait for a fake asynchronous restoration acknowledgement, temporarily report OFF, and verify that the original ON/OFF intent and input pause survive replacement in a one-shot receipt. Unit tests separately cover release filtering, bounded metadata reads, consent, state races, cancellation, and the app’s restart activity mapping.

These local checks do **not** establish production GitHub/CDN delivery, Developer ID/notarized two-version replacement, fresh-machine permissions, administrator authorization prompts, behavior on macOS 13, actual cross-app transfers during an update, or human interaction with the final About UI. Those remain manual release gates.
