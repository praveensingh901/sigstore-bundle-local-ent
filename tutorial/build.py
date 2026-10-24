#!/usr/bin/env python3
"""Assemble the Sigstore Academy tutorial into single-file HTML.

  python3 tutorial/build.py

Outputs:
  tutorial/index.html      full document (open locally or serve with GitHub Pages)
  tutorial/dist/academy.html  body-only variant (for hosts that add their own <head>)
"""
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE / "src"

FONTS = ('<link rel="preconnect" href="https://fonts.googleapis.com">'
         '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>'
         '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,400..800'
         '&family=JetBrains+Mono:wght@400;700&family=Source+Serif+4:ital,opsz,wght@0,8..60,400;0,8..60,600;1,8..60,400&display=swap">')


def body() -> str:
    tools = json.loads((SRC / "tools.json").read_text())
    js = "\n".join([
        "const TOOLS_DATA = " + json.dumps(tools, ensure_ascii=False) + ";",
        (SRC / "content.js").read_text(),
        (SRC / "diagram.js").read_text(),
        (SRC / "app.js").read_text(),
    ])
    if "</script" in js:
        raise SystemExit("content must not contain </script")
    return ("<title>Sigstore Academy</title>\n"
            '<meta name="claude:viewport-fit-sides" content="cover">\n'
            + FONTS + "\n<style>\n" + (SRC / "style.css").read_text() + "\n</style>\n"
            '<div id="app"></div>\n<script>\n' + js + "\n</script>\n")


def main() -> None:
    b = body()
    (HERE / "dist").mkdir(exist_ok=True)
    (HERE / "dist" / "academy.html").write_text(b)
    full = ('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
            '<style>:root{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}'
            'body{margin:0}img{max-width:100%}[hidden]{display:none!important}</style>\n'
            + b.replace("<div id=\"app\"></div>", "</head>\n<body>\n<div id=\"app\"></div>", 1)
            + "</body>\n</html>\n")
    (HERE / "index.html").write_text(full)
    print(f"index.html {len(full)//1024} KB, dist/academy.html {len(b)//1024} KB")


if __name__ == "__main__":
    main()
