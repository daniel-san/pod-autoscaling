#!/usr/bin/env python3
"""Build light and dark PDFs of report-en.md and report-pt-BR.md.

Setup (once; the virtual environment lives in .tools/, which git ignores):
    python3 -m venv .tools/pdf-venv
    .tools/pdf-venv/bin/pip install -r pdf/requirements.txt

Build:
    .tools/pdf-venv/bin/python pdf/build.py

Output: pdf/report-<lang>-<theme>.pdf (4 files).

Changes from the Markdown: a table of contents with page numbers is added after the
introduction, and links to repository files (examples/, lab/, the other report) become
plain text, because a PDF cannot open them portably.
"""
import html
import re
import sys
import unicodedata
from pathlib import Path
from string import Template

from markdown_it import MarkdownIt
from weasyprint import HTML

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "pdf"
CSS_TEMPLATE = Template((OUT / "report.css").read_text())

REPORTS = {
    "en": {
        "source": "report-en.md",
        "lang": "en",
        "contents": "Contents",
        "page": "Page",
        "of": "of",
    },
    "pt-BR": {
        "source": "report-pt-BR.md",
        "lang": "pt-BR",
        "contents": "Sumário",
        "page": "Página",
        "of": "de",
    },
}

THEMES = {
    "light": {
        "bg": "#ffffff", "fg": "#1f2328", "heading": "#0d1b2a", "strong": "#1f2328",
        "muted": "#59636e", "rule": "#c8d1db", "border": "#d1d9e0", "link": "#0969da",
        "code_bg": "#eff2f5", "th_bg": "#eaeff4", "zebra": "#f7f9fb", "path": "#1a4f8a",
    },
    "dark": {
        "bg": "#0d1117", "fg": "#d6dde6", "heading": "#f0f6fc", "strong": "#f0f6fc",
        "muted": "#8d96a0", "rule": "#3a414b", "border": "#30363d", "link": "#58a6ff",
        "code_bg": "#161b22", "th_bg": "#1b222c", "zebra": "#11161d", "path": "#9ecbff",
    },
}


def heading_id(text: str, used: set) -> str:
    """'7.1 Node.js' -> 's-7-1'; 'Appendix A. Files' -> 'appendix-a'; else a slug."""
    m = re.match(r"(\d+(?:\.\d+)*)\.?\s", text)
    if m:
        base = "s-" + m.group(1).replace(".", "-")
    else:
        m = re.match(r"(?:Appendix|Apêndice)\s+([A-Z])\b", text)
        if m:
            base = "appendix-" + m.group(1).lower()
        else:
            ascii_text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
            base = re.sub(r"[^a-z0-9]+", "-", ascii_text.lower()).strip("-") or "section"
    hid, n = base, 2
    while hid in used:
        hid, n = f"{base}-{n}", n + 1
    used.add(hid)
    return hid


def render(lang_key: str, theme: str) -> tuple[str, str]:
    cfg = REPORTS[lang_key]
    md = MarkdownIt("commonmark").enable("table")
    tokens = md.parse((ROOT / cfg["source"]).read_text())

    used, toc = set(), []
    for i, tok in enumerate(tokens):
        if tok.type == "heading_open":
            inline = tokens[i + 1]
            hid = heading_id(inline.content, used)
            tok.attrSet("id", hid)
            if tok.tag in ("h2", "h3"):
                toc.append((tok.tag, hid, md.renderInline(inline.content)))
        if tok.type != "inline" or not tok.children:
            continue
        children = tok.children
        for j, child in enumerate(children):
            if child.type != "link_open":
                continue
            href = child.attrGet("href") or ""
            if re.match(r"(https?:|mailto:|#)", href):
                continue
            # Repository file: keep the visible text, drop the link.
            close = next(k for k in range(j + 1, len(children)) if children[k].type == "link_close")
            if href in ("report-en.md", "report-pt-BR.md"):
                other = href.removesuffix(".md")
                for k in range(j + 1, close):
                    if children[k].type == "text":
                        children[k].content = f"{other}-{theme}.pdf"
            child.tag, child.attrs = "span", {"class": "path"}
            children[close].tag = "span"

    body = md.renderer.render(tokens, md.options, {})

    title = next(t.content for i, t in enumerate(tokens)
                 if t.type == "inline" and tokens[i - 1].tag == "h1")
    items = "\n".join(
        f'<li class="l{tag[1]}"><a href="#{hid}">{text}</a></li>' for tag, hid, text in toc)
    toc_html = (f'<nav class="toc"><h2 id="contents">{cfg["contents"]}</h2>'
                f"<ul>\n{items}\n</ul></nav>")
    # The first horizontal rule ends the introduction; the contents go there.
    body = body.replace("<hr />", toc_html, 1)

    css = CSS_TEMPLATE.substitute(
        THEMES[theme], label_page=cfg["page"], label_of=cfg["of"])
    page = (f'<!DOCTYPE html><html lang="{cfg["lang"]}"><head><meta charset="utf-8">'
            f"<title>{html.escape(title)}</title><style>{css}</style></head>"
            f"<body>{body}</body></html>")
    return page, title


def main() -> int:
    for lang_key in REPORTS:
        for theme in THEMES:
            page, _ = render(lang_key, theme)
            target = OUT / f"report-{lang_key}-{theme}.pdf"
            document = HTML(string=page, base_url=str(ROOT)).render()
            document.write_pdf(target)
            print(f"{target.relative_to(ROOT)}: {len(document.pages)} pages")
    return 0


if __name__ == "__main__":
    sys.exit(main())
