"""Live hot-patch installer (#34). Ship a validated repo copy onto the RUNNING
game: the engine's DebugHotloadCache reloads the context, OnShutdown unhooks
the old handlers + caches state, OnInit(isReload=true) restores it. No restart.

PREREQ: the hot-reload harness commit must already be LOADED in the running
game -- the harness itself (and any .modinfo/.xml change) still needs one
normal between-sessions install. Lua-only changes after that go live here.

Usage:  py tools/hotpatch.py           # validate, then atomically swap the Lua
        py tools/hotpatch.py --dry     # validate only

After patching, confirm in Lua.log:  grep "HOTLOAD complete"
A Runtime Error flood instead means the patch is bad -- rerun with the
previous git revision immediately (git show HEAD~1:<lua> > file, rerun).
"""
import os
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "AutoBuildersArmies", "UI", "AutoBuildersArmies.lua")
DST = os.path.join(
    os.path.expanduser("~"), "OneDrive", "Documents",
    "My Games", "Sid Meier's Civilization VI (WinApp)",
    "Mods", "AutoBuildersArmies", "UI", "AutoBuildersArmies.lua")


def main() -> int:
    print("validating repo copy ...")
    r = subprocess.run(
        [sys.executable, os.path.join(REPO, "tools", "validate_mod.py"),
         os.path.join(REPO, "AutoBuildersArmies")],
        capture_output=True, text=True)
    tail = (r.stdout or "").strip().splitlines()
    print("\n".join(tail[-3:]))
    if r.returncode != 0 or "RESULT: PASS" not in (r.stdout or ""):
        print("ABORT: validator did not pass -- nothing installed.")
        return 1
    if "--dry" in sys.argv:
        print("dry run: validation passed, not installing.")
        return 0

    if not os.path.exists(DST):
        print(f"ABORT: installed copy not found at {DST}")
        return 1

    # Atomic swap: the watcher must never see a half-written file. Write the
    # full bytes to a sibling temp name, then os.replace (atomic, same volume).
    tmp = DST + ".incoming"
    shutil.copyfile(SRC, tmp)
    os.replace(tmp, DST)
    print("HOT-PATCH INSTALLED (atomic). If the game is running, watch for:")
    print('  [ABA] HOTLOAD complete -- new code live, state restored')
    print(r"  in %LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs\Lua.log")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
