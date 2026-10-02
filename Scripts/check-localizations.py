#!/usr/bin/env python3
"""Checks that every user-facing string in MomoApp is translated.

Finds string keys used through L("..."), Text("...", bundle: .module) and
String(localized: "...", bundle: .module), then verifies that each key exists in
Localizable.xcstrings with a translated value for every language listed in
Scripts/Info.plist. Keys with an integer argument (a count) must also have English
plural variations, unless they are listed in NOT_COUNTS. Exits with status 1 when
something is missing.

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

# Integer arguments usually count something, so their English text needs plural variations
# ("1 minute", "2 minutes"). Keys whose number is not a count are listed here.
INTEGER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|i|u|llu|lu)")
NOT_COUNTS = {
    "%lld min",
    "%lld s of audio",
    "%lld-day streak",
    "Done today (%lld)",
    "Download for Me (%lld MB)",
    "Downloading… %lld%%",
    "Female %d",
    "Male %d",
    "Participants (%ld)",
}


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


def has_english_plural(entry: dict) -> bool:
    english = entry.get("localizations", {}).get("en", {})
    if "plural" in english.get("variations", {}):
        return True
    return any("plural" in substitution.get("variations", {})
               for substitution in english.get("substitutions", {}).values())


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

    singular_only = sorted(
        key for key in used
        if key in strings and INTEGER.search(key) and key not in NOT_COUNTS
        and not has_english_plural(strings[key])
    )

    if "--missing" in sys.argv:
        print(json.dumps(missing, ensure_ascii=False, indent=2))
        return 0

    unused = sorted(set(strings) - set(used))
    for key in unused:
        print(f"warning: unused key in catalog: {key!r}", file=sys.stderr)
    for key, info in missing.items():
        print(f"{info['location']}: missing {', '.join(info['languages'])} "
              f"translation for {key!r}", file=sys.stderr)
    for key in singular_only:
        print(f"{used[key]}: {key!r} counts something but has no English plural variations; "
              "add them, or list the key in NOT_COUNTS", file=sys.stderr)
    if missing or invalid or singular_only:
        if missing:
            print(f"{len(missing)} string(s) need translation.", file=sys.stderr)
        if singular_only:
            print(f"{len(singular_only)} string(s) need plural variations.", file=sys.stderr)
        return 1
    print(f"All {len(used)} strings are translated into {', '.join(languages)}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
