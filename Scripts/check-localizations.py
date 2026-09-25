#!/usr/bin/env python3
"""Checks that every user-facing string in MomoApp is translated.

Finds string keys used through L("..."), Text("...", bundle: .module) and
String(localized: "...", bundle: .module), then verifies that each key exists in
Localizable.xcstrings with a translated value for every language listed in
Scripts/Info.plist. Exits with status 1 when something is missing.

Usage:
    Scripts/check-localizations.py            # report problems
    Scripts/check-localizations.py --missing  # print missing keys as JSON, for translators
"""

import json
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "MomoApp"
CATALOG = SOURCES / "Resources" / "Localizable.xcstrings"
INFO_PLIST = ROOT / "Scripts" / "Info.plist"

STRING = r'"((?:[^"\\]|\\.)*)"'
PATTERNS = [
    re.compile(r"\bL\(\s*" + STRING),
    re.compile(r"\bText\(\s*" + STRING + r"\s*,\s*bundle:\s*\.module"),
    re.compile(r"String\(\s*localized:\s*" + STRING + r"\s*,\s*bundle:\s*\.module"),
]


def unescape(key: str) -> str:
    return key.encode("utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8")


def used_keys() -> dict:
    keys = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        for pattern in PATTERNS:
            for match in pattern.finditer(text):
                raw = match.group(1)
                if "\\(" in raw:
                    line = text.count("\n", 0, match.start()) + 1
                    print(f"{path.relative_to(ROOT)}:{line}: interpolation in a localized key; "
                          "use String(format:) instead", file=sys.stderr)
                    keys.setdefault("__invalid__", []).append(raw)
                    continue
                key = unescape(raw)
                line = text.count("\n", 0, match.start()) + 1
                keys.setdefault(key, f"{path.relative_to(ROOT)}:{line}")
    return keys


def main() -> int:
    languages = [
        code for code in plistlib.loads(INFO_PLIST.read_bytes())["CFBundleLocalizations"]
        if code != "en"
    ]
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    strings = catalog["strings"]
    used = used_keys()
    invalid = used.pop("__invalid__", [])

    missing = {}
    for key, location in sorted(used.items()):
        entry = strings.get(key)
        if entry is None:
            missing[key] = {"location": location, "languages": languages}
            continue
        if entry.get("shouldTranslate") is False:
            continue
        absent = [
            language for language in languages
            if entry.get("localizations", {}).get(language, {})
            .get("stringUnit", {}).get("state") != "translated"
        ]
        if absent:
            missing[key] = {"location": location, "languages": absent}

    if "--missing" in sys.argv:
        print(json.dumps(missing, ensure_ascii=False, indent=2))
        return 0

    unused = sorted(set(strings) - set(used))
    for key in unused:
        print(f"warning: unused key in catalog: {key!r}", file=sys.stderr)
    for key, info in missing.items():
        print(f"{info['location']}: missing {', '.join(info['languages'])} "
              f"translation for {key!r}", file=sys.stderr)
    if missing or invalid:
        print(f"{len(missing)} string(s) need translation.", file=sys.stderr)
        return 1
    print(f"All {len(used)} strings are translated into {', '.join(languages)}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
