#!/usr/bin/env python3
"""Empty one msgid's translation so the next pipeline run retranslates it.

Usage:
    ./retranslate_msgid.py <lang_dir> <msgid>

Loads <lang_dir>/assistant.po, clears the msgstr (or msgstr_plural) and any
fuzzy flag of the entry whose msgid matches exactly, and saves the file in
place. The Makefile's `retranslate-msgid` target calls this for every
language, then re-runs extract -> ai-translate -> import for just that entry.

Exit status is 0 when there is nothing to do (file/entry missing, or the
entry is already untranslated); non-zero only on parse/write errors.
"""

import os
import sys

import polib


def main(argv: list[str]) -> int:
    lang_dir, msgid = argv[1], argv[2]
    path = f"{lang_dir}/assistant.po"
    if not os.path.isfile(path):
        print(f"[{lang_dir}] no assistant.po, skipped")
        return 0
    try:
        po = polib.pofile(path, wrapwidth=0)
    except OSError as exc:
        print(f"[{lang_dir}] cannot parse {path}: {exc}")
        return 2

    entry = po.find(msgid)
    if entry is None:
        print(f"[{lang_dir}] msgid not found, skipped")
        return 0

    changed = False
    if "fuzzy" in entry.flags:
        entry.flags.remove("fuzzy")
        changed = True
    if entry.msgid_plural:
        if any(v.strip() for v in entry.msgstr_plural.values()):
            entry.msgstr_plural = {i: "" for i in entry.msgstr_plural}
            changed = True
    elif entry.msgstr.strip():
        entry.msgstr = ""
        changed = True

    if not changed:
        print(f"[{lang_dir}] already untranslated, skipped")
        return 0
    po.save()
    print(f"[{lang_dir}] emptied for retranslation")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[2].strip())
        sys.exit(2)
    sys.exit(main(sys.argv))
