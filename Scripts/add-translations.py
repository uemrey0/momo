#!/usr/bin/env python3
"""Adds translations to Localizable.xcstrings, keeping Xcode's formatting.

Pass a JSON file (or standard input) mapping each English key to its translations:

    {"Listening…": {"tr": "Dinliyorum…"}}

or, for Turkish only, the shorter form:

    {"Listening…": "Dinliyorum…"}

Existing keys are updated. Run `make l10n` afterwards to check nothing is missing.

Usage:
    Scripts/add-translations.py translations.json
    echo '{"Hello": "Merhaba"}' | Scripts/add-translations.py
"""

import json
import sys
from pathlib import Path

CATALOG = (Path(__file__).resolve().parent.parent
           / "Sources" / "MomoApp" / "Resources" / "Localizable.xcstrings")


def main(argv):
    source = open(argv[1], encoding="utf-8") if len(argv) > 1 else sys.stdin
    additions = json.load(source)
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    strings = catalog.setdefault("strings", {})
    for key, value in additions.items():
        translations = value if isinstance(value, dict) else {"tr": value}
        entry = strings.setdefault(key, {})
        localizations = entry.setdefault("localizations", {})
        for language, text in translations.items():
            localizations[language] = {"stringUnit": {"state": "translated", "value": text}}
    text = json.dumps(catalog, indent=2, separators=(",", " : "), ensure_ascii=False,
                      sort_keys=True)
    CATALOG.write_text(text + "\n", encoding="utf-8")
    print(f"Added or updated {len(additions)} key(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
