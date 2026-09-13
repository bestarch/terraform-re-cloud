#!/usr/bin/env python3
"""Offline bootstrap regression tests; requires terraform, bash, jq and Python 3."""

import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


TEMPLATE = Path(__file__).resolve().parents[1] / "configure.sh"
IPS = ["10.0.0.10", "10.0.0.11", "10.0.0.12"]
DEFAULTS = {
    "cluster_admin_username": "admin@example.com",
    "cluster_admin_password": "test-secret",
    "cluster_name": "redis.example.test",
    "no_of_nodes_per_cluster": 3,
    "node_internal_ips_joined": " ".join(IPS),
    "node_external_ips_joined": "192.0.2.10 192.0.2.11 192.0.2.12",
}

MOCK_CURL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
from urllib.parse import urlparse

args = sys.argv[1:]
method, payload, url = "GET", None, None
fail_http = False
i = 0
while i < len(args):
    arg = args[i]
    if arg in ("-X", "-d", "-u", "-H", "--connect-timeout", "--max-time"):
        value = args[i + 1]
        i += 2
        if arg == "-X":
            method = value
        elif arg == "-d":
            payload = value
    else:
        if arg.startswith("https://"):
            url = arg
        if arg == "--fail-with-body" or (arg.startswith("-") and not arg.startswith("--") and "f" in arg):
            fail_http = True
        i += 1
if url is None:
    sys.exit("Mock curl: missing HTTPS URL")
root = Path(os.environ["MOCK_ROOT"])
config = json.loads((root / "config.json").read_text())
state_file = root / "state.json"
state = json.loads(state_file.read_text()) if state_file.exists() else {"calls": [], "posts": {}, "gets": {}, "completed": []}
host, path = urlparse(url).hostname, urlparse(url).path
scenario, ips = config["scenario"], config["ips"]
record = {"method": method, "host": host, "path": path, "body": json.loads(payload) if payload else None}
state["calls"].append(record)
code, body, exit_code = 200, {}, 0
if method == "POST" and path in ("/v1/bootstrap/create_cluster", "/v1/bootstrap/join_cluster"):
    state["posts"][host] = state["posts"].get(host, 0) + 1
    if scenario == "http_reject" and host == ips[1]:
        code, body = 400, {"error_code": "invalid_request", "message": "join request rejected"}
    else:
        code = 202 if scenario == "empty_202" else 200
        body = "" if scenario.startswith("empty_") else {}
elif method == "GET" and path == "/v1/bootstrap":
    count = state["gets"].get(host, 0) + 1
    state["gets"][host] = count
    if scenario == "delayed_install" and host == ips[1] and count <= 2:
        code, body, exit_code = 0, "", 7
    else:
        status = "idle"
        if state["posts"].get(host):
            start = state.setdefault("submitted_gets", {}).setdefault(host, count)
            status = ("creating_cluster" if host == ips[0] else "joining_cluster") if count == start else "completed"
            if scenario == "async_error" and host == ips[1] and count > start:
                status = "error"
        address_field = "available_addresses" if scenario == "legacy_addresses" else "available_addrs"
        body = {"bootstrap_status": {"state": status}, "local_node_info": {address_field: [{"address": host}]}}
        record["bootstrap_state"] = status
        if status == "error":
            body["bootstrap_status"].update({"error_code": "join_cluster_failed", "error_details": "simulated asynchronous join failure"})
        if status == "completed" and host not in state["completed"]:
            state["completed"].append(host)
else:
    code, body = 404, {"error_code": "unexpected_endpoint", "path": path}
state_file.write_text(json.dumps(state))
sys.stdout.write(body if isinstance(body, str) else json.dumps(body))
if fail_http and code >= 400:
    print(f"curl: (22) The requested URL returned error: {code}", file=sys.stderr)
    exit_code = 22
sys.exit(exit_code)
'''


class ConfigureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        missing = [name for name in ("terraform", "bash", "jq", "python3") if not shutil.which(name)]
        if missing:
            raise unittest.SkipTest("Required tools unavailable: " + ", ".join(missing))
        cls.rendered = {}

    def render(self, values):
        cache_key = json.dumps(values, sort_keys=True)
        if cache_key not in self.rendered:
            with tempfile.TemporaryDirectory(prefix="redis-tf-render-") as directory:
                encoded_values = base64.b64encode(json.dumps(values).encode()).decode()
                expression = f'jsonencode(templatefile({json.dumps(str(TEMPLATE))}, jsondecode(base64decode("{encoded_values}"))))'
                result = subprocess.run(["terraform", "console", "-no-color"], cwd=directory, input=expression + "\n", capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.rendered[cache_key] = json.loads(json.loads(result.stdout.strip()))
        return self.rendered[cache_key]

    def run_scenario(self, scenario, overrides=None):
        values = dict(DEFAULTS, **(overrides or {}))
        with tempfile.TemporaryDirectory(prefix="redis-bootstrap-test-") as directory:
            root = Path(directory)
            bindir = root / "bin"
            bindir.mkdir()
            for name, content in {"curl": MOCK_CURL, "sleep": "#!/bin/sh\nexit 0\n"}.items():
                executable = bindir / name
                executable.write_text(content)
                executable.chmod(0o755)
            script = root / "configure.sh"
            script.write_text(self.render(values).replace('/configure_redis.log', str(root / "configure.log")))
            (root / "config.json").write_text(json.dumps({"scenario": scenario, "ips": values["node_internal_ips_joined"].split()}))
            env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ["PATH"], MOCK_ROOT=str(root))
            result = subprocess.run(["bash", str(script)], cwd=root, env=env, capture_output=True, text=True, timeout=30)
            log = (root / "configure.log").read_text() if (root / "configure.log").exists() else ""
            state = json.loads((root / "state.json").read_text()) if (root / "state.json").exists() else {"calls": []}
            self.assertFalse((root / "injection-marker").exists(), "Template values executed as shell commands")
            return result, log, state

    def assert_success(self, result, log, state, ips=IPS):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr + log)
        submits = [call for call in state["calls"] if call["method"] == "POST"]
        self.assertEqual([call["host"] for call in submits], ips)
        self.assertEqual([call["path"] for call in submits], ["/v1/bootstrap/create_cluster"] + ["/v1/bootstrap/join_cluster"] * (len(ips) - 1))
        for index, call in enumerate(submits):
            previous = state["calls"][:state["calls"].index(call)]
            self.assertTrue(any(item["host"] == call["host"] and item.get("bootstrap_state") == "idle" for item in previous))
            if index:
                self.assertTrue(any(item["host"] == ips[index - 1] and item.get("bootstrap_state") == "completed" for item in previous), "Previous bootstrap must complete before the next join")
        self.assertEqual(state["completed"], ips)

    def test_delayed_installation_waits_for_joining_node(self):
        result, log, state = self.run_scenario("delayed_install")
        self.assert_success(result, log, state)
        self.assertGreaterEqual(state["gets"][IPS[1]], 5)

    def test_empty_accepted_response_waits_for_completion(self):
        for scenario in ("empty_200", "empty_202"):
            with self.subTest(scenario=scenario):
                self.assert_success(*self.run_scenario(scenario))

    def test_json_http_200_response_waits_for_completion(self):
        self.assert_success(*self.run_scenario("success"))

    def test_async_error_stops_without_reposting(self):
        result, log, state = self.run_scenario("async_error")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("join_cluster_failed", result.stdout + result.stderr + log)
        self.assertEqual(state["posts"], {IPS[0]: 1, IPS[1]: 1})

    def test_http_400_stops_without_reposting(self):
        result, log, state = self.run_scenario("http_reject")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("400", result.stdout + result.stderr + log)
        self.assertIn("invalid_request", result.stdout + result.stderr + log)
        self.assertEqual(state["posts"], {IPS[0]: 1, IPS[1]: 1})

    def test_documented_address_field_and_legacy_fallback(self):
        for scenario in ("available_addrs", "legacy_addresses"):
            with self.subTest(scenario=scenario):
                self.assert_success(*self.run_scenario(scenario))

    def test_one_and_two_node_clusters_succeed(self):
        for count in (1, 2):
            with self.subTest(count=count):
                result, log, state = self.run_scenario("success", {
                    "no_of_nodes_per_cluster": count,
                    "node_internal_ips_joined": " ".join(IPS[:count]),
                    "node_external_ips_joined": " ".join(DEFAULTS["node_external_ips_joined"].split()[:count]),
                })
                self.assert_success(result, log, state, IPS[:count])

    def test_credentials_survive_shell_and_json_characters_without_logging(self):
        username = "admin+o'brien@example.com"
        password = "literal'\"\\$word ${not_var} %{if true}\n$(touch injection-marker)`touch injection-marker`; secret"
        result, log, state = self.run_scenario("success", {"cluster_admin_username": username, "cluster_admin_password": password})
        self.assert_success(result, log, state)
        for call in state["calls"]:
            if call["method"] == "POST":
                self.assertEqual(call["body"]["credentials"], {"username": username, "password": password})
        self.assertNotIn(password, result.stdout + result.stderr + log)
        self.assertNotIn("touch injection-marker", result.stdout + result.stderr + log)


if __name__ == "__main__":
    unittest.main(verbosity=2)
