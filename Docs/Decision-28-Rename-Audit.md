# Decision 28: FreeDisplay UI name

Implemented on `freedisplay/codex-rename`. The app products are `FreeDisplay.app`,
`FreeDisplay-PublicAPIOnly.app` and `FreeDisplayRescue.app`. Their Swift module names remain
`OpenDisplay`, `OpenDisplay_PublicAPIOnly` and `OpenDisplayRescue`, respectively. Both project
specifications were updated; `project.local.yml` and the generated project are deliberately
excluded from the commit. The lead must retain the same three PRODUCT_NAME/PRODUCT_MODULE_NAME
pairs in their local specification when regenerating the project.

The Info.plists explicitly use `$(EXECUTABLE_NAME)` for CFBundleExecutable so each renamed bundle
identifies its actual executable. Bundle identifiers, persistent storage, preferences,
notification names, log subsystems, schemes, Swift types and the CLI are unchanged. Rescue now
emits localization data too, allowing the extraction audit to cover all three app targets.

English literals, matching catalog keys and Russian values were renamed together. AppShortcuts
contains no hard-coded product name: its existing `${applicationName}` placeholders resolve to
the new CFBundleDisplayName, so that catalog requires no edits. The separate translation handoff
is `/tmp/od-l10n-impl/codex-rename.json` (128 entries, Swift interpolation syntax).

## Remaining OpenDisplay in user-facing strings

The compiler audit scans `.dd/Build/Intermediates.noindex/**/Objects-normal/arm64/*.stringsdata`
and all three source catalogs, and reads both source Info.plists. It examined 2810 extracted
entries. Exactly two distinct extracted strings retain OpenDisplay; each occurs once in each of
the full and public app's extraction data:

| String | Source and catalog | Reason retained |
|---|---|---|
| `© 2026 OpenDisplay contributors` / `© 2026 участники проекта OpenDisplay` | `AboutView.swift`; `Localizable.xcstrings` | Upstream copyright/credit, explicitly preserved. |
| `OpenDisplay Settings %@.json` / `Настройки OpenDisplay %@.json` | `ApplicationSettingsViews.swift`, export panel; `Localizable.xcstrings` | Existing on-disk export filename. The prohibition on changing any disk paths is interpreted conservatively, including suggested export filenames. |

Additional user-facing names/URLs outside compiler-extracted localized strings:

| Remaining occurrence | Source | Reason retained |
|---|---|---|
| `OpenDisplay-diagnostics-\(formatter.string(from: now)).zip` | `Providers/CoreGraphicsProvider/Sources/CoreGraphicsProvider/DiagnosticsBundle.swift` | Existing on-disk diagnostics export filename, also shared with the CLI. The description and README heading inside the archive use FreeDisplay. |
| `https://github.com/aquitaine/OpenDisplay` and its `/releases`, `/issues/new`, `/blob/main/LICENSE` links | `AboutView.swift`, About and Settings links | Upstream project, release history, issues and license destinations. |
| `https://github.com/aquitaine/OpenDisplay/blob/main/Docs/Recovering-a-stranded-display.md` | `ReconnectVerification.swift`, recovery link | Upstream recovery documentation destination. |
| `https://github.com/aquitaine/OpenDisplay/issues` | Diagnostics bundle README | Upstream issues URL, preserved as instructed. |
| `https://github.com/aquitaine/OpenDisplay/releases/latest/download/appcast.xml` | Main app Info.plist, `SUFeedURL` | Upstream update feed. `OpenDisplayLocalBuild` remains true, so fork builds continue to disable upstream updates. |
| `opendisplay — OpenDisplay automation CLI` | CLI help, `main.swift:42`; reproduced in both root READMEs | CLI output must remain unchanged. |
| `# reconnect every display OpenDisplay turned off` | CLI help, `main.swift:55`; reproduced in both root READMEs | CLI output must remain unchanged. |
| `OpenDisplay → Arrange for it to be restored automatically` | CLI message, `main.swift:1448` | CLI output must remain unchanged. |
| `note: brightness events need "Broadcast OSD events" on in OpenDisplay settings` | CLI stderr, `main.swift:1723` | CLI output must remain unchanged. |
| Application Support directory component `OpenDisplay` | Shared settings/registry/checkpoint/audit/scenes/offline stores | Existing persistent paths; Finder may show these paths. No data migration was introduced. |

The requested source Info.plist/catalog grep additionally finds the XML comment identifying the
upstream `aquitaine/OpenDisplay` feed and the custom key `OpenDisplayLocalBuild`; neither is UI
text. `InfoPlist.xcstrings`, `AppShortcuts.xcstrings` and the Rescue Info.plist have no remaining
OpenDisplay occurrences. Effective locally built Info.plists retain `local.personal.OpenDisplay`
and `local.personal.OpenDisplay.publicapionly` bundle identifiers. These are compatibility
identifiers, not display names. The rescue identifier remains `dev.opendisplay.rescue`.

Both root READMEs retain upstream/history/license mentions, CLI transcripts and unchanged
scheme/module/source-path names. Older guide/history documents were not rewritten.

## Validation

- `xcodegen generate --spec project.local.yml`: passed after adding the verification files.
- All four required Debug builds with `-derivedDataPath ./.dd CODE_SIGNING_ALLOWED=NO`: passed
  (`OpenDisplay`, `OpenDisplay-PublicAPIOnly`, `opendisplay`, `OpenDisplayRescue`).
- `swift test --scratch-path ./.spm`: **1286 tests, 0 failures**. Four new tests cover the quit
  label and stable serialization key, failure notification and unchanged recovery URL, default
  power assertion name (fake backend), and report text/localization lookup. All four failed
  before the source fixes (five assertions failed), then passed in the full suite.
- `Tests/Integration/BrandingReadOnly.swift`: passed against built frameworks. It reads all three
  bundle manifests and both Russian resource tables, checks diagnostics descriptions and their
  Russian lookup, and checks that diagnostics filenames and the support directory are retained.
- `python3 Tests/Integration/check-branding.py`: passed; all three app targets were present,
  renamed extracted keys have Russian entries, and every remaining old-name entry is allowlisted.
- `bash -n scripts/bundle-helper.sh scripts/release-signed.sh` and `git diff --check`: passed.
- Self-review confirmed Swift production changes are name substitutions only; CLI sources are
  untouched; existing catalog entries and translations were preserved consistently.

To rerun the read-only framework/resource test after building all schemes:

```sh
swiftc Tests/Integration/BrandingReadOnly.swift -F .dd/Build/Products/Debug \
  -framework CoreGraphicsProvider -framework TopologyCore \
  -Xlinker -rpath -Xlinker "$PWD/.dd/Build/Products/Debug" \
  -o /tmp/od-rename-branding-read-only
/tmp/od-rename-branding-read-only .dd/Build/Products/Debug
python3 Tests/Integration/check-branding.py
```

No app, CLI, rescue executable or display-control operation was run. Signing, launching,
visual UI acceptance and real display behavior are outside this build/read-only verification.
`.dd/` and `.spm/` are local untracked build directories and are not committed or added to ignore files.
