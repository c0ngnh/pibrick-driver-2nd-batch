#!/usr/bin/env python3
"""Remove #if 0 ... #endif blocks from panel-pibrick.9203.c"""
import re
from pathlib import Path

path = Path(__file__).resolve().parent.parent / "panel-pibrick.9203.c"
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
out = []
i = 0
while i < len(lines):
    if re.match(r"^\s*#if\s+0\s*$", lines[i]):
        i += 1
        depth = 1
        while i < len(lines) and depth:
            if re.match(r"^\s*#if\b", lines[i]):
                depth += 1
            elif re.match(r"^\s*#endif\b", lines[i]):
                depth -= 1
            i += 1
        continue
    out.append(lines[i])
    i += 1

text = "".join(out)
text = text.replace("/* duplicate init block removed */\n", "")
path.write_text(text, encoding="utf-8", newline="\n")
print(f"stripped: {len(lines)} -> {len(out)} lines")
