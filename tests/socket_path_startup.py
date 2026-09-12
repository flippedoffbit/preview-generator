#!/usr/bin/env python3
"""The daemon must come up whatever the environment looks like.

THE CRASH THIS GUARDS. run_daemon used to copy the socket path out of the
environment with strncpy(addr.sun_path, sock, sizeof(addr.sun_path) - 1). zig's
libc implements the strn* family by scanning the source for the terminator with
64-byte vector loads, which read up to 63 bytes PAST it. Environment strings sit
at the very top of the initial stack, so whenever the path ended within 64 bytes
of that boundary the scan crossed into unmapped memory and the daemon died with
SIGSEGV -- after printing "[ok] renderer ready", before binding, so the only
symptom was a socket that never appeared. It was in every build ever made,
including the one that was in production, which survived only because of what
its unit happened to put in the environment.

WHY THIS IS PYTHON AND NOT A SHELL SCRIPT. The first version launched the daemon
from bash and PASSED against the broken binary. A shell's exec never laid the
environment out the way that triggers it; only a direct execve did. A test that
cannot reproduce the defect it is named after is worse than no test, so this
drives os.execve itself and sweeps the size of the environment block -- which is
the thing that moves the string relative to the page boundary.

    tests/socket_path_startup.py <binary>
"""
import os
import sys
import time

def launch(binary, env, wait=4.0):
    """execve the daemon directly. Returns (bound, signal, stderr)."""
    sock = env["BILLPREVIEW_SOCKET"]
    log = sock + ".err"
    for f in (sock, log):
        try:
            os.unlink(f)
        except FileNotFoundError:
            pass
    pid = os.fork()
    if pid == 0:
        fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
        os.dup2(fd, 2)
        os.dup2(os.open(os.devnull, os.O_WRONLY), 1)
        try:
            os.execve(binary, [binary], env)
        finally:
            os._exit(127)
    bound, sig, t0 = False, 0, time.time()
    while time.time() - t0 < wait:
        if not bound and os.path.exists(sock):
            bound = True
            break
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            sig = status & 0x7F
            break
        time.sleep(0.005)
    try:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    except (ProcessLookupError, ChildProcessError):
        pass
    try:
        err = open(log, errors="replace").read()
        os.unlink(log)
    except OSError:
        err = ""
    return bound, sig, err

def main():
    if len(sys.argv) < 2:
        sys.exit("usage: socket_path_startup.py <binary>")
    binary = sys.argv[1]
    base = "/tmp/bpsp-%d" % os.getpid()
    os.makedirs(base, exist_ok=True)
    fails = checks = 0

    # Sweep the size of the environment block AND the path length: together they
    # decide where the string lands relative to the top of the stack, and the
    # broken build was 100% reproducible for some combinations and 0% for others.
    cases = []
    for pad in (0, 1, 3, 7, 15, 31, 47, 63, 64, 65, 127, 1024, 4096):
        cases.append(("env pad %dB" % pad, pad, 4))
    for plen in (1, 4, 12, 24, 48):
        cases.append(("path length %d" % plen, 0, plen))

    for label, pad, plen in cases:
        checks += 1
        env = dict(os.environ)
        env["BILLPREVIEW_SOCKET"] = "%s/%s.sock" % (base, "s" * plen)
        if pad:
            env["BILLPREVIEW_PAD"] = "x" * pad
        bound, sig, err = launch(binary, env)
        if bound:
            print("  ok    %s" % label)
        else:
            fails += 1
            print("  FAIL  %s -- never bound%s %s" % (
                label, (" (signal %d)" % sig) if sig else "", err.strip()[:70]))

    # An over-long path must be REFUSED, not truncated. A silently shortened
    # socket path is a daemon listening where nginx is not looking, which
    # presents as the daemon being down.
    checks += 1
    env = dict(os.environ)
    env["BILLPREVIEW_SOCKET"] = "%s/%s.sock" % (base, "s" * 200)
    bound, sig, err = launch(binary, env, wait=1.5)
    if bound:
        print("  FAIL  an over-long path bound a socket anyway (truncated)")
        fails += 1
    elif "socket path is" in err:
        print("  ok    an over-long path is refused, and says why")
    else:
        print("  FAIL  an over-long path failed without saying why: %s" % err.strip()[:70])
        fails += 1

    try:
        for f in os.listdir(base):
            os.unlink(os.path.join(base, f))
        os.rmdir(base)
    except OSError:
        pass
    print()
    print(("FAIL  %d of %d launches" % (fails, checks)) if fails
          else "ok    %d launches" % checks)
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
