"""Offline fixtures only: no app, hardware, keychain, signing or notarization commands."""
import base64
import copy
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("appcast", ROOT / "scripts/validate-appcast.py")
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.archive = self.directory / "FreeDisplay.zip"
        self.feed = self.directory / "appcast.xml"
        self.key = base64.b64encode(bytes(range(32))).decode()
        self.info = {
            "SUPublicEDKey": self.key, "SUFeedURL": appcast.FEED,
            "CFBundleVersion": "25", "CFBundleShortVersionString": "0.12.0",
            "CFBundleIdentifier": "io.github.garshany.FreeDisplay", "LSMinimumSystemVersion": "14.0",
            "OpenDisplayLocalBuild": True,
        }
        self.write_archive()
        self.tree = ET.Element("rss")
        self.item = ET.SubElement(ET.SubElement(self.tree, "channel"), "item")
        for key, value in [("version", "25"), ("shortVersionString", "0.12.0"), ("minimumSystemVersion", "14.0")]:
            ET.SubElement(self.item, appcast.SPARKLE + key).text = value
        self.signature = base64.b64encode(bytes(range(64))).decode()
        self.enclosure = ET.SubElement(self.item, "enclosure", {
            "url": appcast.PROJECT + "/releases/download/v0.12.0/FreeDisplay.zip",
            "length": str(self.archive.stat().st_size), appcast.SPARKLE + "edSignature": self.signature,
        })

    def write_archive(self):
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("FreeDisplay.app/Contents/Info.plist", plistlib.dumps(self.info))

    def validate(self):
        ET.ElementTree(self.tree).write(self.feed)
        return appcast.validate_appcast(self.feed, self.archive, self.info, "v0.12.0")

    def test_valid_source_build_preparation_keeps_local_guard(self):
        self.assertEqual(appcast.validate_archive(self.archive, self.key), self.info)
        self.assertTrue(self.info["OpenDisplayLocalBuild"])
        self.assertEqual(self.validate(), self.signature)

    def test_archive_key_must_match_owner_account(self):
        with self.assertRaisesRegex(ValueError, "differs"):
            appcast.validate_archive(self.archive, base64.b64encode(bytes([7] * 32)).decode())

    def test_upstream_key_is_never_accepted(self):
        with self.assertRaisesRegex(ValueError, "owned"):
            appcast.validate_archive(self.archive, appcast.UPSTREAM_KEY)

    def test_upstream_feed_is_never_accepted(self):
        self.info["SUFeedURL"] = "https://github.com/aquitaine/OpenDisplay/releases/latest/download/appcast.xml"
        self.write_archive()
        with self.assertRaisesRegex(ValueError, "owned"):
            appcast.validate_archive(self.archive, self.key)

    def test_missing_compatibility_metadata_fails(self):
        del self.info["LSMinimumSystemVersion"]
        self.write_archive()
        with self.assertRaisesRegex(ValueError, "LSMinimumSystemVersion"):
            appcast.validate_archive(self.archive, self.key)

    def test_mutated_archive_bytes_fail_length_check(self):
        with self.archive.open("ab") as output:
            output.write(b"changed")
        with self.assertRaisesRegex(ValueError, "length"):
            self.validate()

    def test_malformed_signature_is_rejected(self):
        self.enclosure.set(appcast.SPARKLE + "edSignature", base64.b64encode(b"short").decode())
        with self.assertRaisesRegex(ValueError, "signature"):
            self.validate()

    def test_url_must_reference_exact_fork_asset(self):
        self.enclosure.set("url", "https://github.com/aquitaine/OpenDisplay/releases/download/v0.12.0/FreeDisplay.zip")
        with self.assertRaisesRegex(ValueError, "exact FreeDisplay"):
            self.validate()

    def test_build_and_marketing_version_are_checked_independently(self):
        self.item.find(appcast.SPARKLE + "shortVersionString").text = "0.11.0"
        with self.assertRaisesRegex(ValueError, "Marketing"):
            self.validate()
        self.item.find(appcast.SPARKLE + "shortVersionString").text = "0.12.0"
        self.item.find(appcast.SPARKLE + "version").text = "24"
        with self.assertRaisesRegex(ValueError, "unambiguous"):
            self.validate()

    def test_duplicate_build_offers_fail_closed(self):
        self.tree.find("channel").append(copy.deepcopy(self.item))
        with self.assertRaisesRegex(ValueError, "unambiguous"):
            self.validate()

    def test_os_requirement_cannot_drift_from_archive(self):
        self.item.find(appcast.SPARKLE + "minimumSystemVersion").text = "13.0"
        with self.assertRaisesRegex(ValueError, "macOS"):
            self.validate()

    def test_prerelease_feeds_require_separate_acceptance(self):
        for channel in ["test", "internal"]:
            with self.subTest(channel=channel):
                entry = ET.SubElement(self.item, appcast.SPARKLE + "channel")
                entry.text = channel
                with self.assertRaisesRegex(ValueError, "Prerelease"):
                    self.validate()
                self.item.remove(entry)


class BundleHelperTests(unittest.TestCase):
    def test_build_and_copy_use_only_the_passed_derived_data_with_spaces(self):
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory)
            tools = stage / "tools"
            tools.mkdir()
            log = stage / "invocations.txt"
            dd = stage / "explicit build products"
            (tools / "xcodegen").write_text("#!/bin/bash\nexit 0\n")
            (tools / "xcodebuild").write_text('''#!/bin/bash
printf '%s\\n' "$@" >> "$CALL_LOG"
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-derivedDataPath" ]; then dd="$2"; shift; fi
  shift
done
mkdir -p "$dd/Build/Products/Debug/FreeDisplay.app"
printf 'fake cli, never executed' > "$dd/Build/Products/Debug/opendisplay"
chmod +x "$dd/Build/Products/Debug/opendisplay"
''')
            for tool in tools.iterdir():
                tool.chmod(0o755)
            environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"], CALL_LOG=str(log))
            subprocess.run(["bash", "scripts/bundle-helper.sh", "Debug", str(dd), "CURRENT_PROJECT_VERSION=123", "CODE_SIGNING_ALLOWED=NO"],
                           cwd=ROOT, env=environment, check=True, capture_output=True)
            self.assertEqual(log.read_text().count(str(dd)), 2)
            self.assertEqual(log.read_text().count("CURRENT_PROJECT_VERSION=123"), 2)
            self.assertEqual(log.read_text().count("CODE_SIGNING_ALLOWED=NO"), 2)
            self.assertEqual((dd / "Build/Products/Debug/FreeDisplay.app/Contents/Helpers/opendisplay").read_text(),
                             "fake cli, never executed")


if __name__ == "__main__":
    unittest.main()
