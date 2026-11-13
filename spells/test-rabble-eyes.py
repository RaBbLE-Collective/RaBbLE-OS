#!/usr/bin/env python3
# test-rabble-eyes.py -- unit tests for rabble-eyes (fake backend, no desktop).
# Usage: python3 RaBbLE-OS/spells/test-rabble-eyes.py
import importlib.machinery
import importlib.util
import os
import json
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_l = importlib.machinery.SourceFileLoader("rabble_eyes", os.path.join(HERE, "rabble-eyes"))
_s = importlib.util.spec_from_loader("rabble_eyes", _l)
eyes = importlib.util.module_from_spec(_s)
_l.exec_module(eyes)

DENY = os.path.join(HERE, "..", "config", "RaBbLE", "eyes-deny.conf")


class Fake(eyes.Backend):
    name = "fake"

    def __init__(self, wins):
        self.wins = wins
        self.cmds = []
        self.captured = []
        self.run = self._run

    def _run(self, cmd, input=None, timeout=15):
        self.cmds.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, b"", b"")

    def list_windows(self):
        return [dict(w) for w in self.wins]

    def capture(self, win, path):
        self.captured.append(win["id"])
        open(path, "wb").write(b"png")

    def fresh_commands(self, win):
        return [["nudge", str(win["id"]), "+1"], ["nudge", str(win["id"]), "-1"]]


def W(i, app, title, visible=True):
    return {"id": str(i), "app_id": app, "title": title, "workspace": 1, "visible": visible, "focused": False}


WINS = [
    W(1, "kitty", "~"), W(2, "kitty", "build"), W(3, "org.keepassxc.KeePassXC", "Vault"),
    W(4, "firefox", "News - Mozilla Firefox Private Browsing"),
    W(5, "firefox", "Example Domain"), W(6, "foot", "My Bank - Online Banking", False),
    W(7, "codium", "hidden one", False),
]


class T(unittest.TestCase):
    def setUp(self):
        self.rules = eyes.load_deny(DENY)
        self.out = tempfile.mkdtemp()

    def test_deny_matching(self):
        ann = {w["id"]: w["denied"] for w in eyes.annotate(WINS, self.rules)}
        self.assertEqual([k for k, v in ann.items() if v], ["3", "4", "6"])

    def test_redaction(self):
        ann = {w["id"]: w for w in eyes.annotate(WINS, self.rules)}
        self.assertEqual(ann["4"]["title"], "[redacted]")
        self.assertEqual(ann["5"]["title"], "Example Domain")

    def test_parse_errors(self):
        with self.assertRaises(eyes.EyesError):
            eyes.parse_deny("bogus:x")
        self.assertEqual(eyes.parse_deny("# c\n\n"), [])

    def test_resolve(self):
        ann = eyes.annotate(WINS, self.rules)
        self.assertEqual(eyes.resolve("5", ann)["id"], "5")
        self.assertEqual(eyes.resolve("codium", ann)["id"], "7")
        self.assertEqual(eyes.resolve("example dom", ann)["id"], "5")
        with self.assertRaises(eyes.EyesError) as c:
            eyes.resolve("kitty", ann)
        self.assertIn("2 candidates", str(c.exception))
        with self.assertRaises(eyes.EyesError):
            eyes.resolve("nope", ann)

    def test_denied_not_matchable_by_title(self):
        ann = eyes.annotate(WINS, self.rules)
        with self.assertRaises(eyes.EyesError):
            eyes.resolve("online banking", ann)

    def test_shot_denied_refused(self):
        f = Fake(WINS)
        for q in ("3", "4", "6"):
            with self.assertRaises(eyes.EyesError) as c:
                eyes.do_shot(f, self.rules, q, self.out)
            self.assertIn("deny list", str(c.exception))
        self.assertEqual(f.captured, [])

    def test_shot_ok(self):
        f = Fake(WINS)
        r = eyes.do_shot(f, self.rules, "5", self.out)
        self.assertTrue(os.path.exists(r["path"]))

    def test_probe_unchanged(self):
        f = Fake(WINS)
        r = eyes.do_shot(f, self.rules, "5", self.out, probe=True, sleep=lambda s: None)
        self.assertTrue(r["probe"].startswith("unchanged"))

    def test_fresh_refuses_visible(self):
        f = Fake(WINS)
        with self.assertRaises(eyes.EyesError):
            eyes.do_shot(f, self.rules, "5", self.out, fresh=True)
        self.assertEqual(f.captured, [])
        self.assertEqual(f.cmds, [])

    def test_fresh_hidden_runs_nudge_then_capture(self):
        f = Fake(WINS)
        eyes.do_shot(f, self.rules, "7", self.out, fresh=True)
        self.assertEqual(f.cmds, [["nudge", "7", "+1"], ["nudge", "7", "-1"]])
        self.assertEqual(f.captured, ["7"])

    def test_niri_column_visibility(self):
        wss = {1: {"id": 1, "is_active": True, "output": "o", "active_window_id": 4}}
        outs = {"o": {"logical": {"width": 1920}}}
        def win(i, col, width):
            return {"id": i, "workspace_id": 1, "layout": {"pos_in_scrolling_layout": [col, 1], "tile_size": [width, 1000]}}
        wins = [win(4, 2, 1900), win(7, 4, 1900), win(9, 2, 1900)]
        rows = {r["id"]: r["visible"] for r in (eyes.NiriBackend._row(w, wss, outs, wins) for w in wins)}
        self.assertEqual(rows, {"4": True, "7": False, "9": True})
        narrow = [win(4, 2, 900), win(7, 3, 900)]
        rows = {r["id"]: r["visible"] for r in (eyes.NiriBackend._row(w, wss, outs, narrow) for w in narrow)}
        self.assertEqual(rows, {"4": True, "7": True})  # cannot prove off screen: stays visible

    def test_niri_fresh_restores_edges(self):
        n = eyes.NiriBackend().fresh_commands({"id": "17", "_edges": True})
        self.assertEqual(n[-1], ["niri", "msg", "action", "maximize-window-to-edges", "--id", "17"])
        self.assertEqual(len(eyes.NiriBackend().fresh_commands({"id": "17"})), 2)

    def test_map_groups_columns_and_redacts(self):
        class M(Fake):
            def workspaces(self):
                return [{"idx": 2, "name": "b", "output": "o", "active": False, "focused": False, "output_size": [1920, 1200]},
                        {"idx": 1, "name": "a", "output": "o", "active": True, "focused": True, "output_size": [1920, 1200]}]
        def P(i, ws, col, row, title="t", floating=False):
            w = W(i, "app", title)
            w.update(output="o", ws_idx=ws, column=None if floating else col, row=row, floating=floating, size=[10, 10])
            return w
        m = eyes.build_map(M([P(1, 1, 2, 1), P(2, 1, 1, 1), P(3, 1, 2, 2), P(4, 2, 1, 1, "Online Banking"), P(5, 1, 0, 0, floating=True)]),
                           eyes.parse_deny("title:\\bbank\\w*"))
        a, b = m[0]["workspaces"]
        self.assertEqual((a["idx"], b["idx"]), (1, 2))
        self.assertEqual([[w["id"] for w in c] for c in a["columns"]], [["2"], ["1", "3"]])
        self.assertEqual([w["id"] for w in a["floating"]], ["5"])
        self.assertTrue(b["columns"][0][0]["denied"])
        self.assertNotIn("Banking", json.dumps(m))

    def test_real_fresh_commands(self):
        n = eyes.NiriBackend().fresh_commands({"id": "9"})
        self.assertEqual(n[0], ["niri", "msg", "action", "set-window-width", "--id", "9", "+1"])
        self.assertEqual(n[1][-1], "-1")
        h = eyes.HyprBackend().fresh_commands({"id": "0xabc", "_geom": ([0, 0], [100, 50])})
        self.assertEqual(h[0][-1], "exact 101 50,address:0xabc")
        self.assertEqual(h[1][-1], "exact 100 50,address:0xabc")


if __name__ == "__main__":
    unittest.main()
