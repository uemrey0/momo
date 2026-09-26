#!/usr/bin/env python3
"""A git merge driver for String Catalogs (.xcstrings).

Parallel branches that each add translations touch neighbouring lines of the same JSON file,
which git reports as conflicts. This driver merges the catalogs as data instead: keys added
on either side are kept, keys removed on one side (and untouched on the other) are removed,
and when both sides change the same key differently, the current branch wins and the key is
reported.

Enable it once per clone (the attribute is already in .gitattributes):

    git config merge.xcstrings.name "String Catalog merge"
    git config merge.xcstrings.driver "python3 Scripts/merge-xcstrings.py %O %A %B"

Usage by git: merge-xcstrings.py <ancestor> <current> <other>. The result is written to
<current>. Exits with status 1 only when a file cannot be read as JSON.
"""

import json
import sys


def load(path):
    with open(path, encoding="utf-8") as file:
        text = file.read()
    return json.loads(text) if text.strip() else {"sourceLanguage": "en", "strings": {}}


def dump(catalog, path):
    text = json.dumps(catalog, indent=2, separators=(",", " : "), ensure_ascii=False,
                      sort_keys=True)
    with open(path, "w", encoding="utf-8") as file:
        file.write(text + "\n")


def merge(base, ours, theirs):
    merged = dict(ours)
    base_strings = base.get("strings", {})
    our_strings = ours.get("strings", {})
    their_strings = theirs.get("strings", {})
    strings = {}
    conflicts = []
    for key in set(base_strings) | set(our_strings) | set(their_strings):
        original = base_strings.get(key)
        mine = our_strings.get(key)
        other = their_strings.get(key)
        if mine == other:
            result = mine
        elif mine == original:
            result = other
        elif other == original:
            result = mine
        else:
            result = mine if mine is not None else other
            conflicts.append(key)
        if result is not None:
            strings[key] = result
    merged["strings"] = strings
    return merged, conflicts


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        base, ours, theirs = (load(path) for path in argv[1:])
    except (OSError, ValueError) as error:
        print(f"merge-xcstrings: {error}", file=sys.stderr)
        return 1
    merged, conflicts = merge(base, ours, theirs)
    dump(merged, argv[2])
    for key in sorted(conflicts):
        print(f"merge-xcstrings: both sides changed {key!r}; kept the current branch's value",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
