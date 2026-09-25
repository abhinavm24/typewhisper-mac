#!/usr/bin/env python3
"""Generate a personal Sparkle feed from an already-signed release archive."""
import argparse
import base64
import json
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET

REPO = "abhinavm24/typewhisper-mac"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def build_number(value):
    if not re.fullmatch(r"[1-9][0-9]*(?:\.[0-9]+){0,2}", str(value)):
        raise ValueError("Personal builds require an increasing numeric CFBundleVersion")
    parts = tuple(int(part) for part in str(value).split('.'))
    return parts + (0,) * (3 - len(parts))


def generate(archive, info, manifest, signature, previous=None):
    tag = manifest["tag"]
    if manifest["repository"] != REPO or not re.fullmatch(r"personal-\d{8}-\d{6}-run\d+-attempt\d+", tag):
        raise ValueError("Unexpected personal release")
    if archive.name != "TypeWhisper-personal.dmg" or info.get("CFBundleIdentifier") != "com.typewhisper.mac":
        raise ValueError("Feed requires the personal Release app and its DMG")
    version = build_number(info.get("CFBundleVersion", ""))
    attrs = ET.fromstring(f'<enclosure xmlns:sparkle="{SPARKLE}" {signature.strip()} />').attrib
    if set(attrs) != {f"{{{SPARKLE}}}edSignature", "length"}:
        raise ValueError("Unexpected sign_update output")
    if len(base64.b64decode(attrs[f"{{{SPARKLE}}}edSignature"], validate=True)) != 64:
        raise ValueError("Invalid EdDSA signature encoding")
    if int(attrs["length"]) != archive.stat().st_size:
        raise ValueError("Signed archive size does not match DMG")
    url = f"https://github.com/{REPO}/releases/download/{tag}/{archive.name}"
    if previous:
        for item in ET.fromstring(previous).findall("./channel/item"):
            old_version = build_number(item.findtext(f"{{{SPARKLE}}}version", ""))
            if old_version > version:
                raise ValueError("Refusing to replace a newer personal update")
            if old_version == version:
                old = item.find("enclosure")
                if old is None or old.get("url") != url or old.get(f"{{{SPARKLE}}}edSignature") != attrs[f"{{{SPARKLE}}}edSignature"]:
                    raise ValueError("A different archive already uses this build number")
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "TypeWhisper personal updates"
    ET.SubElement(channel, "link").text = f"https://github.com/{REPO}/releases"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Personal build {info['CFBundleVersion']}"
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = str(info['CFBundleVersion'])
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = str(info["CFBundleShortVersionString"])
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = str(info.get("LSMinimumSystemVersion", "15.0"))
    ET.SubElement(item, "description").text = f"Tested personal build. Release details: https://github.com/{REPO}/releases/tag/{tag}"
    ET.SubElement(item, "enclosure", {**attrs, "url": url, "type": "application/octet-stream"})
    ET.indent(root)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["archive", "info-plist", "manifest", "signature", "output"]:
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--previous", type=Path)
    args = parser.parse_args()
    result = generate(args.archive, plistlib.loads(args.info_plist.read_bytes()),
                      json.loads(args.manifest.read_text()), args.signature.read_text(),
                      args.previous.read_bytes() if args.previous and args.previous.exists() else None)
    args.output.write_bytes(result)


if __name__ == "__main__":
    main()
