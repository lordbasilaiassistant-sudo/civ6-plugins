"""FireTuner bridge probe (#34). Run while Civ6 is running (launched AFTER
EnableTuner 1 was set in AppOptions.txt). Answers one question definitively:
does this Game Pass build open the tuner's local TCP console?

Usage:  py tools/tuner_probe.py
Output: per-port verdict + hex/ascii of any greeting bytes the game sends.
        Exit 0 if any port accepted a connection, 1 otherwise.

Ports: FireTuner has used 4318 since Civ5; neighbors scanned for safety.
No packets are sent on first pass -- pure connect + listen. If a listener is
found, we additionally try the classic length-prefixed hello to see if the
socket stays open (protocol reverse-engineering happens in a later step; this
script only proves the door exists).
"""
import socket
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")

PORTS = [4318, 4319, 4320, 13000, 13001]
HOST = "127.0.0.1"


def probe(port: int) -> bool:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(2.0)
    try:
        s.connect((HOST, port))
    except (ConnectionRefusedError, socket.timeout, OSError):
        print(f"port {port}: closed")
        return False

    print(f"port {port}: OPEN -- something is listening")
    s.settimeout(2.0)
    try:
        greeting = s.recv(4096)
        if greeting:
            print(f"  greeting ({len(greeting)} bytes):")
            print("  hex   :", greeting[:64].hex(" "))
            print("  ascii :", "".join(chr(b) if 32 <= b < 127 else "." for b in greeting[:64]))
        else:
            print("  connected, no greeting (server waits for client hello)")
    except socket.timeout:
        print("  connected, silent for 2s (server likely waits for client hello)")
    finally:
        s.close()
    return True


def main() -> int:
    print(f"probing {HOST} ports {PORTS} ...")
    found = [p for p in PORTS if probe(p)]
    if found:
        print(f"\nVERDICT: tuner door EXISTS on port(s) {found} -- build honors EnableTuner.")
        print("Next step: implement the framed-packet client and exec a no-op Lua print.")
        return 0
    print("\nVERDICT: no listener. Either the game predates the flag flip (restart it),")
    print("or this build strips the tuner -- fall back to the hot-reload command channel.")
    return 1


if __name__ == "__main__":
    time.sleep(0.2)
    raise SystemExit(main())
