#!/usr/bin/env python3
"""Port probe for fass setup.sh.

Usage:
  port_probe.py PORT [PORT ...]       local availability: is each port
                                      free on this host? (bind test — a
                                      successful bind proves no listener
                                      holds the port)
  port_probe.py --connect HOST PORT   reachability: can a TCP connection
                                      be made to the (possibly remote)
                                      endpoint? (5 s timeout)

Exit status: 0 = every port free / reachable, 1 = at least one taken /
unreachable, 2 = usage error. One status line per port on stdout
("free 8000", "taken 8080", "reachable host:port", "unreachable host:port").
"""
import errno
import socket
import sys


def is_free(port):
    # A dual-stack v6 bind (V6ONLY off) conflicts with v4 listeners too,
    # so one successful bind covers both families. Fall back to a plain
    # v4 bind when the host has no IPv6.
    perm_denied = False
    for fam, addr in ((socket.AF_INET6, "::"), (socket.AF_INET, "0.0.0.0")):
        s = None
        try:
            s = socket.socket(fam, socket.SOCK_STREAM)
            if fam is socket.AF_INET6:
                s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            s.bind((addr, port))
            return True
        except OSError as e:
            if e.errno == errno.EADDRINUSE:
                return False
            if e.errno in (errno.EACCES, errno.EPERM):
                perm_denied = True
            # anything else (no IPv6, ...) -> the next family decides
        finally:
            if s is not None:
                s.close()
    if perm_denied:
        # A non-privileged user cannot bind low ports, so the bind test
        # is inconclusive. Ask the port instead: a listener answers, a
        # free port refuses.
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1.0):
                return False
        except OSError:
            return True
    return True


def is_reachable(host, port, timeout=5.0):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def parse_port(a):
    """int + 1..65535 range check; raises ValueError with a readable message."""
    port = int(a)
    if not 1 <= port <= 65535:
        raise ValueError(f"port out of range 1-65535: {a}")
    return port


def main():
    args = sys.argv[1:]
    if not args:
        print("usage: port_probe.py PORT [PORT ...] | port_probe.py --connect HOST PORT",
              file=sys.stderr)
        return 2
    if args[0] == "--connect":
        if len(args) != 3:
            print("usage: port_probe.py --connect HOST PORT", file=sys.stderr)
            return 2
        try:
            port = parse_port(args[2])
        except ValueError as e:
            print(str(e), file=sys.stderr)
            return 2
        ok = is_reachable(args[1], port)
        print(f"{'reachable' if ok else 'unreachable'} {args[1]}:{port}")
        return 0 if ok else 1
    ok_all = True
    for a in args:
        try:
            port = parse_port(a)
        except ValueError as e:
            print(str(e), file=sys.stderr)
            return 2
        ok = is_free(port)
        ok_all = ok_all and ok
        print(f"{'free' if ok else 'taken'} {port}")
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
