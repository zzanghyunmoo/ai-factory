"""Offline safety contracts only; no WSL, apt, systemd or container calls."""
import copy
import hashlib
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("guard", ROOT / "scripts/guest/guard.py")
assert spec is not None and spec.loader is not None
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
OWNER = "12345678-1234-1234-1234-123456789abc"
IMAGE = json.loads((ROOT / "versions.json").read_text())["kind"]["nodeImage"]


def containers():
    return [{"Id": name + "-id", "Name": "/" + name,
             "Config": {"Image": IMAGE, "Labels": {"io.x-k8s.kind.cluster": "infra", "io.x-k8s.kind.role": role}},
             "State": {"Running": True},
             "HostConfig": {"PortBindings": ports}}
            for name, role, ports in [
                ("infra-control-plane", "control-plane", {
                    "6443/tcp": [{"HostIp": "127.0.0.1", "HostPort": "16443"}],
                    "30080/tcp": [{"HostIp": "127.0.0.1", "HostPort": "18080"}]}),
                ("infra-worker", "worker", {})]]


class GuardTests(unittest.TestCase):
    def test_owner_mismatch_and_missing_name(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "marker.json"
            for data in ({"owner": "other", "name": "infra"}, {"owner": OWNER}):
                marker.write_text(json.dumps(data))
                with self.assertRaises(ValueError):
                    guard.check_owner(marker, OWNER)
            marker.write_text(json.dumps({"owner": OWNER, "name": "infra"}))
            guard.check_owner(marker, OWNER)

    def test_fingerprint_changes_with_config_and_image(self):
        base = guard.fingerprint(b"config", IMAGE)
        self.assertNotEqual(base, guard.fingerprint(b"config\n", IMAGE))
        self.assertNotEqual(base, guard.fingerprint(b"config", IMAGE + "x"))

    def test_absent_only_without_record(self):
        self.assertEqual(guard.cluster_status([], None, "digest", OWNER, IMAGE), "absent")
        with self.assertRaises(ValueError):
            guard.cluster_status([], {}, "digest", OWNER, IMAGE)

    def test_foreign_partial_and_changed_rejected(self):
        live = containers()
        state = guard.make_record(live, "digest", OWNER)
        for nodes, record, digest in ((live, None, "digest"), (live[:1], state, "digest"),
                                       (live, state, "changed"), (live, {**state, "owner": "foreign"}, "digest")):
            with self.subTest(nodes=len(nodes), digest=digest), self.assertRaises(ValueError):
                guard.cluster_status(nodes, record, digest, OWNER, IMAGE)

    def test_actual_drift_not_hidden_by_fingerprint(self):
        live = containers()
        state = guard.make_record(live, "digest", OWNER)
        self.assertEqual(guard.cluster_status(live, state, "digest", OWNER, IMAGE), "existing")
        for mutate in (lambda n: n[0]["Config"].update(Image="foreign"),
                       lambda n: n[1].update(Id="replaced"),
                       lambda n: n[0]["Config"]["Labels"].update({"io.x-k8s.kind.role": "worker"}),
                       lambda n: n[0]["HostConfig"]["PortBindings"]["6443/tcp"][0].update(HostIp="192.0.2.1")):
            broken = copy.deepcopy(live)
            mutate(broken)
            with self.assertRaises(ValueError):
                guard.cluster_status(broken, state, "digest", OWNER, IMAGE)

    def test_only_recorded_stopped_nodes_can_resume(self):
        live = containers()
        state = guard.make_record(live, "digest", OWNER)
        live[1]["State"]["Running"] = False
        with self.assertRaises(ValueError):
            guard.cluster_status(live, state, "digest", OWNER, IMAGE)
        self.assertEqual(guard.cluster_status(live, state, "digest", OWNER, IMAGE,
                                             allow_stopped=True), "stopped")
        for record in (None, {**state, "owner": "foreign"}):
            with self.assertRaises(ValueError):
                guard.cluster_status(live, record, "digest", OWNER, IMAGE, allow_stopped=True)
        live[1]["Id"] = "replaced"
        with self.assertRaises(ValueError):
            guard.cluster_status(live, state, "digest", OWNER, IMAGE, allow_stopped=True)

    def test_ready_requires_exact_two_names_and_versions(self):
        nodes = {"items": [{"metadata": {"name": name}, "status": {
            "nodeInfo": {"kubeletVersion": "v1.37.0"},
            "conditions": [{"type": "Ready", "status": "True"}]}}
            for name in ("infra-control-plane", "infra-worker")]}
        guard.check_nodes(nodes, "1.37.0")
        for broken in ({"items": nodes["items"][:1]}, {"items": nodes["items"] * 2}):
            with self.assertRaises(ValueError):
                guard.check_nodes(broken, "1.37.0")
        wrong_version = copy.deepcopy(nodes)
        wrong_version["items"][1]["status"]["nodeInfo"]["kubeletVersion"] = "v1.36.0"
        with self.assertRaises(ValueError):
            guard.check_nodes(wrong_version, "1.37.0")
        nodes["items"][1]["status"]["conditions"][0]["status"] = "False"
        with self.assertRaises(ValueError):
            guard.check_nodes(nodes, "1.37.0")

    def test_inspection_includes_reserved_foreign_names(self):
        foreign = containers()
        foreign[0]["Config"]["Labels"] = {}
        with patch.object(guard, "run", side_effect=["a b", json.dumps(foreign)]) as run:
            self.assertEqual(len(guard.inspect_containers()), 2)
            self.assertEqual(run.call_count, 2)

    def test_unrelated_unlabelled_container_is_not_adopted(self):
        unrelated = {"Name": "/unrelated", "Config": {"Labels": None}}
        with patch.object(guard, "run", side_effect=["a", json.dumps([unrelated])]):
            self.assertEqual(guard.inspect_containers(), [])

    def test_command_failure_does_not_leak_stdout(self):
        result = subprocess.CompletedProcess(["kubectl"], 1, "private-key", "private-key")
        with patch.object(guard.subprocess, "run", return_value=result), self.assertRaises(ValueError) as error:
            guard.run(["kubectl"])
        self.assertNotIn("private-key", str(error.exception))

    def test_doctor_rejects_old_running_daemon_with_pinned_packages(self):
        pins = {"kind": {"sha256": hashlib.sha256(b"kind").hexdigest()},
                "kubectl": {"sha256": hashlib.sha256(b"kubectl").hexdigest()},
                "docker": {"packages": {"docker-ce": "5:29.8.1-1~ubuntu.24.04~noble"}},
                "ansible": {"version": "2.21.4"}}
        with patch.object(guard.Path, "read_bytes", side_effect=[b"kind", b"kubectl"]), \
                patch.object(guard, "run", side_effect=["install ok installed 5:29.8.1-1~ubuntu.24.04~noble",
                                                       "2.21.4", "29.7.0"]), self.assertRaises(ValueError):
            guard.check_versions(ROOT, pins)

    def test_owner_failure_precedes_subprocess_and_state_access(self):
        with patch.object(guard.sys, "argv", ["guard", "preflight", "--root", "unused", "--owner-id", OWNER]), \
                patch.object(guard, "check_owner", side_effect=ValueError("mismatch")), \
                patch.object(guard, "run") as run, self.assertRaises(ValueError):
            guard.main()
        run.assert_not_called()

    def test_record_roundtrip_and_replay_rejected_with_fake_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "config").mkdir()
            (root / ".local").mkdir()
            (root / "config/kind.yaml").write_bytes(b"config")
            (root / "versions.json").write_text(json.dumps({"kind": {"nodeImage": IMAGE}}))
            argv = ["guard", "record", "--root", str(root), "--owner-id", OWNER]
            with patch.object(guard.sys, "argv", argv), patch.object(guard, "check_owner"), \
                    patch.object(guard, "inspect_containers", return_value=containers()):
                guard.main()
                state = json.loads((root / ".local/cluster.json").read_text())
                self.assertEqual(guard.cluster_status(containers(), state,
                                 guard.fingerprint(b"config", IMAGE), OWNER, IMAGE), "existing")
                with self.assertRaises(ValueError):
                    guard.main()

    def test_declared_pin_and_config_integrity(self):
        pins = json.loads((ROOT / "versions.json").read_text())
        for name in ("kind", "kubectl", "ansible"):
            self.assertRegex(pins[name]["sha256"], r"^[0-9a-f]{64}$")
            self.assertTrue(pins[name]["url"].startswith("https://"))
        self.assertIn("@sha256:", pins["kind"]["nodeImage"])
        lock = (ROOT / "ansible/requirements.lock").read_text()
        self.assertIn("ansible-core==" + pins["ansible"]["version"], lock)
        self.assertIn(pins["ansible"]["sha256"], lock)
        self.assertEqual(len([line for line in lock.splitlines() if "--hash=sha256:" in line]), 9)
        config = (ROOT / "config/kind.yaml").read_text()
        for expected in ('apiServerAddress: "127.0.0.1"', "apiServerPort: 16443", "hostPort: 18080", "containerPort: 30080"):
            self.assertIn(expected, config)
        self.assertEqual(config.count("role: control-plane"), 1)
        self.assertEqual(config.count("role: worker"), 1)
        self.assertIn(pins["smoke"]["image"], (ROOT / "examples/smoke/app.yaml").read_text())


if __name__ == "__main__":
    unittest.main()
