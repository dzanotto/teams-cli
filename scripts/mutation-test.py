#!/usr/bin/env python3
"""Run the scoped Swift mutation checks without modifying the working tree."""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def run(command, cwd, log, timeout, environment=None):
    with log.open("w") as output:
        process = subprocess.Popen(command, cwd=cwd, env=environment, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except BaseException:
            # Stop the runner and its build/test children before deleting the copy.
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            raise
    if code:
        raise RuntimeError(f"Command exited {code}; see {log}")


def install_tool(config, cache, workspace):
    version = config["tool_version"]
    name = f"swift-mutation-testing-v{version}-macos.tar.gz"
    archive = cache / name
    if not archive.exists():
        url = f"https://github.com/ericodx/swift-mutation-testing/releases/download/v{version}/{name}"
        print(f"Downloading swift-mutation-testing {version}...", flush=True)
        with tempfile.TemporaryDirectory(dir=cache, prefix="download-") as directory:
            download = Path(directory) / name
            subprocess.run(["/usr/bin/curl", "--fail", "--location", "--silent",
                            "--show-error", "--proto", "=https", "--connect-timeout", "15",
                            "--max-time", "120", "--output", str(download), url],
                           check=True, timeout=130)
            if digest(download) != config["archive_sha256"]:
                raise RuntimeError("Downloaded mutation tool failed its SHA-256 check")
            download.replace(archive)
    if digest(archive) != config["archive_sha256"]:
        raise RuntimeError(f"Cached archive failed its SHA-256 check; remove {archive} and retry")
    # Extract only the expected regular file, without trusting archive paths or links.
    binary = workspace / "swift-mutation-testing"
    with tarfile.open(archive) as bundle:
        members = bundle.getmembers()
        if len(members) != 1 or members[0].name != binary.name or not members[0].isfile():
            raise RuntimeError("Unexpected mutation tool archive contents")
        with bundle.extractfile(members[0]) as source, binary.open("wb") as output:
            shutil.copyfileobj(source, output)
    binary.chmod(0o755)
    version_text = subprocess.check_output([str(binary), "--version"], text=True, timeout=10).strip()
    if not version_text.startswith(f"swift-mutation-testing {version} "):
        raise RuntimeError(f"Unexpected tool version: {version_text}")
    return binary, version_text


def snapshot(repo, project, config):
    project.mkdir()
    for name in ("Sources", "Tests"):
        shutil.copytree(repo / name, project / name)
    for name in ("Package.swift", "Package.resolved"):
        if (repo / name).exists():
            shutil.copy2(repo / name, project / name)
    scope = set(config["source_files"])
    source_paths = {p.relative_to(project).as_posix() for p in (project / "Sources/TeamsCore").rglob("*.swift")}
    if not scope or not scope <= source_paths:
        raise RuntimeError("Mutation scope must name existing Swift files under Sources/TeamsCore")
    # Generate exclusions from an allowlist so adding a source file cannot expand scope.
    lines = ["test-target: TeamsCoreTests", "testing-framework: xctest",
             "sources-path: Sources/TeamsCore", "concurrency: 1", "no-cache: true",
             "no-warm-sandbox: true", "timing: true",
             f"timeout: {config['test_timeout_seconds']}",
             f"build-timeout: {config['build_timeout_seconds']}",
             "operators: " + ", ".join(config["operators"]), "exclude:"]
    lines.extend("  - " + json.dumps(path) for path in sorted(source_paths - scope))
    (project / ".swift-mutation-testing.yml").write_text("\n".join(lines) + "\n")
    return {p.relative_to(project).as_posix(): digest(p)
            for p in sorted(project.rglob("*")) if p.is_file()}


def summarize(report, plan):
    planned_files = {item["path"] for item in plan["files"]}
    if {name.lstrip("/") for name in report["files"]} != planned_files:
        raise RuntimeError("Report files do not match the mutation plan")
    mutants = [m for file in report["files"].values() for m in file["mutants"]]
    planned = Counter((m["file"], m["fingerprint"]) for m in plan["mutants"])
    reported = Counter((name.lstrip("/"), m["fingerprint"])
                       for name, file in report["files"].items() for m in file["mutants"])
    if planned != reported or any(count != 1 for count in planned.values()):
        raise RuntimeError("The report does not account for every planned mutation")
    counts = Counter(m["status"] for m in mutants)
    if counts.keys() - {"Killed", "Survived", "CompileError", "Timeout", "NoCoverage"}:
        raise RuntimeError(f"Unexpected mutation statuses: {dict(counts)}")
    executable = len(mutants) - counts["CompileError"]
    if not executable:
        raise RuntimeError("No executable mutations; no meaningful score is available")
    return {
        "counts": {status: counts[status] for status in
                   ("Killed", "Survived", "CompileError", "Timeout", "NoCoverage")},
        "score_percent": 100 * (counts["Killed"] + counts["Timeout"]) / executable,
        "integrity_warnings": sum(m["status"] in ("Killed", "Timeout") and not m.get("activated")
                                  for m in mutants),
    }


def read_report(reports):
    plan_path = reports / "plan.json"
    plan = json.loads(plan_path.read_text())
    report = json.loads((reports / "mutation-report.json").read_text())
    if report["config"]["planSha256"] != digest(plan_path):
        raise RuntimeError("Report plan checksum does not match this run")
    html = reports / "mutation-report.html"
    if not html.is_file() or not html.stat().st_size:
        raise RuntimeError("Missing or empty HTML mutation report")
    return summarize(report, plan)


def main():
    parser = argparse.ArgumentParser(
        description="Run the report-only, scoped mutation check using an isolated package copy.",
        epilog="Requires Apple Silicon macOS 15+, Python 3.9+, and a working Swift/Xcode toolchain. "
               "The first run downloads the pinned tool. Reports are saved under .build/mutation-testing/runs/.")
    parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("The pinned mutation-tool binary requires Apple Silicon macOS")
    if int(platform.mac_ver()[0].split(".")[0]) < 15:
        parser.error("The pinned mutation-tool binary requires macOS 15 or later")
    repo = Path(__file__).resolve().parent.parent
    config = json.loads((repo / "scripts/mutation-test.json").read_text())
    cache = repo / ".build/mutation-testing/tools"
    runs = repo / ".build/mutation-testing/runs"
    cache.mkdir(parents=True, exist_ok=True)
    runs.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
    reports = Path(tempfile.mkdtemp(prefix=stamp, dir=runs))
    metadata = {"status": "running", "configuration": config,
                "git_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
                "git_status": subprocess.check_output(["git", "status", "--porcelain"], cwd=repo, text=True),
                "swift_version": subprocess.check_output(["swift", "--version"], text=True,
                                                         stderr=subprocess.STDOUT).strip()}
    started = time.monotonic()
    print(f"Reports: {reports}", flush=True)
    try:
        # Do not put this copy under .build: the tool excludes such paths.
        with tempfile.TemporaryDirectory(prefix="teams-cli-mutation-") as directory:
            workspace = Path(directory)
            binary, metadata["tool_version"] = install_tool(config, cache, workspace)
            project = workspace / "project"
            metadata["snapshot_sha256"] = snapshot(repo, project, config)
            with tarfile.open(reports / "source-snapshot.tar.gz", "w:gz") as archive:
                for item in sorted(project.iterdir()):
                    archive.add(item, arcname=item.name)
            shutil.copy2(project / ".swift-mutation-testing.yml", reports / "configuration.yml")
            # Keep the tool's own sandboxes inside our cleanup boundary too.
            tool_temp = workspace / "tmp"
            tool_temp.mkdir()
            environment = dict(os.environ, TMPDIR=str(tool_temp) + "/")
            plan_path = reports / "plan.json"
            run([str(binary), "plan", ".", "--output", str(plan_path)], project,
                reports / "discovery.log", 30, environment)
            plan = json.loads(plan_path.read_text())
            if (plan["project"].get("testTarget") != "TeamsCoreTests" or not plan["mutants"]
                    or {f["path"] for f in plan["files"]} != set(config["source_files"])):
                raise RuntimeError("Discovered mutation plan does not match the configured scope")
            command = [str(binary), "run", ".", "--plan", str(plan_path),
                       "--output", str(reports / "mutation-report.json"),
                       "--html-output", str(reports / "mutation-report.html"),
                       "--keep-logs", str(reports / "logs")]
            metadata["command"] = command
            write_json(reports / "run.json", metadata)
            print(f"Running {len(plan['mutants'])} mutations; output: {reports / 'run.log'}", flush=True)
            run(command, project, reports / "run.log", config["run_timeout_seconds"], environment)
            result = read_report(reports)
            write_json(reports / "summary.json", result)
            metadata["status"] = "completed"
            print(json.dumps(result, indent=2), flush=True)
    except BaseException as error:
        metadata.update(status="failed", error=str(error))
        raise
    finally:
        metadata["elapsed_seconds"] = time.monotonic() - started
        write_json(reports / "run.json", metadata)
        print(f"Reports retained at {reports}", flush=True)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"Mutation check failed: {error}", file=sys.stderr)
        sys.exit(1)
