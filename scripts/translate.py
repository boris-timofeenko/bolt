#!/usr/bin/env python3
"""Fills missing interface strings for one or more languages with Claude Haiku.

Usage: scripts/translate.py fr de ja    (lproj names; translates only keys the table doesn't have yet)
       scripts/translate.py --dump DIR fr   then  --apply DIR fr   (when the model runs elsewhere)

Needs the `claude` CLI signed in. The English text and the Russian translation go to the model as the
source, so the tone of the hand-made Russian table carries over. Format specifiers are checked afterwards;
a translation that loses or changes one is dropped and reported.
"""
import json, pathlib, re, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
app = root / "App"
entry = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', re.M)
spec = re.compile(r'%(?:(\d+)\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h)?([@dfsuxX%])')


def unescape(s):
    return s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def table(lang):
    path = app / f"{lang}.lproj" / "Localizable.strings"
    return dict((unescape(k), unescape(v)) for k, v in entry.findall(path.read_text())) if path.exists() else {}


def source_keys():
    pattern = re.compile(r'\b(?:L|NSLocalizedString)\(\s*"((?:[^"\\]|\\.)*)"')
    keys = set()
    for source in (root / "Sources").rglob("*.swift"):
        keys.update(unescape(k) for k in pattern.findall(source.read_text()))
    return keys


def specifiers(text):
    return sorted(kind for _, kind in spec.findall(text) if kind != "%")


PROMPT = """You translate the interface of Bolt, a fast native photo viewer for macOS, into {name} ({lang}).

Rules:
- Menu items, buttons and settings use the exact terms Apple uses in the {name} localization of macOS
  (Finder, Photos, Preview): "Move to Trash", "Show in Finder", "Settings…", "Select All" and so on.
- Keep it short and plain, like the Russian version the author wrote by hand. No exclamation marks.
- Keep every format specifier (%@, %d, %.1f) and every symbol (⌘ ⌥ ↩ → – …). If the word order needs the
  arguments in another order, use positional specifiers (%1$d, %2$d).
- Keys that start with "history." are action names inserted into "Undo %@", "Redo %@", "Undone: %@" and
  "Redone: %@". Write them so they read correctly in all four of those in {name}.
- Labels ending in ":" are settings labels; keep the colon if {name} uses one.
- "Pick" and "Reject" are culling flags, "Picks" are photos flagged as picks.

Input: a JSON object; each key maps to {{"en": English text, "ru": Russian translation}}.
Output: only a JSON object mapping each key to the {name} text. No comments, no code fence."""


def ask_claude(lang, name, items):
    payload = json.dumps(items, ensure_ascii=False, indent=1)
    result = subprocess.run(
        ["claude", "-p", payload, "--output-format", "json", "--model", "haiku",
         "--system-prompt", PROMPT.format(name=name, lang=lang), "--tools", "", "--no-session-persistence"],
        stdin=subprocess.DEVNULL, capture_output=True, text=True)
    reply = json.loads(result.stdout)
    if reply.get("is_error"):
        sys.exit(f"{lang}: {reply.get('result')}")
    return json.loads(re.sub(r"^```(?:json)?\s*|\s*```$", "", reply["result"].strip()))


def pending(lang):
    english, russian, have = table("en"), table("ru"), table(lang)
    keys = sorted(source_keys() | set(english))
    return {k: {"en": english.get(k, k), "ru": russian.get(k, "")} for k in keys if k not in have}


def apply(lang, missing, done):
    """Merges checked translations into the table and returns the keys that were rejected."""
    have = table(lang)
    bad = [k for k in missing if not isinstance(done.get(k), str) or specifiers(done[k]) != specifiers(missing[k]["en"])]
    have.update({k: done[k] for k in missing if k not in bad})
    keys = sorted(source_keys() | set(table("en")))
    name = NAMES.get(lang, lang)
    lines = [f"/* {name}. Machine translated with scripts/translate.py; fix by hand where it reads wrong. */", ""]
    lines += [f'"{escape(k)}" = "{escape(have[k])}";' for k in keys if k in have]
    path = app / f"{lang}.lproj" / "Localizable.strings"
    path.parent.mkdir(exist_ok=True)
    path.write_text("\n".join(lines) + "\n")
    print(f"{lang}: {len(missing) - len(bad)} translated" + (f", rejected: {bad}" if bad else ""))
    return bad


def main(args):
    # --dump DIR writes DIR/<lang>.json and DIR/<lang>.prompt.txt for translating elsewhere;
    # --apply DIR reads the answers back from DIR/<lang>.out.json.
    mode, folder = (args[0], pathlib.Path(args[1])) if args and args[0] in ("--dump", "--apply") else (None, None)
    for lang in args[2:] if mode else args:
        name = NAMES.get(lang, lang)
        missing = pending(lang)
        if not missing:
            print(f"{lang}: nothing to translate")
        elif mode == "--dump":
            folder.mkdir(parents=True, exist_ok=True)
            (folder / f"{lang}.json").write_text(json.dumps(missing, ensure_ascii=False, indent=1))
            (folder / f"{lang}.prompt.txt").write_text(PROMPT.format(name=name, lang=lang))
        elif mode == "--apply":
            apply(lang, missing, json.loads((folder / f"{lang}.out.json").read_text()))
        else:
            apply(lang, missing, ask_claude(lang, name, missing))


NAMES = {
    "zh-Hans": "Simplified Chinese", "es": "Spanish", "hi": "Hindi", "ar": "Arabic", "pt-BR": "Brazilian Portuguese",
    "fr": "French", "de": "German", "ja": "Japanese", "ko": "Korean", "it": "Italian", "tr": "Turkish",
    "uk": "Ukrainian", "pl": "Polish", "id": "Indonesian", "vi": "Vietnamese", "nl": "Dutch",
}

if __name__ == "__main__":
    main(sys.argv[1:])
