#!/usr/bin/env python3
"""Exercise the OKD wrapper with a fake oc, without network or credentials."""

import json
import os
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


FAKE_OC_SOURCE = r'''
import json
import os
import sys
import time
from pathlib import Path

root = Path(os.environ["OKD_TEST_DIRECTORY"])
arguments = sys.argv[1:]
scenario = os.environ["OKD_TEST_SCENARIO"]
if arguments == ["port-forward", "--help"]:
    (root / "child-pid").write_text(str(os.getpid()))
    (root / "checking-help").touch()
    while not (root / "release-help").exists():
        time.sleep(0.02)
    print("--address string" if scenario == "modern" else "--pod-running-timeout duration")
    sys.exit(0)
if "get" in arguments:
    if scenario == "parent-discovery":
        (root / "child-pid").write_text(str(os.getpid()))
        (root / "discovery-stalled").touch()
        while True:
            time.sleep(0.02)
    print("test-proxy-pod")
    sys.exit(0)
assert "port-forward" in arguments
assert ("--address" in arguments) == (scenario == "modern")
if "--address" in arguments:
    assert arguments[arguments.index("--address") + 1] == "127.0.0.1"
assert arguments[-2:] == ["15424", "15427"]
assert not any("synthetic-test-token" in argument for argument in arguments)
count_path = root / "attempt-count"
attempt = int(count_path.read_text()) + 1 if count_path.exists() else 1
count_path.write_text(str(attempt))
(root / "child-pid").write_text(str(os.getpid()))
(root / f"arguments-{attempt}.json").write_text(json.dumps(arguments))
if scenario == "failure":
    print("synthetic port-forward failure", flush=True)
    (root / f"failed-{attempt}").touch()
    sys.exit(1)
print("Forwarding from 127.0.0.1:15424 -> 15424", flush=True)
print("Forwarding from 127.0.0.1:15424 -> 15424", flush=True)
print("Forwarding from [::1]:15427 -> 15427", flush=True)
(root / f"partial-{attempt}").touch()
while not (root / f"release-partial-{attempt}").exists():
    time.sleep(0.02)
print("Forwarding from 127.0.0.1:15427 -> 15427", flush=True)
(root / f"ready-{attempt}").touch()
while not (root / f"release-ready-{attempt}").exists():
    time.sleep(0.02)
sys.exit(1)
'''


SUPERVISOR_SOURCE = '''
import subprocess
import sys

child = subprocess.Popen(sys.argv[1:])
child.wait()
'''


def wait_until(predicate, description):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError(f"Timed out: {description}")


def check_scenario(project_directory, scenario):
    with tempfile.TemporaryDirectory(prefix="okd-proxy-test-", dir=project_directory / "run") as temporary_directory:
        root = Path(temporary_directory)
        executable_directory = root / "bin"
        executable_directory.mkdir()
        fake_oc = executable_directory / "oc"
        fake_oc.write_text(f"#!{sys.executable}\n" + FAKE_OC_SOURCE)
        fake_oc.chmod(0o700)
        configuration = root / "configuration.plist"
        with configuration.open("wb") as configuration_file:
            plistlib.dump({
                "serverURL": "https://okd.example.invalid",
                "token": "synthetic-test-token",
                "namespace": "test-namespace",
                "podSelector": "app=test-proxy",
                "ports": "15424 15427",
            }, configuration_file)
        configuration.chmod(0o600)
        environment = dict(os.environ)
        environment.update({
            "PATH": f"{executable_directory}:/usr/bin:/bin:/usr/sbin:/sbin",
            "BCS_VPN_DATA_DIRECTORY": str(root),
            "OKD_TEST_DIRECTORY": str(root),
            "OKD_TEST_SCENARIO": scenario,
        })
        status_file = root / "run/okd-proxy.status"
        status_file.parent.mkdir()
        status_file.write_text("connected\n")

        def status():
            return status_file.read_text().strip() if status_file.exists() else ""

        with (root / "output.log").open("w+") as output_file:
            command = ["/bin/bash", project_directory / "scripts/okd-proxy.sh", configuration]
            parent_exit_scenario = scenario in ("parent-terminate", "parent-kill", "parent-discovery", "parent-help")
            if parent_exit_scenario:
                command = [sys.executable, "-c", SUPERVISOR_SOURCE, *command]
            process = subprocess.Popen(
                command, env=environment, stdout=output_file, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            scenario_succeeded = False
            try:
                wait_until(lambda: (root / "checking-help").exists(), "CLI compatibility check")
                assert status() == "starting", "Previous run must not supply connected status"
                if scenario != "parent-help":
                    (root / "release-help").touch()
                if scenario in ("parent-help", "parent-discovery"):
                    if scenario == "parent-discovery":
                        wait_until(lambda: (root / "discovery-stalled").exists(), "stalled pod discovery")
                    assert status() == "starting"
                elif scenario == "failure":
                    wait_until(lambda: (root / "failed-1").exists(), "failed attempt")
                    assert status() == "starting", "Failed launch must not be connected"
                    wait_until(lambda: (root / "failed-2").exists(), "failure retry")
                    assert status() == "starting"
                else:
                    wait_until(lambda: (root / "partial-1").exists(), "first listener")
                    assert status() == "starting", "Duplicate/IPv6 messages must not count as all IPv4 listeners"
                    (root / "release-partial-1").touch()
                    wait_until(lambda: status() == "connected", "all IPv4 listeners")
                    arguments = json.loads((root / "arguments-1.json").read_text())
                    assert ("--address" in arguments) == (scenario == "modern")
                    kubeconfig = root / "run/okd-proxy-kubeconfig"
                    assert kubeconfig.stat().st_mode & 0o777 == 0o600
                    if not parent_exit_scenario:
                        (root / "release-ready-1").touch()
                        wait_until(lambda: status() == "starting", "clear disconnected state")
                        wait_until(lambda: (root / "partial-2").exists(), "next attempt")
                        assert status() == "starting", "Previous attempt must not supply readiness"
                child_process_id = int((root / "child-pid").read_text())
                if scenario == "parent-kill":
                    process.kill()
                else:
                    process.terminate()
                process.wait(timeout=5)
                wait_until(lambda: status() == "stopped", "wrapper stops after parent exit")
                assert not (root / "run/okd-proxy-kubeconfig").exists()
                assert not list((root / "run").glob("okd-proxy-output.*"))
                try:
                    os.kill(child_process_id, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError("Port-forward child survived shutdown")
                output_file.seek(0)
                assert "synthetic-test-token" not in output_file.read()
                scenario_succeeded = True
            except Exception:
                output_file.seek(0)
                print(output_file.read(), file=sys.stderr)
                raise
            finally:
                # Once shutdown is verified, do not signal an exited/reused group.
                if not scenario_succeeded:
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=5)
                    if parent_exit_scenario:
                        wait_until(lambda: status() == "stopped", "orphan test cleanup")
        print(f"OKD proxy: {scenario} passed")


if __name__ == "__main__":
    project_directory = Path(__file__).resolve().parent.parent
    (project_directory / "run").mkdir(exist_ok=True)
    for scenario in ("legacy", "modern", "failure", "parent-terminate", "parent-kill", "parent-discovery", "parent-help"):
        check_scenario(project_directory, scenario)
