#!/usr/bin/env python3
"""Offline release metadata checks; cryptographic verification is owned by Sparkle sign_update."""
import argparse
import base64
import plistlib
from pathlib import Path
from urllib.parse import quote
import xml.etree.ElementTree as ET
import zipfile

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
PROJECT = "https://github.com/garshany/FreeDisplay"
FEED = PROJECT + "/releases/latest/download/appcast.xml"
UPSTREAM_KEY = "G9aQchK8B0eqrXhKwKWat4SRCR/XboPdgpmfuHrBnuE="


def validate_archive(archive, public_key):
    if public_key == UPSTREAM_KEY or len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError("A FreeDisplay-owned Ed25519 public key is required")
    with zipfile.ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read("FreeDisplay.app/Contents/Info.plist"))
    if info.get("SUPublicEDKey") != public_key:
        raise ValueError("The archive public key differs from the signing account")
    if info.get("SUFeedURL") != FEED:
        raise ValueError("The archive must use the FreeDisplay-owned release feed")
    for field in ("CFBundleVersion", "CFBundleShortVersionString", "CFBundleIdentifier", "LSMinimumSystemVersion"):
        if not isinstance(info.get(field), str) or not info[field].strip():
            raise ValueError("Missing archive metadata: " + field)
    return info


def validate_appcast(appcast, archive, info, tag):
    tree = ET.parse(appcast)
    items = tree.findall("./channel/item")
    expected_url = PROJECT + "/releases/download/" + quote(tag, safe="") + "/" + quote(Path(archive).name)
    matching = [item for item in items if item.findtext(SPARKLE + "version") == info["CFBundleVersion"]]
    if len(matching) != 1:
        raise ValueError("The feed must contain one unambiguous item for this build")
    item = matching[0]
    if item.findtext(SPARKLE + "shortVersionString") != info["CFBundleShortVersionString"]:
        raise ValueError("Marketing version differs from the archive")
    if item.findtext(SPARKLE + "minimumSystemVersion") != info["LSMinimumSystemVersion"]:
        raise ValueError("Minimum macOS differs from the archive")
    enclosure = item.find("enclosure")
    if enclosure is None or enclosure.get("url") != expected_url:
        raise ValueError("Archive URL must point to the exact FreeDisplay release asset")
    if enclosure.get("length") != str(Path(archive).stat().st_size):
        raise ValueError("Archive length differs from signed feed metadata")
    signature = enclosure.get(SPARKLE + "edSignature", "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Missing or malformed Ed25519 archive signature")
    # This is a prepared stable feed. Prerelease policies belong to FD-150.
    if item.find(SPARKLE + "channel") is not None:
        raise ValueError("Prerelease channels require separate owner validation")
    return signature


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True)
    parser.add_argument("--public-key", required=True)
    parser.add_argument("--appcast")
    parser.add_argument("--tag")
    parser.add_argument("--print-signature", action="store_true")
    args = parser.parse_args()
    try:
        info = validate_archive(args.archive, args.public_key)
        if args.appcast:
            if not args.tag:
                raise ValueError("--tag is required with --appcast")
            signature = validate_appcast(args.appcast, args.archive, info, args.tag)
            if args.print_signature:
                print(signature)
        elif args.print_signature:
            raise ValueError("--print-signature requires --appcast")
    except (ValueError, OSError, KeyError, ET.ParseError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        parser.exit(1, "error: " + str(error) + "\n")


if __name__ == "__main__":
    main()
