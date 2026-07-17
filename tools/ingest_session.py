"""Ingest a finished Civ6 session into the training dataset (issue #8).

Run AFTER a play session (the game overwrites its logs on next launch):
    py tools/ingest_session.py

Collects from %LOCALAPPDATA%/Firaxis Games/Sid Meier's Civilization VI/Logs:
  - [ABA-TEL] per-turn state lines  -> telemetry/<stamp>_<seed>/state.jsonl
  - [ABA] decision lines            -> telemetry/<stamp>_<seed>/decisions.log
  - the game's own per-turn CSVs    -> telemetry/<stamp>_<seed>/csv/
The game grades itself: score lives in state.jsonl, and the AI_*.csv files
carry the engine's own evaluations. The trainer consumes these folders.
"""
import json
import os
import re
import shutil
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")

LOGS = os.path.expandvars(
    r"%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_ROOT = os.path.join(REPO, "telemetry")

# The engine's own per-turn evaluation files worth keeping (reward features).
CSV_KEEP = [
    "AI_Research.csv", "AI_CityBuild.csv", "AI_Military.csv", "AI_Victories.csv",
    "AI_Planning.csv", "City_BuildQueue.csv", "CombatLog.csv", "Barbarians.csv",
    "Game_PlayerScores.csv", "Player_Stats.csv", "Player_Stats_2.csv",
]

TEL = re.compile(r"\[ABA-TEL\] (.+)$")
ABA = re.compile(r"\[ABA\] ")
SEED = re.compile(r"Map Seed = (\d+)")


def parse_tel(payload: str) -> dict:
    row = {}
    for pair in payload.split():
        k, _, v = pair.partition("=")
        try:
            row[k] = float(v) if "." in v else int(v)
        except ValueError:
            row[k] = v
    return row


def main() -> None:
    lua_log = os.path.join(LOGS, "Lua.log")
    if not os.path.exists(lua_log):
        print(f"no Lua.log at {LOGS} - nothing to ingest")
        return

    with open(lua_log, encoding="utf-8", errors="replace") as f:
        lines = f.readlines()

    seed = "unknown"
    for line in lines:
        m = SEED.search(line)
        if m:
            seed = m.group(1)
            break

    stamp = time.strftime("%Y%m%d_%H%M%S")
    out = os.path.join(OUT_ROOT, f"{stamp}_seed{seed}")
    os.makedirs(os.path.join(out, "csv"), exist_ok=True)

    states, decisions = [], []
    for line in lines:
        m = TEL.search(line)
        if m:
            states.append(parse_tel(m.group(1)))
        elif ABA.search(line):
            decisions.append(line.rstrip("\n"))

    with open(os.path.join(out, "state.jsonl"), "w", encoding="utf-8") as f:
        for row in states:
            f.write(json.dumps(row) + "\n")
    with open(os.path.join(out, "decisions.log"), "w", encoding="utf-8") as f:
        f.write("\n".join(decisions))

    kept = 0
    for name in CSV_KEEP:
        src = os.path.join(LOGS, name)
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(out, "csv", name))
            kept += 1

    final = states[-1] if states else {}
    print(f"ingested -> {out}")
    print(f"  turns={len(states)} decisions={len(decisions)} csvs={kept}")
    if final:
        print(f"  final: turn={final.get('turn')} score={final.get('score')} "
              f"cities={final.get('cities')} sci={final.get('sci')}")


if __name__ == "__main__":
    main()
