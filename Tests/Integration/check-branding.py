#!/usr/bin/env python3
"""Read-only audit of compiler-extracted UI strings and the source string catalogs.

Run after building all four schemes: python3 Tests/Integration/check-branding.py
The allowlist preserves disk paths and upstream credit as required by decision 28.
"""
import json
from pathlib import Path
import plistlib
import sys

root = Path(__file__).resolve().parents[2]
derived = Path(sys.argv[1]) if len(sys.argv) > 1 else root / ".dd"
allowed = {
    "© 2026 OpenDisplay contributors": "upstream copyright notice",
    "OpenDisplay Settings %@.json": "existing exported-settings file name; disk paths are preserved",
}
resources = root / "Apps/OpenDisplay/Resources"
localizable = json.loads((resources / "Localizable.xcstrings").read_text())["strings"]
remaining = set()
seen_targets = set()
count = 0
for path in sorted((derived / "Build/Intermediates.noindex").glob("**/Objects-normal/arm64/*.stringsdata")):
    data = json.loads(path.read_text())
    target = path.parents[2].stem
    if target in {"OpenDisplay", "OpenDisplay-PublicAPIOnly", "OpenDisplayRescue"}:
        seen_targets.add(target)
    for table, entries in data.get("tables", {}).items():
        for entry in entries:
            key = entry["key"]
            count += 1
            if "OpenDisplay" in key:
                assert key in allowed, (str(path), key)
                remaining.add((key, allowed[key]))
            if "FreeDisplay" in key and table == "Localizable" and target in {"OpenDisplay", "OpenDisplay-PublicAPIOnly"}:
                assert key in localizable, ("Source/catalog key mismatch", str(path), key)
                assert localizable[key]["localizations"]["ru"]["stringUnit"]["value"], key
assert seen_targets == {"OpenDisplay", "OpenDisplay-PublicAPIOnly", "OpenDisplayRescue"}, seen_targets
for path in sorted(resources.glob("*.xcstrings")):
    strings = json.loads(path.read_text())["strings"]
    for key, entry in strings.items():
        if "OpenDisplay" in key:
            assert key in allowed, (str(path), key)
        for language, localization in entry.get("localizations", {}).items():
            value = localization.get("stringUnit", {}).get("value", "")
            if "OpenDisplay" in value:
                assert key in allowed, (str(path), key, language, value)
            if "FreeDisplay" in key:
                assert "OpenDisplay" not in value, (str(path), key, language)
for relative in ("Apps/OpenDisplay/Resources/Info.plist", "Apps/OpenDisplayRescue/Resources/Info.plist"):
    info = plistlib.loads((root / relative).read_bytes())
    for key, value in info.items():
        if isinstance(value, str) and "OpenDisplay" in value:
            assert key == "SUFeedURL" and value == "https://github.com/aquitaine/OpenDisplay/releases/latest/download/appcast.xml", (relative, key, value)
            remaining.add((value, "unchanged upstream update feed; local-build update guard remains enabled"))
print(f"Audited {count} compiler-extracted strings from all three app targets and all three catalogs.")
for key, reason in sorted(remaining):
    print(f"{key}\n  {reason}")
print("Branding extraction audit passed")
