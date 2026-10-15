# FreeDisplay release checks

This is a verification checklist for the parent session's release process. Release scripts,
`project.yml`, signing identities, feed/key configuration, CI, artifact naming and the release itself
are owned by that session. This P1 implementation neither changes those files nor publishes,
signs, notarizes, installs or launches a release. Follow the parent's current
[release workflow](../scripts/sparkle-setup.md) and
[sign/notarize procedure](../scripts/release-signed.sh); documentation is not evidence they passed.

## Before packaging

- Record the exact committed revision and tree state. Run `swift test --scratch-path .build/spm`,
  `xcodegen generate --spec project.local.yml`, and Debug builds of OpenDisplay,
  OpenDisplay-PublicAPIOnly, opendisplay and OpenDisplayRescue with signing disabled, using a
  worktree-local derived-data directory. Keep logs, test count and exit status. These are compile
  and fake-test results, separate from signed Release/distribution acceptance.
- Check both API surfaces and localization: public-only refusals, recovery, exact identity/mode
  handling, new strings/format placeholders, English/Russian/VoiceOver, long text and About build
  information. Central translations must be merged before claiming Russian coverage.
- Verify user-facing FreeDisplay branding and upstream attribution. The built app is FreeDisplay.app;
  internal targets/modules, executable/CLI, URL scheme, bundle/storage domains retain compatibility
  names. Parent packaging determines the actual archive/container name; do not rename release
  artifacts merely to make a checklist agree. Verify archive contents against the declared product.
- On separate authorized test hardware exercise keep/revert (mode/main), recovery/Rescue by identity,
  quit/restart restoration, gamma/ICC safeguards, software controls, CoreAudio, shortcuts and conflicts,
  capture, settings backup/import, login/safe startup and sleep/wake. Record direct/dock/KVM and
  unrelated-display effects. A readback is not physical image/audio proof. Stream Deck, external
  recorders, TV pairing and installed Shortcuts discovery need separate integration checks.

## Distribution gate — parent session

1. Establish the expected **FreeDisplay-owned** Developer ID authority, Team ID, update signing key
   and trusted release origin before assessing the artifact. Do not copy upstream or BetterDisplay
   identities. No Developer ID/Team ID has been validated by this implementation round. An ad-hoc
   build is a source/development build, not a Developer ID authenticated distribution.
2. Build from the declared path/revision and sign nested code/all supported architectures and app.
   Verify signature integrity and independently compare authority/Team ID to the expected identity.
   A valid unexpected signer fails the gate. Preserve failures and stderr, not only a success banner.
3. Submit the intended distribution for notarization, inspect acceptance, staple the actual app
   (and container when applicable), then validate the staple. Assess normal Gatekeeper distribution
   on the final app/container independently. Wrong signer, signature, staple or Gatekeeper failure
   blocks a release-ready result. Record network/service failures as unverified assessment, rather
   than asserting tampering or bypassing checks.
4. Produce the **final download bytes after stapling and final repack**. Compute and publish the
   exact archive's SHA-256 (all 64 hex characters) through the trusted FreeDisplay release channel.
   Compare a freshly downloaded copy against that value. Any byte-changing repack requires a new
   checksum and revalidation. Matching a digest alone does not authenticate the publisher.
5. Test the distributed artifact in the intended quarantine/install context and with offline
   Gatekeeper using its stapled ticket. Check nested code, expected bundle/executable, version/build,
   minimum OS/architecture, permissions and settings migration. Test wrong signer and a modified
   bundle as rejected cases. Do not disable Gatekeeper or remove quarantine to force acceptance.
6. Validate FreeDisplay feed/key admission, upgrade from a supported older build, cancellation/failure,
   relaunch, and the parent's rollback process. Upstream feed/key refusal must remain; source builds
   must retain updater-disabled behavior. A prepared appcast is not an observed successful update.
7. Publish only after these gates pass, including expected identity, exact artifact checksum, source
   revision/license/attribution, release notes, known capability limitations and rollback instructions.
   Experimental builds require an explicit label and their own evidence; no extra channel is invented.

Recipient-side commands and interpretation are in [Verify a download](ReleaseVerification.md).
Before signing off, record each check as passed, failed or **not exercised**, with artifact hash,
commands/results and hardware/context. Unit tests, Debug build success, UI discovery, signed release,
offline installation and physical device behavior are different evidence. Unperformed release tests
remain the parent session's acceptance work and must not be inferred from this checklist.
