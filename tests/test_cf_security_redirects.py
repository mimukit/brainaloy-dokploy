"""Offline checks. The fake pnpm executable never calls Cloudflare."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cf-security-setup.sh"
BASH = shutil.which("bash", path="/opt/homebrew/bin:/usr/local/bin") or shutil.which("bash")
PHASE = "http_request_dynamic_redirect"
MANUAL = {
    "id": "manual-id", "ref": "manual", "action": "redirect", "enabled": False,
    "expression": '(http.request.uri.path eq "/old")', "description": "Existing redirect",
    "action_parameters": {"from_value": {"status_code": 302, "preserve_query_string": False,
                                          "target_url": {"value": "https://example.com/new"}}},
}
FAKE_PNPM = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
a = args[args.index("cf@1.0.0-beta.12") + 1:]
a = [x for x in a if x != "--quiet"]
p = pathlib.Path(os.environ["FAKE_STATE"])
state = json.loads(p.read_text())
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps(a) + "\n")
def emit(value):
    print(json.dumps(value))
if a[:2] == ["accounts", "list"]:
    emit([{"id":"account-id", "name":"Test account"}])
elif a[:2] == ["zones", "list"]:
    emit([{"name":"example.com"}])
elif a[:3] == ["dns", "records", "list"]:
    emit([{"proxied":True, "name":host, "type":"A", "content":"192.0.2.1"}
          for host in ["example.com", "www.example.com", "api.example.com"]])
elif a[:3] == ["rulesets", "account-rulesets", "phases"]:
    op, phase = a[3:5]
    if op == "get":
        if phase == "http_request_dynamic_redirect" and os.environ.get("FAKE_READ_ERROR"):
            print("403 Forbidden", file=sys.stderr)
            sys.exit(1)
        if phase not in state:
            print("404 not found", file=sys.stderr)
            sys.exit(1)
        rules = state[phase]
        if phase == "http_request_dynamic_redirect" and os.environ.get("FAKE_MISMATCH") and state.get("updated"):
            rules = json.loads(json.dumps(rules))
            rules[-1]["action_parameters"]["from_value"]["status_code"] = 302
        emit({"rules":rules})
    elif op == "update":
        rules = json.loads(pathlib.Path(a[a.index("--rules")+1][1:]).read_text())
        if "--dry-run" not in a:
            state[phase] = rules
            state["updated"] = True
            p.write_text(json.dumps(state))
        emit(rules)
    else:
        sys.exit("Unexpected phase operation")
elif a[:3] == ["zones", "settings", "get"]:
    emit({"value":"off"})
elif a[:3] == ["zones", "settings", "edit"]:
    emit({"value":"on"})
elif a[:2] == ["bot-management", "get"]:
    config = state.get("bot_management", {"fight_mode":False, "enable_js":False})
    if os.environ.get("FAKE_BOT_MISMATCH") and config.get("fight_mode"):
        config = {**config, "enable_js":False}
    emit(config)
elif a[:2] == ["bot-management", "update"]:
    if "--enable-js" not in a:
        print("cannot enable Fight_Mode while EnableJS is disabled", file=sys.stderr)
        sys.exit(1)
    config = {**state.get("bot_management", {}), "fight_mode":True, "enable_js":True}
    if "--dry-run" not in a:
        state["bot_management"] = config
        p.write_text(json.dumps(state))
    emit(config)
else:
    sys.exit("Unexpected command: " + repr(a))
'''


class RedirectChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        (self.dir / "pnpm").write_text(FAKE_PNPM)
        (self.dir / "pnpm").chmod(0o755)
        self.state = self.dir / "state.json"
        self.log = self.dir / "calls.jsonl"
        self.state.write_text(json.dumps({PHASE: [MANUAL]}))
        self.env = {**os.environ, "PATH": str(self.dir) + os.pathsep + os.environ["PATH"],
                    "FAKE_STATE": str(self.state), "FAKE_LOG": str(self.log)}

    def run_script(self, choice="", apply=True, api="", wp="", **env):
        # One account and one zone need no answer. No API or WordPress hosts.
        answers = api + "\n" + wp + "\n\n" + choice + "\n" + ("y\n" if apply else "")
        return subprocess.run([BASH, str(SCRIPT), "--apply" if apply else "--dry-run"],
                              input=answers, text=True, capture_output=True, cwd=self.dir,
                              env={**self.env, **env})

    def rules(self):
        return json.loads(self.state.read_text())[PHASE]

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_bot_fight_mode_enables_javascript_detections(self):
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        updates = [c for c in self.calls() if c[:2] == ["bot-management", "update"]]
        self.assertEqual(len(updates), 1)
        self.assertIn("--fight-mode", updates[0])
        self.assertIn("--enable-js", updates[0])
        self.assertIn("Read-back Bot Fight Mode and JavaScript detections: OK", r.stdout)
        config = json.loads(self.state.read_text())["bot_management"]
        self.assertTrue(config["fight_mode"])
        self.assertTrue(config["enable_js"])

    def test_bot_read_back_detects_disabled_javascript(self):
        r = self.run_script(FAKE_BOT_MISMATCH="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Read-back Bot Fight Mode and JavaScript detections: MISMATCH", r.stderr)

    def test_bot_settings_stay_unchanged_for_api_and_wordpress_hosts(self):
        for answers in [{"api":"1"}, {"wp":"1"}]:
            with self.subTest(answers=answers):
                self.log.write_text("")
                r = self.run_script(**answers)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertFalse(any(c[:2] == ["bot-management", "update"] for c in self.calls()))

    def test_default_and_repeat_preserve_existing_rules_and_backup(self):
        for _ in range(2):
            r = self.run_script()
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("Read-back http_request_dynamic_redirect: OK", r.stdout)
            rules = self.rules()
            self.assertEqual(rules[1], MANUAL)
            self.assertEqual(len(rules), 3)
            self.assertEqual(rules[0]["description"], "Security setup: HTTP to HTTPS")
            self.assertEqual(rules[2]["description"], "Security setup: www to non-www")
            self.assertEqual(rules[2]["expression"], '(http.host eq "www.example.com")')
            target = rules[2]["action_parameters"]["from_value"]
            self.assertEqual(target, {"status_code":301, "preserve_query_string":True,
                                     "target_url":{"expression":'concat("https://example.com", http.request.uri.path)'}})
            self.assertEqual(rules[0]["expression"], '(not ssl)')
            self.assertEqual(rules[0]["action_parameters"]["from_value"]["target_url"]["expression"],
                             'concat("https://", http.host, http.request.uri.path)')
        backups = list((self.dir / "cf-backup").glob("*/http_request_dynamic_redirect.json"))
        self.assertTrue(backups)

    def test_switch_direction_replaces_old_rule(self):
        self.assertEqual(self.run_script().returncode, 0)
        r = self.run_script("2")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(len(self.rules()), 3)
        self.assertEqual(self.rules()[0]["ref"], "cf_security_https")
        self.assertEqual(self.rules()[2]["description"], "Security setup: non-www to www")
        self.assertEqual(self.rules()[2]["expression"], '(http.host eq "example.com")')
        self.assertEqual(self.rules()[2]["action_parameters"]["from_value"]["target_url"]["expression"],
                         'concat("https://www.example.com", http.request.uri.path)')

    def test_https_only_removes_owned_hostname_rule(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.run_script("3").returncode, 0)
        self.assertEqual([r["ref"] for r in self.rules()], ["cf_security_https", "manual"])

    def test_skip_does_not_read_or_write_redirect_phase(self):
        self.assertEqual(self.run_script("0").returncode, 0)
        self.assertFalse(any(PHASE in c for c in self.calls()))
        self.assertEqual(self.rules(), [MANUAL])

    def test_dry_run_keeps_state_and_has_no_backup(self):
        r = self.run_script(apply=False)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.rules(), [MANUAL])
        self.assertFalse((self.dir / "cf-backup").exists())
        writes = [c for c in self.calls() if PHASE in c and "update" in c]
        self.assertEqual(len(writes), 1)
        self.assertIn("--dry-run", writes[0])

    def test_absent_redirect_phase_is_created(self):
        self.state.write_text("{}")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(len(self.rules()), 2)
        backup = next((self.dir / "cf-backup").glob("*/http_request_dynamic_redirect.json"))
        self.assertEqual(json.loads(backup.read_text()), {})

    def test_read_failure_prevents_all_writes(self):
        r = self.run_script(FAKE_READ_ERROR="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("403 Forbidden", r.stderr)
        self.assertFalse(any("update" in c or "edit" in c for c in self.calls()))

    def test_limit_prevents_all_writes(self):
        self.state.write_text(json.dumps({PHASE:[{**MANUAL, "ref":f"manual-{n}"} for n in range(9)]}))
        r = self.run_script()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("limit of 10", r.stderr)
        self.assertFalse(any("update" in c or "edit" in c for c in self.calls()))

    def test_verification_detects_changed_redirect_status(self):
        r = self.run_script(FAKE_MISMATCH="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Read-back http_request_dynamic_redirect: MISMATCH", r.stderr)

    def test_invalid_choice_prevents_all_writes(self):
        r = self.run_script("invalid")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Bad choice: invalid", r.stderr)
        self.assertFalse(any("update" in c or "edit" in c for c in self.calls()))


if __name__ == "__main__":
    unittest.main()
