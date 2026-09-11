#!/usr/bin/env python3
"""Build current app sources and run private, watchdog-bounded diff UI checks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import selectors
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[2]
BUILD = REPO / ".scratch/diff-inspector-tests"
APP = BUILD / "OrchestraDiffChecks.app"
BINARY = APP / "Contents/MacOS/OrchestraDiffChecks"


def app_sources():
    return (sorted((REPO / "App").glob("*.swift"))
            + sorted((REPO / "App/Views").glob("*.swift"))
            + sorted((REPO / "Tests/AppTests").glob("*.swift")))


def source_hashes():
    paths = app_sources() + [REPO / "Package.swift", REPO / "Package.resolved"]
    for module in ["OrchestraKit", "OrchestraCore", "OrchestraUI"]:
        paths += sorted(p for p in (REPO / "Sources" / module).rglob("*") if p.is_file())
    return {str(p.relative_to(REPO)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def build(args):
    # The parent invocation holds the machine-wide build lock for this entire function.
    fingerprints = source_hashes()
    subprocess.run(["xcrun", "swift", "build", "--target", "OrchestraUI", "-c", "release",
                    "-Xswiftc", "-enable-testing"], cwd=REPO, check=True)
    products = Path(subprocess.check_output([
        "xcrun", "swift", "build", "-c", "release", "--show-bin-path"], cwd=REPO, text=True).strip())
    sources = app_sources()
    objects = []
    for module in ["OrchestraKit", "OrchestraCore", "OrchestraUI"]:
        found = sorted((products / (module + ".build")).glob("*.o"))
        if not found:
            raise RuntimeError(f"No linkable objects for {module} under {products}")
        objects.extend(found)
    BINARY.parent.mkdir(parents=True, exist_ok=True)
    command = ["xcrun", "swiftc", "-swift-version", "6", "-O", "-whole-module-optimization", "-g",
               "-D", "ORCHESTRA_DIFF_CHECKS",
               "-target", f"{platform.machine()}-apple-macosx14.0", "-I", str(products / "Modules"),
               "-module-cache-path", str(BUILD / "module-cache"), "-module-name", "OrchestraDiffChecks"]
    if args.swiftterm_products:
        term = Path(args.swiftterm_products).resolve()
        command += ["-I", str(term), str(term / "SwiftTerm.o"), "-lutil"]
    command += list(map(str, sources + objects)) + ["-o", str(BINARY)]
    # Swift can leave intermediate module/debug files in its working directory on a failed build.
    subprocess.run(command, cwd=BUILD, check=True)
    if source_hashes() != fingerprints:
        raise RuntimeError("App sources changed during compilation; rebuild before running the checks")
    info = {"CFBundleIdentifier": "com.orchestra.tests.diff-inspector", "CFBundleExecutable": BINARY.name,
            "CFBundleName": "Orchestra Diff Checks", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True}
    (APP / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(APP)], check=True)
    manifest = {"command": command, "swiftterm": args.swiftterm_products,
                "sources": fingerprints,
                "binary_sha256": hashlib.sha256(BINARY.read_bytes()).hexdigest()}
    (BUILD / "build.json").write_text(json.dumps(manifest, indent=2) + "\n")


def fixture(count):
    sections = []
    for i in range(count):
        rows = 2 + (i * 7) % 5 + (80 if i % 17 == 0 else 0)
        body = "".join(f" value_{j} = {j}\n" for j in range(rows))
        if i % 19 == 0:
            body += " " + "long_line " * 160 + "\n"
            rows += 1
        sections.append(f"diff --git a/file-{i}.swift b/file-{i}.swift\n"
                        f"--- a/file-{i}.swift\n+++ b/file-{i}.swift\n"
                        f"@@ -1,{rows + 1} +1,{rows + 1} @@\n{body}-previous\n+updated\n")
    result = "".join(sections)
    if len(result.encode()) > 256 * 1024:
        raise ValueError("Synthetic fixture exceeds the application's diff cap; use fewer files")
    return result


def run(args):
    if not BINARY.is_file():
        raise RuntimeError("Test executable is missing; rerun without --skip-build")
    manifest = json.loads((BUILD / "build.json").read_text())
    if manifest["sources"] != source_hashes():
        raise RuntimeError("App or test sources changed; rerun without --skip-build")
    if args.mode != "checks":
        session = subprocess.run(["/usr/sbin/ioreg", "-n", "Root", "-d", "1"],
                                 capture_output=True, text=True, check=True).stdout
        if re.search(r'"CGSSessionScreenIsLocked"\s*=\s*Yes', session):
            raise RuntimeError("Native scrolling tests need an unlocked macOS desktop; the screen is locked")
    label = args.label or time.strftime("%Y%m%d-%H%M%S") + f"-{args.mode}-{args.files}"
    if Path(label).name != label or label in (".", ".."):
        raise ValueError("--label must be a single directory name")
    output = BUILD / "runs" / label
    output.mkdir(parents=True, exist_ok=False)
    patch = Path(args.fixture).resolve() if args.fixture else output / "fixture.diff"
    if not args.fixture:
        patch.write_text(fixture(args.files))
    command = [str(BINARY), "--mode", args.mode, "--fixture", str(patch), "--gesture", args.gesture,
               "--cycles", str(args.cycles), "--files", str(args.files),
               "--artifact-dir", str(output),
               "-inspectorWidth", "850.34765625"]
    if args.split:
        command.append("--split")
    if args.churn:
        command.append("--churn")
    metadata = {"command": command, "start_unix": time.time(),
                "binary_sha256": hashlib.sha256(BINARY.read_bytes()).hexdigest(),
                "fixture_sha256": hashlib.sha256(patch.read_bytes()).hexdigest()}
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    started = last_heartbeat = time.monotonic()
    pending = b""
    events = []
    failure = None
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    print(f"RUN {label}: private pid {process.pid}", flush=True)

    def consume(line):
        nonlocal last_heartbeat
        if line.startswith("[DIFF-CHECK] {"):
            event = json.loads(line[len("[DIFF-CHECK] "):])
            events.append(event)
            last_heartbeat = time.monotonic()
            if event.get("event") != "heartbeat":
                print(json.dumps(event, sort_keys=True), flush=True)

    try:
        with (output / "stdout.log").open("w") as log:
            while process.poll() is None:
                for key, _ in selector.select(timeout=0.1):
                    block = os.read(key.fileobj.fileno(), 65536)
                    if not block:
                        selector.unregister(key.fileobj)
                        continue
                    pending += block
                    while b"\n" in pending:
                        raw, pending = pending.split(b"\n", 1)
                        line = raw.decode(errors="replace")
                        log.write(line + "\n")
                        log.flush()
                        consume(line)
                now = time.monotonic()
                if now - last_heartbeat > args.stall_timeout or now - started > args.timeout:
                    failure = "main-loop watchdog" if now - last_heartbeat > args.stall_timeout else "total time limit"
                    try:
                        subprocess.run(["/usr/bin/sample", str(process.pid), "2", "1", "-file",
                                        str(output / "hang.sample.txt")], capture_output=True, timeout=8)
                    except subprocess.TimeoutExpired:
                        pass
                    break
            if process.poll() is not None:
                tail = (pending + process.stdout.read()).decode(errors="replace")
                log.write(tail)
                for line in tail.splitlines():
                    consume(line)
    finally:
        selector.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        process.stdout.close()
    passed = not failure and process.returncode == 0 and any(e.get("event") == "pass" for e in events)
    result = {"passed": passed, "failure": failure, "exit_code": process.returncode, "events": events}
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"{'PASS' if passed else 'FAIL'}: {output}", flush=True)
    return 0 if passed else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--_build", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--swiftterm-products", help="Optional matching Xcode Release products containing SwiftTerm.o")
    parser.add_argument("--mode", choices=["checks", "scroll", "benchmark", "inspect"], default="checks")
    parser.add_argument("--fixture")
    parser.add_argument("--files", type=int, default=12)
    parser.add_argument("--gesture", choices=["knob", "wheel"], default="knob")
    parser.add_argument("--cycles", type=int, default=3)
    parser.add_argument("--split", action="store_true")
    parser.add_argument("--churn", action="store_true")
    parser.add_argument("--label")
    parser.add_argument("--stall-timeout", type=float, default=12)
    parser.add_argument("--timeout", type=float, default=90)
    args = parser.parse_args()
    if args.files < 1 or args.cycles < 1 or args.stall_timeout <= 0 or args.timeout <= 0:
        parser.error("Counts and timeouts must be positive")
    if args._build:
        build(args)
        return 0
    if not args.skip_build:
        command = [str(REPO / "scripts/lib/with-lock.sh"), "build", "--", sys.executable, __file__, "--_build"]
        if args.swiftterm_products:
            command += ["--swiftterm-products", args.swiftterm_products]
        subprocess.run(command, cwd=REPO, check=True)
    return 0 if args.build_only else run(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        print(f"Build command failed with exit status {error.returncode}", file=sys.stderr)
        sys.exit(error.returncode)
    except (RuntimeError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
