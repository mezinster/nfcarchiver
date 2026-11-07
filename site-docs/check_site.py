#!/usr/bin/env python3
"""Checks for the documentation site.

    python site-docs/check_site.py
        Source checks: locale folders, page parity, required contact text.

    python site-docs/check_site.py --built <dir> --base <url-path> --sha <sha>
        Built-tree checks: build marker, base-path-absolute links, the pages
        Apple needs in every locale.

Both print one line per problem and exit non-zero if there is any.
"""
import argparse
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ARB_DIR = HERE.parent / "lib" / "l10n"
DOCS = HERE / "docs"
EMAIL = "support@nfcarchiver.com"


def locales():
    """The app's locales: the xx of lib/l10n/app_xx.arb."""
    return sorted(p.stem[len("app_"):] for p in ARB_DIR.glob("app_*.arb"))


def check_source():
    problems = []
    langs = locales()
    if not langs:
        return [f"no app_*.arb files found in {ARB_DIR}"]
    if "en" not in langs:
        problems.append("app_en.arb (the template locale) is missing")

    present = sorted(p.name for p in DOCS.iterdir() if p.is_dir()) if DOCS.is_dir() else []
    present = [d for d in present if d != "assets"]
    for lang in langs:
        if lang not in present:
            problems.append(f"docs/{lang}/ is missing")
    for d in present:
        if d not in langs:
            problems.append(f"docs/{d}/ has no lib/l10n/app_{d}.arb")

    en = DOCS / "en"
    pages = sorted(p.relative_to(en).as_posix() for p in en.rglob("*.md")) if en.is_dir() else []
    for lang in langs:
        if lang == "en" or not (DOCS / lang).is_dir():
            continue
        for page in pages:
            if not (DOCS / lang / page).is_file():
                problems.append(f"docs/{lang}/{page} is missing (en/ has it)")

    for lang in langs:
        privacy = DOCS / lang / "privacy.md"
        support = DOCS / lang / "support.md"
        if privacy.is_file():
            text = privacy.read_text(encoding="utf-8")
            if EMAIL not in text:
                problems.append(f"docs/{lang}/privacy.md lacks {EMAIL}")
            if "Chameleon" not in text:
                problems.append(f"docs/{lang}/privacy.md does not mention Chameleon")
            if lang != "en" and not re.search(r"\]\((\.\./)+privacy/?\)", text):
                problems.append(f"docs/{lang}/privacy.md has no link to the English privacy page")
        if support.is_file() and EMAIL not in support.read_text(encoding="utf-8"):
            problems.append(f"docs/{lang}/support.md lacks {EMAIL}")
    return problems


LINK = re.compile(r'\b(?:href|src)="(/[^"]*)"')


def check_built(built, base, sha):
    problems = []
    root = Path(built)
    if not root.is_dir():
        return [f"{built} is not a directory"]
    if not (base.startswith("/") and base.endswith("/")):
        return [f"--base {base!r} must start and end with /"]
    marker = f'<meta name="nfar-docs-build" content="{sha}"'
    htmls = sorted(root.rglob("*.html"))
    if not htmls:
        problems.append(f"{built} has no HTML files")
    for f in htmls:
        rel = f.relative_to(root).as_posix()
        text = f.read_text(encoding="utf-8")
        if marker not in text:
            problems.append(f"{rel}: build marker for {sha} missing")
        for url in sorted(set(LINK.findall(text))):
            if url.startswith("//") or not url.startswith(base):
                problems.append(f"{rel}: link {url} does not start with {base}")
    for lang in locales():
        prefix = "" if lang == "en" else f"{lang}/"
        for page in ("privacy", "support"):
            if not (root / prefix / page / "index.html").is_file():
                problems.append(f"{prefix}{page}/index.html is missing")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--built")
    ap.add_argument("--base")
    ap.add_argument("--sha")
    a = ap.parse_args()
    if a.built:
        if not (a.base and a.sha):
            ap.error("--built needs --base and --sha")
        problems = check_built(a.built, a.base, a.sha)
    else:
        problems = check_source()
    for p in problems:
        print(f"FAIL: {p}")
    if problems:
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
