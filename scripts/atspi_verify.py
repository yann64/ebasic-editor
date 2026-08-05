#!/usr/bin/env python3
# AT-SPI-based GUI verification for ebasic-editor.
#
# Requires: `gi.repository.Atspi` (PyGObject's GObject-Introspection
# binding for AT-SPI) - confirmed importable with NO new package install
# in this environment. A real GTK4 display (GDK_BACKEND=x11, as
# established by scripts/manual_verify.sh) is still needed to launch the
# app at all.
#
# REAL, CONFIRMED SCOPE (found the hard way - read before assuming this
# script's own coverage is complete): AT-SPI's *structural* introspection
# (walking the accessible tree, reading widget names/roles, reading
# STATE via `get_state_set()`) works reliably and was the missing piece
# `scripts/manual_verify.sh` didn't have - every button/sidebar row/label
# this app has shows up with its correct accessible name, confirming the
# UI is laid out and labeled exactly as intended, and state flags (e.g.
# FOCUSED) can be read directly with no ambiguity.
#
# However, **`Atspi.Action.do_action` (e.g. "click" on a button) reports
# success (`True`) at the D-Bus protocol level but was never observed to
# produce any real application-level effect in this environment** - and
# a follow-up dig root-caused this precisely to TWO distinct, separate
# bugs, not one:
#   1. `Atspi.Action.do_action()` (the Python/GI binding, called via
#      either the instance method or the class-style `Atspi.Action.
#      do_action(node, 0)`) never sends a real D-Bus method call AT ALL
#      - confirmed via a live `dbus-monitor` on the real, canonical
#      AT-SPI bus (looked up via `org.a11y.Bus.GetAddress`, exported as
#      AT_SPI_BUS_ADDRESS for both processes to rule out a stale/
#      mismatched private bus - a real pitfall, found separately, from
#      ad hoc script runs accumulating many disconnected private bus
#      sockets under /run/user/<uid>/at-spi2-*): only `org.a11y.atspi.
#      Cache.AddAccessible` tree-registration broadcasts ever appear -
#      never a `DoAction` method call from Python's own D-Bus connection.
#   2. Calling the exact same real method DIRECTLY (bypassing Python/GI
#      entirely) - via `busctl call <app's unique bus name> <button's own
#      real per-widget object path, found via `busctl tree`/`get-
#      property ... org.a11y.atspi.Accessible Name`> org.a11y.atspi.
#      Action DoAction i 0` - genuinely DOES send the method call (this
#      time visible on the `dbus-monitor` capture) and GTK4's own
#      accessibility handler still just returns `true` with no real
#      effect (checked visually - the button's own real handler, which
#      would rewrite the output panel unconditionally per
#      `NoFileOpenGuard` in `gitui.bas`, never runs).
# So: (1) is a real bug/limitation in this specific `gi.repository.
# Atspi` binding version for `Action.do_action` specifically (structural
# introspection and state reads via the SAME binding work completely
# fine - only this one call silently no-ops); (2) is a separate, real
# limitation in GTK4's own accessibility-to-D-Bus action bridge (in this
# GTK 4.22/4.23 build) - `DoAction` on a `GtkButton` is acknowledged but
# never actually triggers `"clicked"`. Neither is a defect in this
# project's own code, and this is a second, separate, real
# input-delivery limitation, additional to (not a fix for) the raw X11
# mouse-click limitation `scripts/manual_verify.sh` already documents -
# button-click *effects* remain unconfirmed live by any route tried so
# far. Every one of those effects still has real, passing coverage via
# `tests/buildrun_smoke.bas`/`tests/gitui_smoke.bas` against the exact
# same underlying functions.
#
# So: this script verifies what AT-SPI *does* reliably prove here -
# structural/state introspection - and pairs it with the proven
# keyboard-driven interactions from `scripts/manual_verify.sh` (Return/
# Down/Ctrl+Z, which really do work) wherever an actual interaction is
# needed, rather than button clicks.
import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi

import os
import subprocess
import sys
import time

REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAILED = False

# Every widget this app's real UI is expected to expose, by (accessible
# name, role name) - walked once against the live tree below. This is
# the structural half of the C6 checklist: proof the window really has
# every button/row/label the README describes, correctly labeled.
EXPECTED_WIDGETS = [
    ("Open Folder", "button"),
    ("Open", "button"),
    ("Save", "button"),
    ("Undo", "button"),
    ("Redo", "button"),
    ("Test", "button"),
    ("Run", "button"),
    ("Build", "button"),
    ("Git Status", "button"),
    ("Diff", "button"),
    ("Stage", "button"),
    ("Unstage", "button"),
    ("Commit...", "button"),
    ("Push", "button"),
    ("Pull", "button"),
]


def report(ok, msg):
    global FAILED
    if ok:
        print(f"    PASS: {msg}")
    else:
        print(f"    FAIL: {msg}")
        FAILED = True


def canonical_bus_address():
    """The real, single AT-SPI bus this session's at-spi2-registryd
    actually publishes (queried directly via org.a11y.Bus.GetAddress on
    the main D-Bus session bus) - explicitly exporting this as
    AT_SPI_BUS_ADDRESS for both this script and the app it launches
    rules out either one falling back to spawning/discovering a
    mismatched *private* bus of its own (a real, confirmed pitfall found
    while writing this script: /run/user/<uid>/at-spi2-* accumulated
    many distinct, private socket directories over repeated ad hoc
    invocations)."""
    result = subprocess.run(
        [
            "gdbus", "call", "--session", "--dest", "org.a11y.Bus",
            "--object-path", "/org/a11y/bus", "--method", "org.a11y.Bus.GetAddress",
        ],
        capture_output=True, text=True,
    )
    # Output looks like: ('unix:path=...,guid=...',)
    addr = result.stdout.strip()
    if addr.startswith("('") and addr.endswith("',)"):
        return addr[2:-3]
    return None


def find_app(name_substr, timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        desktop = Atspi.get_desktop(0)
        for i in range(desktop.get_child_count()):
            app = desktop.get_child_at_index(i)
            try:
                name = app.get_name()
            except Exception:
                continue
            if name and name_substr.lower() in name.lower():
                return app
        time.sleep(0.3)
    return None


def find_descendant(node, name=None, role_name=None):
    try:
        n_ok = name is None or node.get_name() == name
        r_ok = role_name is None or node.get_role_name() == role_name
        if n_ok and r_ok:
            return node
    except Exception:
        pass
    for i in range(node.get_child_count()):
        try:
            child = node.get_child_at_index(i)
        except Exception:
            continue
        found = find_descendant(child, name, role_name)
        if found is not None:
            return found
    return None


def is_focused(node):
    return node.get_state_set().contains(Atspi.StateType.FOCUSED)


def xdotool(*args):
    subprocess.run(["xdotool", *args])


def find_window_id():
    out = subprocess.run(
        ["xdotool", "search", "--name", "ebasic-editor"], capture_output=True, text=True
    ).stdout.strip().splitlines()
    # Last match is reliably the real toplevel, not the 1x1 leader window
    # (confirmed via scripts/manual_verify.sh's own hard-won lessons).
    return out[-1] if out else None


def main():
    print("==> Building...")
    env = dict(os.environ)
    env["PATH"] = (
        f"{REPO_DIR}/../eBasic/build/linux-gcc/compiler:"
        f"{REPO_DIR}/../eBasic/build/linux-gcc/pkg:"
        f"{REPO_DIR}/../eBasic/build/linux-gcc/lsp:" + env.get("PATH", "")
    )
    env["GDK_BACKEND"] = "x11"
    bus_addr = canonical_bus_address()
    if bus_addr:
        env["AT_SPI_BUS_ADDRESS"] = bus_addr
        os.environ["AT_SPI_BUS_ADDRESS"] = bus_addr
    subprocess.run(["ebpm", "build"], cwd=REPO_DIR, env=env, check=True)

    subprocess.run(["pkill", "-9", "-f", f"{REPO_DIR}/target/ebasic-editor"], env=env)
    time.sleep(1)

    print("==> Launching...")
    proc = subprocess.Popen(
        [f"{REPO_DIR}/target/ebasic-editor"],
        cwd=REPO_DIR, env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        app = find_app("ebasic-editor")
        report(app is not None, "app registered in the AT-SPI desktop tree")
        if app is None:
            return

        print("==> Structural verification: every expected widget, by accessible name...")
        for name, role in EXPECTED_WIDGETS:
            node = find_descendant(app, name=name, role_name=role)
            report(node is not None, f"'{name}' ({role}) present in the accessible tree")

        print("==> WidgetGrabFocus: sidebar file-load should move real focus into the editor...")
        win_id = find_window_id()
        report(win_id is not None, "found the real toplevel window")
        if win_id is None:
            return
        xdotool("windowactivate", "--sync", win_id)
        xdotool("windowfocus", "--sync", win_id)
        time.sleep(0.4)
        xdotool("key", "--window", win_id, "--clearmodifiers", "Return")
        time.sleep(0.8)
        for _ in range(4):
            xdotool("key", "--window", win_id, "--clearmodifiers", "Down")
            time.sleep(0.25)
        time.sleep(0.4)
        xdotool("key", "--window", win_id, "--clearmodifiers", "Return")
        time.sleep(0.8)

        editor_node = find_descendant(app, role_name="text")
        report(editor_node is not None, "found the editor's SourceView via AT-SPI")
        if editor_node is not None:
            report(is_focused(editor_node), "editor has real keyboard focus after a sidebar file-load (WidgetGrabFocus)")

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

    if FAILED:
        sys.exit(1)


if __name__ == "__main__":
    main()
