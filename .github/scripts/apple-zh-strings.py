"""Collect the Simplified Chinese interface text of macOS's own apps and System Settings panes.

Usage: python3 apple-zh-strings.py <output.tsv>  (run by the Test runners job in .github/workflows/ci.yml)
Writes one line per string: bundle<TAB>table<TAB>key<TAB>text. Reads .strings, .stringsdict and
.loctable files; .loctable holds every language, and only the zh_CN / zh-Hans part is kept.
The result is reference material for docs/copy-guide.md: our wording follows Apple's.
"""
import glob
import os
import plistlib
import sys

ROOTS = [
    "/System/Applications/*.app",
    "/System/Applications/Utilities/*.app",
    "/System/Library/ExtensionKit/Extensions/*.appex",
    "/System/Library/CoreServices/*.app",
    "/System/Library/PreferencePanes/*.prefPane",
]
LANGS = ("zh_CN", "zh-Hans", "zh_Hans")


def load(path):
    try:
        with open(path, "rb") as handle:
            return plistlib.load(handle)
    except Exception:
        try:
            with open(path, encoding="utf-16") as handle:
                text = handle.read()
            return plistlib.loads(text.encode("utf-8"))
        except Exception:
            return None


def flatten(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from flatten(item)


def main(output):
    rows = 0
    with open(output, "w", encoding="utf-8") as out:
        for pattern in ROOTS:
            for bundle in sorted(glob.glob(pattern)):
                name = os.path.basename(bundle)
                files = []
                for lang in LANGS:
                    files += glob.glob(f"{bundle}/Contents/Resources/{lang}.lproj/*.strings")
                files += glob.glob(f"{bundle}/Contents/Resources/*.loctable")
                for path in files:
                    data = load(path)
                    if not isinstance(data, dict):
                        continue
                    if path.endswith(".loctable"):
                        data = next((data[lang] for lang in LANGS if isinstance(data.get(lang), dict)), None)
                        if data is None:
                            continue
                    table = os.path.splitext(os.path.basename(path))[0]
                    for key, value in data.items():
                        for text in flatten(value):
                            text = " ".join(text.split())
                            if text and any("一" <= ch <= "鿿" for ch in text):
                                out.write(f"{name}\t{table}\t{' '.join(str(key).split())}\t{text}\n")
                                rows += 1
    print(f"{rows} strings")


if __name__ == "__main__":
    main(sys.argv[1])
