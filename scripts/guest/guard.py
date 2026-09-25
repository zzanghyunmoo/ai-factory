"""Small stdlib safety checks; Ansible owns installation and cluster convergence."""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import uuid
from pathlib import Path

NAMES = {"infra-control-plane": "control-plane", "infra-worker": "worker"}


def parse_json(text):
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        raise ValueError("Invalid JSON in infra input or command output.") from error


def check_owner(marker, owner):
    uuid.UUID(owner)
    data = parse_json(Path(marker).read_text())
    if data.get("owner") != owner or data.get("name") != "infra":
        raise ValueError("Guest ownership mismatch; refusing changes.")


def fingerprint(config, image):
    return hashlib.sha256(config + b"\0" + image.encode()).hexdigest()


def run(args):
    # Never include subprocess output in errors: kubeconfig may contain private keys.
    result = subprocess.run(args, capture_output=True, text=True, timeout=30, check=False)
    if result.returncode:
        raise ValueError("Guest check failed: " + args[0])
    return result.stdout.strip()


def inspect_containers():
    ids = run(["docker", "ps", "-aq"]).split()
    if not ids:
        return []
    all_containers = parse_json(run(["docker", "inspect", *ids]))
    return [node for node in all_containers
            if node["Name"].lstrip("/") in NAMES
            or (node["Config"].get("Labels") or {}).get("io.x-k8s.kind.cluster") == "infra"]


def check_containers(nodes, image, *, allow_stopped=False):
    if len(nodes) != 2 or {n["Name"].lstrip("/") for n in nodes} != set(NAMES):
        raise ValueError("Foreign/partial infra containers; inspect manually, never auto-recreate.")
    for node in nodes:
        name = node["Name"].lstrip("/")
        labels = node["Config"].get("Labels") or {}
        if (node["Config"]["Image"] != image
                or labels.get("io.x-k8s.kind.cluster") != "infra"
                or labels.get("io.x-k8s.kind.role") != NAMES[name]
                or (not allow_stopped and not node["State"]["Running"])):
            raise ValueError("Actual infra container image/role/running state mismatch.")
        expected_ports = ({"6443/tcp": [{"HostIp": "127.0.0.1", "HostPort": "16443"}],
                           "30080/tcp": [{"HostIp": "127.0.0.1", "HostPort": "18080"}]}
                          if name == "infra-control-plane" else {})
        if (node["HostConfig"].get("PortBindings") or {}) != expected_ports:
            raise ValueError("Actual infra loopback port bindings mismatch.")


def make_record(nodes, digest, owner):
    return {"owner": owner, "fingerprint": digest,
            "containers": {n["Name"].lstrip("/"): n["Id"] for n in nodes}}


def cluster_status(nodes, record, digest, owner, image, *, allow_stopped=False):
    if not nodes:
        if record is not None:
            raise ValueError("Recorded infra cluster is missing; manual investigation required.")
        return "absent"
    check_containers(nodes, image, allow_stopped=allow_stopped)
    if record != make_record(nodes, digest, owner):
        raise ValueError("Missing/changed cluster fingerprint or identity; no adoption or replacement.")
    return "existing" if all(node["State"]["Running"] for node in nodes) else "stopped"


def check_nodes(data, version):
    nodes = data.get("items", [])
    if len(nodes) != 2 or {n["metadata"]["name"] for n in nodes} != set(NAMES):
        raise ValueError("Expected exactly infra-control-plane and infra-worker.")
    for node in nodes:
        if (node["status"]["nodeInfo"]["kubeletVersion"] != "v" + version
                or not any(c["type"] == "Ready" and c["status"] == "True"
                           for c in node["status"].get("conditions", []))):
            raise ValueError("Expected two Ready nodes at the declared Kubernetes version.")


def check_versions(root, pins):
    for name in ("kind", "kubectl"):
        binary = Path("/usr/local/bin") / name
        if hashlib.sha256(binary.read_bytes()).hexdigest() != pins[name]["sha256"]:
            raise ValueError("Installed " + name + " checksum mismatch.")
    for name, version in pins["docker"]["packages"].items():
        actual = run(["dpkg-query", "-W", "-f=${Status} ${Version}", name])
        if actual != "install ok installed " + version:
            raise ValueError("Installed Docker package mismatch: " + name)
    actual = run([str(root / ".venv/bin/python"), "-c",
                  "import importlib.metadata; print(importlib.metadata.version('ansible-core'))"])
    if actual != pins["ansible"]["version"]:
        raise ValueError("Installed Ansible version mismatch.")
    expected_engine = pins["docker"]["packages"]["docker-ce"].split(":", 1)[-1].split("-", 1)[0]
    if run(["docker", "version", "--format", "{{.Server.Version}}"]) != expected_engine:
        raise ValueError("Running Docker daemon version mismatch; inspect service restart status.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["owner", "preflight", "record", "nodes", "versions"])
    parser.add_argument("--root", required=True)
    parser.add_argument("--owner-id", required=True)
    parser.add_argument("--allow-stopped", action="store_true")
    args = parser.parse_args()
    check_owner("/etc/infra-owner.json", args.owner_id)
    if args.action == "owner":
        return
    root = Path(args.root)
    pins = parse_json((root / "versions.json").read_text())
    if args.action == "versions":
        check_versions(root, pins)
        return
    if args.action == "nodes":
        data = run(["kubectl", "--kubeconfig", str(root / ".local/kubeconfig"),
                    "--request-timeout=20s", "get", "nodes", "-o", "json"])
        check_nodes(parse_json(data), pins["kubectl"]["version"])
        return
    digest = fingerprint((root / "config/kind.yaml").read_bytes(), pins["kind"]["nodeImage"])
    state_path = root / ".local/cluster.json"
    record = parse_json(state_path.read_text()) if state_path.exists() else None
    nodes = inspect_containers()
    if args.action == "preflight":
        print(cluster_status(nodes, record, digest, args.owner_id, pins["kind"]["nodeImage"],
                             allow_stopped=args.allow_stopped))
    else:
        if record is not None:
            raise ValueError("Refusing to overwrite cluster ownership record.")
        check_containers(nodes, pins["kind"]["nodeImage"])
        # Caller runs this only after successful create and node readiness. Atomic, mode 0600.
        temporary = state_path.with_suffix(".pending")
        with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
            json.dump(make_record(nodes, digest, args.owner_id), stream)
        temporary.replace(state_path)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        # Exceptions from JSON parsing/filesystem checks never contain command stdout.
        print("infra: " + str(error), file=sys.stderr)
        sys.exit(4)
