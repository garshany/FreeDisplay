# Releasing FreeDisplay

The public channel uses GitHub Releases with ad-hoc signatures. No Developer ID certificate,
notarization credentials, Sparkle signing key, or repository secret is required. The only publishing
credential is the workflow's short-lived `GITHUB_TOKEN` (`contents: write`). Sparkle's public key
stays empty: the app checks GitHub metadata and opens the release page; it never installs updates.

## Cut a release

1. Merge reviewed changes and update `MARKETING_VERSION` in tracked `project.yml` (initially `1.0.0`).
2. Commit the version change, then create `git tag v1.0.0` at that reviewed commit and run
   `git push origin v1.0.0` (substitute the new version for later releases).
3. The Release workflow checks out that tag, verifies its exact version, tests the core, and builds
   the app and CLI. Review the resulting GitHub Release, generated commit notes, zips and checksums.

These are owner/lead commands; implementation work does not create tags or releases. To rerun a
failed publication, use **Actions → Release → Run workflow** with an **existing** tag such as
`v1.0.0`. Dispatch checks out the tag, not the selected branch; it cannot create an unreviewed tag.
An existing release is not overwritten automatically: inspect it before retrying publication.

## Build and package locally without publishing

Use Apple Silicon, Xcode 26 (Swift 6.2 or later) and XcodeGen. CI explicitly selects Xcode 26.3 on
`macos-15-arm64`; its [runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md#xcode)
currently lists that toolchain. The package manifest needs Swift tools 6.0; this selection supplies Swift 6.2
and the macOS 26 SDK used for the app build. Runner images and Homebrew packages can change: if Xcode 26.3 disappears,
update both workflows to an available, validated Xcode 26 version. macOS 14 remains the app minimum.

```sh
brew install xcodegen
BUILD_NUMBER=1 RELEASE_TAG=v1.0.0 scripts/release-adhoc.sh ./.dd/release ./.dd/artifacts
```

The script always generates from tracked `project.yml`, never `project.local.yml`. It builds Release
for **arm64** without code signing, bundles the separately built `opendisplay` helper, then ad-hoc
signs nested code before the app and verifies the complete seal with `codesign --verify --deep
--strict`. Release metadata sets `OpenDisplayLocalBuild=false` and `SUPublicEDKey=""`. Source builds
retain the local-build flag. `CURRENT_PROJECT_VERSION` is passed to both app and CLI from
`github.run_number` in CI; locally `BUILD_NUMBER` is optional and defaults to the project value.
A rerun keeps that workflow run number; there is no build-number-based updater in this channel.

Artifacts:

- `FreeDisplay.zip`, containing `FreeDisplay.app` and its embedded frameworks/helper.
- `opendisplay.zip`, containing an `opendisplay/` directory with the CLI and required dynamic
  frameworks. Keep that directory intact; copying just the binary breaks its runtime linkage.
- `FreeDisplay.zip.sha256` and `opendisplay.zip.sha256`, computed from the final `ditto -c -k
  --keepParent` archives. Validate with `shasum -a 256 -c <archive>.sha256`.

No application, display provider, or CLI is executed by the release script. Builds, signing,
packaging and metadata inspection are sufficient for this dry run. Outputs under `.dd/` and `.spm/`
are local artifacts and must not be committed, nor should the generated Xcode project or personal
local spec be committed.

## CI and release checks

`ci.yml` runs on push and pull request: `swift build`, `swift test`, XcodeGen, all four Debug schemes
without signing, the synthetic local-control loopback integration, and offline Python tooling tests.
Both workflows cache SwiftPM output/dependencies under keys tied to the runner architecture,
selected Xcode, manifest and project spec. The release workflow builds the full app only, plus the
standalone CLI; PublicAPIOnly and Rescue remain CI build checks rather than separate downloads.

## Update and first-launch behavior

Automatic checks respect the existing **Check for updates automatically** setting. Checks happen at
launch and when this setting is enabled; **Check for Updates** always checks manually. There is no
new polling timer, interval, retry policy or automatic download. URLSession/URLCache use HTTP cache
headers and ETag revalidation for `https://api.github.com/repos/garshany/FreeDisplay/releases/latest`.
HTTP errors (including rate limiting, unavailable/private repositories and no published release),
malformed metadata and unparseable versions report failure/unknown, never “up to date.” Stable
release tags are compared semantically with `CFBundleShortVersionString`; prerelease responses and
foreign release links are rejected. No token is sent by the app. A private repository must become
public before unauthenticated update checks and public downloads can work.

Recipients download in their browser, quit FreeDisplay, and replace it manually. On first launch,
right-click the app and choose **Open**, because it is not notarized. Some macOS security settings
require approval in **System Settings → Privacy & Security** as well. SHA-256 detects corruption;
an ad-hoc signature does not identify a Developer ID publisher. After replacing the app, macOS may
ask for Accessibility permission again because the ad-hoc code identity changes.

The older Developer ID/notarization/appcast scripts are retained as optional tooling and are **not**
used by this release channel. Do not generate a Sparkle key or enable in-app installation as part of
cutting these releases. See [download verification](ReleaseVerification.md).
