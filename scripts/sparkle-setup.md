# FreeDisplay signed updates — preparation and owner release gates

FreeDisplay is a GPL-3.0 fork of aquitaine/OpenDisplay. The owned repository and release origin is
https://github.com/garshany/FreeDisplay. No FreeDisplay Developer ID, Team ID, Ed25519 private key or
validated public release is asserted by this document. All credential examples below are placeholders.

## Current state: source-only

`Apps/OpenDisplay/Resources/Info.plist` retains **`OpenDisplayLocalBuild = true`** for every build.
`SoftwareUpdater` refuses to start Sparkle in that state, even if a feed and public key are supplied.
Missing/invalid feed/key and known upstream feed/key values also keep it off. A missing local-build
flag is treated as local (fail closed). Nothing here enables automatic installation or publishes assets.
Bundle IDs, OpenDisplay.app, `opendisplay`, `opendisplay://` and persisted-settings paths stay compatible.

`project.yml` supplies these build settings (also overridable on `xcodebuild`):

| Setting | Prepared value |
|---|---|
| `FREEDISPLAY_UPDATE_FEED_URL` | `https://github.com/garshany/FreeDisplay/releases/latest/download/appcast.xml` |
| `FREEDISPLAY_UPDATE_PUBLIC_ED_KEY` | empty; owner must supply a new fork-owned base64 Ed25519 public key |
| `OpenDisplayLocalBuild` (Info.plist) | true; never overridden by release scripts |

Only a validated full-app release belongs in this feed. PublicAPIOnly/Rescue/CLI are build checks,
not automatically replaceable products. Never substitute the upstream key or feed.

## Owner-only key setup (not performed by the coding agent)

Use `generate_keys`, `generate_appcast`, and `sign_update` from the same resolved Sparkle distribution
as the embedded framework. Pass its bin directory explicitly as `SPARKLE_BIN`; never search for the
newest DerivedData. Select a dedicated `SPARKLE_KEYCHAIN_ACCOUNT` owned by FreeDisplay, separate from
upstream and other products. The account name, Developer ID authority/team, notarization profile and
backup/recovery custody are owner decisions. Keep private keys out of this repository and logs.

```sh
export SPARKLE_BIN=/absolute/path/to/resolved/Sparkle/bin
export SPARKLE_KEYCHAIN_ACCOUNT=YOUR_FREEDISPLAY_KEYCHAIN_ACCOUNT
"$SPARKLE_BIN/generate_keys" --account "$SPARKLE_KEYCHAIN_ACCOUNT"
"$SPARKLE_BIN/generate_keys" --account "$SPARKLE_KEYCHAIN_ACCOUNT" -p
# Put only the public output in FREEDISPLAY_UPDATE_PUBLIC_ED_KEY, via release configuration.
```

Do not run this example on a machine without an owner-approved key/account and backup process.
The private key must remain available for subsequent updates. Rotating/loss requires a separately
validated migration; merely replacing the embedded public key is not a recovery plan.

## Build, sign, notarize and prepare locally (owner only)

```sh
export SIGN_IDENTITY='Developer ID Application: YOUR_NAME (YOUR_TEAM_ID)'
export NOTARY_PROFILE=YOUR_NOTARIZATION_PROFILE
export DERIVED_DATA_PATH="$PWD/.build/release-dd"
export FREEDISPLAY_UPDATE_PUBLIC_ED_KEY=YOUR_FORK_PUBLIC_KEY
export SPARKLE_MAXIMUM_DELTAS=YOUR_OWNER_CHOSEN_DELTA_COUNT
# Optional: PROJECT_SPEC=project.local.yml for an explicitly prepared local dependency spec.
./scripts/release-signed.sh
```

`SPARKLE_MAXIMUM_DELTAS` is required when generating an appcast; this branch chooses no numeric
limit. Feed history is uncapped (`--maximum-versions 0`). The staging directory contains the current
archive only; retaining older releases/deltas requires the owner to supply a history workflow.
`NOTARIZE=0 APPCAST=0` is a signing-only development exercise; it cannot publish.

The helper and app share an explicit `-derivedDataPath`; `bundle-helper.sh CONFIG PATH` also accepts
an explicit second argument. Default is project-local `.build/release-dd`, never global newest output.
The release script signs nested helpers/frameworks/CLI and the app, verifies the expected authority
and team, notarizes, staples, assesses, then re-zips. It writes `dist/OpenDisplay.zip.sha256` next to
the **final** `dist/OpenDisplay.zip` and prints its full SHA-256. Stapling changes archive bytes, so
appcast signing follows final packaging. Stale appcast/checksum outputs are cleared before packaging.

`prepare-appcast.sh archive.zip tag output/appcast.xml [notes.md]` is independently usable after the
owner has produced a validated final archive. It requires explicit tools, keychain account and delta
policy. It checks the archive's embedded public key and fork feed before generation, runs Sparkle's
EdDSA appcast generation, validates release URL, build/marketing version, minimum macOS, byte length
and signature shape, then calls Sparkle `sign_update --verify` against the exact archive. Python 3 (standard library only) is required. The Python
metadata validator does **not** perform cryptographic verification itself. The output is stable-only;
prerelease/internal/critical/informational feed policy is FD-150 and requires separate acceptance.

Release notes default to the current CHANGELOG version section in `release-signed.sh`;
`RELEASE_NOTES` can supply an owner-reviewed Markdown file. For standalone preparation, pass a Markdown file (named with the archive stem in
staging). No default rollout interval, expiry threshold or compatibility ceiling is introduced.
Minimum macOS comes from the archived app; CPU support must be independently checked using `lipo`
and tested with the intended release artifacts. Keep architecture/maximum-OS bounds explicit in any
future owner-approved feed; do not publish a broader compatibility claim than was tested.

## Validation required before changing the local-build guard

Use disposable test installations and a private owner-controlled feed. Validate old→new upgrade,
monotonic `CFBundleVersion`, supported/unsupported CPU and OS, altered archive/signature refusal,
wrong key and wrong signer, offline/network failure, notes failure, cancellation, authorization denial,
skip and manual recheck, prepared/install-on-quit, relaunch and quit cleanup. Check settings migration
and rollback/recovery from failed installation. A download or generated XML is not an installed update.
Keep a known-good installer and settings backup. The first enabled fork release must be installed
manually; current source-only builds do not self-update to it.

Only after that evidence and an owner decision should a dedicated release change set the guard false.
Never do it for source/debug builds. The gate is not changed by this branch's scripts.

## Publication (not performed here)

Review and publish archive, checksum, optional notes and appcast together to an existing release in
`garshany/FreeDisplay`. `PUBLISH=1` is an explicit opt-in in the existing release script; it requires
notarization and targets that exact repository. GitHub `latest` must resolve to a release carrying
`appcast.xml`; a release without it breaks the feed. Publish full expected Developer ID authority and
Team ID alongside each release, and verify downloaded assets again. A checksum beside an archive
alone cannot establish authenticity if both came from an untrusted origin.

User verification instructions: [Docs/ReleaseVerification.md](../Docs/ReleaseVerification.md).
Sparkle primary references: [setup](https://sparkle-project.org/documentation/),
[publishing and EdDSA](https://sparkle-project.org/documentation/publishing/), and the resolved
`SPUUserDriver.h`, `SPUUpdaterDelegate.h`, `SUErrors.h` for the version actually embedded.
