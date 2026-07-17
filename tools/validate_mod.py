"""Static validator for mods in this repo. Catches, before you ever launch the game:
  - Lua syntax errors           (the game fails silently or half-loads)
  - XML syntax errors           (incl. the '--' inside a comment trap, which kills a whole panel)
  - Controls.X used in Lua but missing from the panel XML
  - files promised in .modinfo that don't exist on disk
  - file-level Lua locals used before declaration (compile as nil globals -> runtime crash)

Usage:  py tools/validate_mod.py [ModFolder ...]      (default: every folder with a .modinfo)
Needs:  py -m pip install luaparser
"""
import sys, os, re, glob, xml.etree.ElementTree as ET

sys.stdout.reconfigure(encoding="utf-8")
from luaparser import ast

def validate(mod_dir):
    ok = True
    name = os.path.basename(mod_dir.rstrip("\\/"))
    print("=== %s ===" % name)

    modinfos = glob.glob(os.path.join(mod_dir, "*.modinfo"))
    luas     = glob.glob(os.path.join(mod_dir, "**", "*.lua"), recursive=True)
    xmls     = glob.glob(os.path.join(mod_dir, "**", "*.xml"), recursive=True) + modinfos

    for x in xmls:
        try:
            ET.parse(x)
            print("XML OK   ", os.path.relpath(x, mod_dir))
        except Exception as e:
            ok = False
            print("XML FAIL ", os.path.relpath(x, mod_dir), "->", e)

    all_ids = set()
    for x in xmls:
        if not x.endswith(".modinfo"):
            all_ids |= set(re.findall(r'ID="([^"]+)"', open(x, encoding="utf-8").read()))

    for lua in luas:
        src = open(lua, encoding="utf-8").read()
        rel = os.path.relpath(lua, mod_dir)
        try:
            ast.parse(src)
            print("LUA OK   ", rel, "(%d lines)" % (src.count("\n") + 1))
        except Exception as e:
            ok = False
            print("LUA FAIL ", rel, "->", e)
            continue

        code = "\n".join(re.sub(r"--.*$", "", ln) for ln in src.split("\n"))
        missing = sorted(set(re.findall(r"Controls\.(\w+)", code)) - all_ids)
        if missing:
            ok = False
            print("  Controls missing from XML:", missing)

        decls, lines = {}, code.split("\n")
        for i, ln in enumerate(lines, 1):
            m = re.match(r"local\s+(?:function\s+)?([A-Za-z_]\w*)", ln)
            if m and m.group(1) not in decls:
                decls[m.group(1)] = i
        for nm, dline in decls.items():
            pat = re.compile(r'(?<![\w.:"\'])' + re.escape(nm) + r"\s*[\(\[]")
            for i, ln in enumerate(lines[: dline - 1], 1):
                if pat.search(ln) and not re.search(r"function\s*\([^)]*" + re.escape(nm), ln):
                    ok = False
                    print("  use-before-declaration: %s used line %d, declared line %d" % (nm, i, dline))
                    break

    for mi in modinfos:
        root = ET.parse(mi).getroot()
        for f in sorted({f.text for f in root.iter("File") if f.text}):
            p = os.path.join(mod_dir, f.replace("/", os.sep))
            if os.path.isfile(p):
                print("FILE OK  ", f)
            else:
                ok = False
                print("FILE MISS", f)
    return ok

if __name__ == "__main__":
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    targets = sys.argv[1:] or [
        d for d in glob.glob(os.path.join(here, "*"))
        if os.path.isdir(d) and glob.glob(os.path.join(d, "*.modinfo"))
    ]
    results = [validate(t) for t in targets]
    print("\nRESULT:", "PASS" if all(results) else "FAIL")
    sys.exit(0 if all(results) else 1)
