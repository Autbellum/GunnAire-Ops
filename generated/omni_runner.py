#!/usr/bin/env python3
"""omni_runner.py - local compilation and verification pipeline.

Adapted to this repository: the iOS branch uses the .xcodeproj (there is no
workspace), runs the clean build against a simulator destination and reports
the warning count, since the standing rule for this app is zero warnings.
"""
import os
import subprocess
import sys


def log_status(message, step_type="info"):
    markers = {"info": "ℹ️", "success": "✅", "error": "❌", "working": "⚙️"}
    print(f"{markers.get(step_type, '•')} {message}", flush=True)


def detect_project_type():
    files = os.listdir('.')
    if "GunnAire Ops.xcworkspace" in files or "GunnAire Ops.xcodeproj" in files or any(f.endswith('.swift') for f in files):
        return "ios_swift"
    if "package.json" in files:
        return "node_js"
    if "requirements.txt" in files or "Pipfile" in files or "pyproject.toml" in files:
        return "python"
    if "go.mod" in files:
        return "go"
    if "Dockerfile" in files:
        return "docker"
    return "generic"


def run_step(command, description):
    log_status(f"Starting: {description}", "working")
    result = subprocess.run(command, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if result.returncode == 0:
        log_status(f"Completed: {description}", "success")
        return True, result.stdout
    log_status(f"Failed: {description}", "error")
    lines = [l for l in result.stdout.splitlines() if "error:" in l or "warning:" in l]
    print("--- ERROR OUTPUT ---\n" + "\n".join(sorted(set(lines))[:40]) + "\n--------------------")
    return False, result.stdout


def main():
    os.chdir(os.path.dirname(os.path.abspath(__file__)) + "/..")
    project_type = detect_project_type()
    log_status(f"Detected project archetype: {project_type.upper()}", "info")
    success = True

    if project_type == "ios_swift":
        derived = os.environ.get("DERIVED_DATA", os.path.join(os.environ.get("TMPDIR", "/tmp"), "omni-runner-dd"))
        base = f"xcodebuild -project 'GunnAire Ops.xcodeproj' -scheme 'GunnAire Ops' -derivedDataPath '{derived}'"
        success, _ = run_step(f"{base} clean -quiet", "Cleaning iOS Build Cache")
        if success:
            success, output = run_step(
                f"{base} build -configuration Debug -destination 'generic/platform=iOS Simulator'",
                "Compiling App Matrix (Sim)")
            if success:
                warnings = sorted(set(l.split("GunnAire-Ops/")[-1] for l in output.splitlines() if "warning:" in l))
                if warnings:
                    log_status(f"{len(warnings)} compiler warning(s); the standing rule for this app is zero:", "error")
                    print("\n".join(warnings[:40]))
                    success = False
                else:
                    log_status("Zero compiler warnings", "success")
    elif project_type == "node_js":
        success, _ = run_step("npm install", "Resolving Node Dependency Graph")
        if success:
            success, _ = run_step("npm run lint --if-present", "Enforcing Code Quality & Style Rules")
        if success:
            success, _ = run_step("npm test --if-present", "Executing Deterministic Integration Tests")
    elif project_type == "python":
        success, _ = run_step("pip install -r requirements.txt --quiet", "Hydrating Virtual Environment Caches")
        if success:
            success, _ = run_step("mypy . --ignore-missing-imports", "Verifying Strict Static Type System")
        if success:
            success, _ = run_step("pytest", "Executing PyTest Verification Matrix")
    elif project_type == "docker":
        success, _ = run_step("docker compose up -d --build", "Spinning Up Local Container Network")
        if success:
            success, _ = run_step("docker compose ps", "Verifying Container Network Health Diagnostics")
    else:
        log_status("Generic project detected. Attempting global optimization rules...", "info")
        if os.path.exists("Makefile"):
            success, _ = run_step("make test", "Executing Makefile Test Targets")
        else:
            log_status("No structural build manifests found. Awaiting agent directives.", "error")
            sys.exit(1)

    if success:
        log_status("🎉 SYSTEM COMPILED CLEANLY WITH ZERO CRITICAL THROTTLING ERROR MARGINS!", "success")
        sys.exit(0)
    log_status("🚨 PIPELINE CRASHED. Refactoring protocol required.", "error")
    sys.exit(1)


if __name__ == "__main__":
    main()
