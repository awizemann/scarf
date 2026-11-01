#!/usr/bin/env python3
"""Server half of `ui-gate-vm.sh --real-remote`. Standard library only.

    real-remote-server.py sweep                  remove throwaway homes left by a killed run
    real-remote-server.py setup    <home>        make the throwaway home
    real-remote-server.py probe    <home>        measure one real `hermes acp`
    real-remote-server.py tick     <home>        memory, state.db signature, acp processes
    real-remote-server.py db       <home>        gzip of a read-only copy of its state.db
    real-remote-server.py killall  <home>        stop the processes of that home
    real-remote-server.py teardown <home>        stop them, remove the home, prove it

Everything is scoped to one throwaway home, ~/scarf-ui-gate-<stamp>. A process
counts as ours only when /proc/<pid>/environ names exactly that HERMES_HOME, so
the server's own gateway and a reviewer's session are never counted or touched.
From ~/.hermes this only reads config.yaml, .env (copied) and, through an
immutable read-only open, the number of sessions. Never prints a value from .env.
"""
import glob
import gzip
import json
import os
import re
import select
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time

HOME = os.path.expanduser("~")
LIVE = os.path.join(HOME, ".hermes")
NAME = re.compile(r"^scarf-ui-gate-[0-9-]+$")
GATE = ".gate"
STAMP_FILE = "stamp"


def check_home(path):
    if os.path.dirname(path) != HOME or not NAME.match(os.path.basename(path)) or os.path.islink(path):
        sys.exit(f"refusing: {path} is not ~/scarf-ui-gate-<stamp>")
    return path


def our_pids(home):
    wanted = b"HERMES_HOME=" + home.encode()
    pids = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit() or int(entry) == os.getpid():
            continue
        try:
            with open(f"/proc/{entry}/environ", "rb") as f:
                if wanted in f.read().split(b"\0"):
                    pids.append(int(entry))
        except OSError:
            pass
    return pids


def cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return f.read().rstrip(b"\0").replace(b"\0", b" ").decode(errors="replace")
    except OSError:
        return ""


def stop(home):
    for sig, wait in ((signal.SIGTERM, 3), (signal.SIGKILL, 1)):
        pids = our_pids(home)
        for pid in pids:
            try:
                os.kill(pid, sig)
            except OSError:
                pass
        if pids:
            time.sleep(wait)
    return our_pids(home)


def available_mb():
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) // 1024
    return -1


def live_session_count():
    path = os.path.join(LIVE, "state.db")
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True)
        return db.execute("select count(*) from sessions").fetchone()[0]
    except sqlite3.Error as error:
        return f"unreadable ({error})"


def real_hermes():
    for candidate in (os.path.join(HOME, ".local/bin/hermes"), shutil.which("hermes")):
        if candidate and os.path.exists(candidate):
            return os.path.realpath(candidate)
    sys.exit("no hermes on this server")


def setup(home):
    # The home itself and .gate were made by the caller, to upload this file.
    for name in ("config.yaml", ".env"):
        target = os.path.join(home, name)
        shutil.copyfile(os.path.join(LIVE, name), target)
        os.chmod(target, 0o600)
    config = os.path.join(home, "config.yaml")
    with open(config) as f:
        text = f.read()
    if re.search(r"^approvals:", text, re.M):
        sys.exit("the server's config.yaml already has an approvals block: merge it here instead of appending")
    with open(config, "a") as f:
        f.write("\napprovals:\n  mode: manual\n")
    # Hermes's code lives inside ~/.hermes: this keeps Python from writing
    # __pycache__ there, whatever module a test run is the first to import.
    wrapper = os.path.join(home, GATE, "hermes")
    with open(wrapper, "w") as f:
        f.write(f'#!/bin/sh\nPYTHONDONTWRITEBYTECODE=1; export PYTHONDONTWRITEBYTECODE\nexec "{real_hermes()}" "$@"\n')
    os.chmod(wrapper, 0o700)
    open(os.path.join(home, GATE, STAMP_FILE), "w").close()
    print(json.dumps({"binary": wrapper, "available_mb": available_mb(), "live_sessions": live_session_count()}))


def proc_memory(pid):
    out = {}
    with open(f"/proc/{pid}/smaps_rollup") as f:
        for line in f:
            parts = line.split()
            if parts[0] in ("Rss:", "Pss:", "Private_Clean:", "Private_Dirty:"):
                out[parts[0]] = int(parts[1]) // 1024
    return {"rss_mb": out["Rss:"], "pss_mb": out["Pss:"],
            "private_mb": out["Private_Clean:"] + out["Private_Dirty:"], "available_mb": available_mb()}


def probe(home):
    """One `hermes acp` as Scarf starts it, through session/new and one short
    prompt: the modules a working chat holds are loaded by then."""
    env = dict(os.environ, HERMES_HOME=home)
    before = available_mb()
    child = subprocess.Popen([os.path.join(home, GATE, "hermes"), "-p", "default", "acp"], cwd=home, env=env,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    buffered = b""

    def call(request_id, method, params, timeout):
        nonlocal buffered
        child.stdin.write((json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}) + "\n").encode())
        child.stdin.flush()
        end = time.time() + timeout
        while time.time() < end:
            while b"\n" in buffered:
                line, buffered = buffered.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if message.get("id") == request_id and "method" not in message:
                    return message
            if select.select([child.stdout], [], [], 1)[0]:
                chunk = os.read(child.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError(f"hermes acp exited during {method}")
                buffered += chunk
        raise RuntimeError(f"no answer to {method} within {timeout}s")

    result = {"available_before_mb": before}
    try:
        call(1, "initialize", {"protocolVersion": 1, "clientCapabilities": {}}, 60)
        result["after_initialize"] = proc_memory(child.pid)
        session = call(2, "session/new", {"cwd": home, "mcpServers": []}, 60)["result"]["sessionId"]
        result["after_session_new"] = proc_memory(child.pid)
        answer = call(3, "session/prompt", {"sessionId": session,
                                            "prompt": [{"type": "text", "text": "Reply with exactly: OK"}]}, 120)
        result["stop_reason"] = (answer.get("result") or {}).get("stopReason") or "error"
        result["after_prompt"] = proc_memory(child.pid)
    except (RuntimeError, KeyError) as error:
        result["error"] = str(error)
    finally:
        child.terminate()
        try:
            child.wait(5)
        except subprocess.TimeoutExpired:
            child.kill()
    print(json.dumps(result))


def tick(home):
    print(f"MEM {available_mb()}")
    signature = []
    for name in ("state.db", "state.db-wal"):
        try:
            info = os.stat(os.path.join(home, name))
            signature.append(f"{info.st_mtime_ns}:{info.st_size}")
        except OSError:
            signature.append("-")
    print("SIG " + ",".join(signature))
    for pid in our_pids(home):
        line = cmdline(pid)
        if "hermes" in line and " acp" in line:
            print("P " + line)


def copy_db(home):
    with tempfile.NamedTemporaryFile(dir=os.path.join(home, GATE), suffix=".db") as copy:
        source = sqlite3.connect(f"file:{os.path.join(home, 'state.db')}?mode=ro", uri=True, timeout=5)
        target = sqlite3.connect(copy.name)
        source.backup(target)
        # The runner opens this read-only, and can't make a -shm beside it.
        target.execute("PRAGMA journal_mode=DELETE")
        target.close()
        source.close()
        with open(copy.name, "rb") as f:
            sys.stdout.buffer.write(gzip.compress(f.read(), 1))


def writes_in_live(home):
    """Paths under ~/.hermes changed since this run began, names only. The
    server's own gateway writes there too: this is evidence to read, not a verdict."""
    stamp = os.stat(os.path.join(home, GATE, STAMP_FILE)).st_mtime
    changed = []
    for root, dirs, files in os.walk(LIVE):
        dirs[:] = [d for d in dirs if d not in ("node", "__pycache__")] if root != LIVE else dirs
        for name in files:
            path = os.path.join(root, name)
            try:
                info = os.lstat(path)
            except OSError:
                continue
            if stat.S_ISREG(info.st_mode) and info.st_mtime > stamp:
                changed.append(os.path.relpath(path, LIVE))
    return sorted(changed)


def remove(home):
    left = stop(home)
    shutil.rmtree(home, ignore_errors=True)
    return left, os.path.exists(home)


def teardown(home):
    changed = writes_in_live(home) if os.path.exists(os.path.join(home, GATE, STAMP_FILE)) else []
    left, exists = remove(home)
    print(f"changed under ~/.hermes during the run: {changed or 'nothing'}")
    print(f"live sessions: {live_session_count()}; available: {available_mb()} MB")
    print(f"processes left: {left or 'none'}; home exists: {exists}")
    print("CLEAN" if not left and not exists else "NOT CLEAN")


def sweep():
    for home in glob.glob(os.path.join(HOME, "scarf-ui-gate-*")):
        if NAME.match(os.path.basename(home)):
            left, exists = remove(home)
            print(f"removed a leftover {os.path.basename(home)}: processes left {left or 'none'}, exists {exists}")


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "sweep":
        return sweep()
    home = check_home(sys.argv[2])
    if command == "killall":
        print(f"processes left: {stop(home) or 'none'}")
    else:
        {"setup": setup, "probe": probe, "tick": tick, "db": copy_db, "teardown": teardown}[command](home)


if __name__ == "__main__":
    main()
