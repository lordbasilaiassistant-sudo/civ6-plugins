"""Cross-game telemetry analysis (issue #8) — the trainer's first stage.

Reads every telemetry/<session>/state.jsonl and prints per-game yield curves
plus a cross-game comparison at fixed turn checkpoints. This is the reward
signal the parameter trainer will optimize; run it after any rule change to
see whether the change actually helped.

    py tools/analyze_telemetry.py
"""
import json
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TROOT = os.path.join(REPO, "telemetry")
CHECKPOINTS = [10, 20, 30, 50, 75, 100]
KEYS = ["score", "cities", "pop", "sci", "cul", "gpt", "techs", "mil"]


def load(session: str):
    path = os.path.join(TROOT, session, "state.jsonl")
    if not os.path.exists(path):
        return []
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows


def at_turn(rows, turn):
    best = None
    for r in rows:
        t = r.get("turn", 0)
        if t <= turn and (best is None or t > best.get("turn", 0)):
            best = r
    return best


def main() -> None:
    if not os.path.isdir(TROOT):
        print("no telemetry/ directory")
        return
    sessions = sorted(d for d in os.listdir(TROOT)
                      if os.path.isdir(os.path.join(TROOT, d)))
    games = [(s, load(s)) for s in sessions]
    games = [(s, r) for s, r in games if r]

    print(f"{len(games)} game(s) with state data\n")
    for s, rows in games:
        final = rows[-1]
        print(f"{s}: turns={final.get('turn')} score={final.get('score')} "
              f"cities={final.get('cities')} pop={final.get('pop')} "
              f"sci/turn={final.get('sci')} techs={final.get('techs')}")

    for cp in CHECKPOINTS:
        rows_at = [(s, at_turn(r, cp)) for s, r in games]
        rows_at = [(s, r) for s, r in rows_at if r and r.get("turn", 0) >= cp - 5]
        if not rows_at:
            continue
        print(f"\n== turn {cp} checkpoint ({len(rows_at)} games) ==")
        for k in KEYS:
            vals = [r.get(k, 0) for _, r in rows_at]
            if any(vals):
                best_s = max(rows_at, key=lambda x: x[1].get(k, 0))[0][:22]
                print(f"  {k:6} avg={sum(vals)/len(vals):7.1f} "
                      f"max={max(vals):7.1f}  (best: {best_s})")


if __name__ == "__main__":
    main()
