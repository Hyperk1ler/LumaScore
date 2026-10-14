#!/usr/bin/env python3
"""Package a trusted Homebrew FFmpeg bottle and its ABI-matching dependencies.

This copies and relocates files inside the project only. No system installation,
PATH fallback or incompatible library-name shims are used. The resulting app
runtime requires the highest minimum macOS version of the packaged binaries.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def dependencies(path):
    return [line.strip().split(" (compatibility", 1)[0]
            for line in run("/usr/bin/otool", "-L", str(path)).splitlines()[1:]]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg-prefix", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prefix = args.ffmpeg_prefix.resolve()
    destination = args.output.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "lib").mkdir(exist_ok=True)
    queue = [prefix / "bin/ffmpeg", prefix / "bin/ffprobe"]
    copied = {}
    package_roots = {prefix}
    reports = []
    while queue:
        source = queue.pop(0).resolve()
        if source.name in copied:
            if digest(source) != copied[source.name]["originalSHA256"]:
                raise RuntimeError("Conflicting library filename: " + source.name)
            continue
        if not source.is_file():
            raise RuntimeError("ABI-matching dependency missing: " + str(source))
        is_library = source.suffix == ".dylib"
        target = destination / ("lib" if is_library else "") / source.name
        if target.exists():
            target.unlink()
        shutil.copy2(source, target)
        target.chmod(0o755)
        metadata = {"name": source.name, "originalSHA256": digest(source)}
        copied[source.name] = metadata
        load_commands = run("/usr/bin/otool", "-l", str(source))
        minimum = re.search(r"\bminos\s+([\d.]+)", load_commands)
        metadata["minimumMacOS"] = minimum.group(1) if minimum else "unspecified"
        for reference in dependencies(source):
            if reference.startswith(("/usr/lib/", "/System/Library/")):
                continue
            resolved = reference.replace("@@HOMEBREW_PREFIX@@/opt/ffmpeg", str(prefix))
            resolved = resolved.replace("@@HOMEBREW_PREFIX@@", "/opt/homebrew")
            resolved = resolved.replace("@@HOMEBREW_CELLAR@@/ffmpeg/" + prefix.name, str(prefix))
            resolved = resolved.replace("@@HOMEBREW_CELLAR@@", "/opt/homebrew/Cellar")
            child = Path(resolved).resolve()
            if not child.is_file():
                raise RuntimeError("ABI-matching dependency missing: " + reference)
            relative = "@loader_path/" + ("" if is_library else "lib/") + child.name
            subprocess.check_call(["/usr/bin/install_name_tool", "-change", reference, relative, str(target)])
            if child.name != source.name:
                queue.append(child)
            if "/Cellar/" in str(child):
                components = child.parts
                cellar = components.index("Cellar")
                package_roots.add(Path(*components[:cellar + 3]))
        if is_library:
            subprocess.check_call(["/usr/bin/install_name_tool", "-id", "@loader_path/" + source.name, str(target)])
        subprocess.check_call(["/usr/bin/codesign", "--force", "--sign", "-", str(target)])
        metadata["packagedSHA256"] = digest(target)
        metadata["dependencies"] = dependencies(target)
        if any(dep.startswith(("/opt/", "@@")) for dep in metadata["dependencies"]):
            raise RuntimeError("Non-portable dependency remains in " + str(target))

    licenses = destination / "Licenses"
    licenses.mkdir(exist_ok=True)
    for package in sorted(package_roots):
        name = package.parent.name
        version = package.name
        folder = licenses / (name + "-" + version)
        folder.mkdir(exist_ok=True)
        copied_license = False
        for pattern in ("LICENSE*", "COPYING*", "NOTICE*", "PATENTS*"):
            for item in package.glob(pattern):
                if item.is_file():
                    shutil.copy2(item, folder / item.name)
                    copied_license = True
        formula = package / ".brew" / (name + ".rb")
        report = {"package": name, "version": version}
        if formula.is_file():
            shutil.copy2(formula, folder / "homebrew-formula.rb")
            text = formula.read_text()
            url = re.search(r'^\s*url "([^"]+)"', text, re.M)
            checksum = re.search(r'^\s*sha256 "([^"]+)"', text, re.M)
            license_line = re.search(r'^\s*license (.+)$', text, re.M)
            if url:
                report["sourceURL"] = url.group(1)
            if checksum:
                report["sourceSHA256"] = checksum.group(1)
            if license_line:
                report["license"] = license_line.group(1)
        if not copied_license:
            raise RuntimeError("License text missing for " + str(package))
        reports.append(report)
    manifest = {"runtime": "Homebrew FFmpeg bottle, relocated as a separate executable",
                "architecture": "arm64", "binaries": list(copied.values()), "sourcePackages": reports}
    (destination / "provenance.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(run(str(destination / "ffmpeg"), "-version"))
    print("Packaged", len(copied), "binaries with licenses and source provenance in", destination)


if __name__ == "__main__":
    main()
