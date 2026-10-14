#!/usr/bin/env python3
"""Verify and package the pinned sources of the bundled WebM runtime.

Downloads require --download. Offline packaging never silently substitutes a
newer version, accepts an unverified archive, or installs system dependencies.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import urllib.parse
import zipfile


REPO = Path(__file__).resolve().parents[2]
RUNTIME = REPO / "native/Resources/WebMRuntime"


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def filename(package):
    return urllib.parse.urlparse(package["sourceURL"]).path.rsplit("/", 1)[-1]


def download(package, cache):
    target = cache / filename(package)
    if target.is_file() and digest(target) == package["sourceSHA256"]:
        return target
    temporary = target.with_name(target.name + ".part")
    url = package["sourceURL"]
    parts = urllib.parse.urlparse(url).path.strip("/").split("/")
    try:
        if url.startswith("https://github.com/") and "releases/download" in url:
            owner, repository = parts[:2]
            release = json.loads(subprocess.check_output([
                "gh", "api", f"repos/{owner}/{repository}/releases/tags/{parts[4]}"
            ]))
            asset = next(x for x in release["assets"] if x["name"] == parts[5])
            with temporary.open("wb") as stream:
                subprocess.run([
                    "gh", "api", f"repos/{owner}/{repository}/releases/assets/{asset['id']}",
                    "-H", "Accept: application/octet-stream"
                ], stdout=stream, check=True)
        else:
            if url.startswith("https://github.com/") and "archive/refs/tags" in url:
                tag = parts[5].removesuffix(".tar.gz")
                url = f"https://codeload.github.com/{parts[0]}/{parts[1]}/tar.gz/refs/tags/{tag}"
            subprocess.run([
                "curl", "--fail", "--silent", "--show-error", "--http1.1", "--location",
                "--connect-timeout", "20", "--max-time", "120", "--retry", "2",
                "--output", str(temporary), url
            ], check=True)
        if digest(temporary) != package["sourceSHA256"]:
            raise RuntimeError("Source checksum mismatch: " + package["package"])
        temporary.replace(target)
        print("Downloaded and verified", package["package"], flush=True)
        return target
    finally:
        temporary.unlink(missing_ok=True)


def validate_archive(path):
    if not hasattr(tarfile, "data_filter"):
        raise RuntimeError("Use Python 3.12+ (or a patched Python with tarfile.data_filter)")
    with tarfile.open(path) as archive, tempfile.TemporaryDirectory() as destination:
        members = archive.getmembers()
        if not members:
            raise RuntimeError("Empty source archive: " + str(path))
        roots = set()
        for entry in members:
            tarfile.data_filter(entry, destination)
            if entry.name.startswith("/") or ".." in Path(entry.name).parts:
                raise RuntimeError("Unsafe source path: " + entry.name)
            roots.add(Path(entry.name).parts[0])
            if entry.isdev() or entry.isfifo():
                raise RuntimeError("Special file in source archive: " + entry.name)
        if len(roots) != 1:
            raise RuntimeError("Source archive must have one root: " + str(path))
        return len(members)


def verify(packages, cache):
    provenance = json.loads((RUNTIME / "provenance.json").read_text())
    expected = {x["name"] for x in provenance["binaries"]}
    owners = [name for package in packages for name in package["binaries"]]
    if set(owners) != expected or len(owners) != len(expected):
        raise RuntimeError("Every shipped binary must have exactly one source package")
    for binary in provenance["binaries"]:
        relative = ("lib/" if binary["name"].endswith(".dylib") else "") + binary["name"]
        if digest(RUNTIME / relative) != binary["packagedSHA256"]:
            raise RuntimeError("Runtime changed; update the source lock: " + relative)
    results = []
    for package in packages:
        path = cache / filename(package)
        if not path.is_file():
            raise RuntimeError(f"Missing {path.name}; run with --download to fetch pinned sources")
        if digest(path) != package["sourceSHA256"]:
            raise RuntimeError("Source checksum mismatch: " + package["package"])
        result = dict(package, archive="archives/" + path.name,
                      archiveBytes=path.stat().st_size, archiveEntries=validate_archive(path))
        result["formulaSHA256"] = digest(RUNTIME / package["formula"])
        results.append(result)
        print("Verified", package["package"], package["version"], flush=True)
    return results


def write_entry(archive, name, data, executable=False):
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.external_attr = (0o100755 if executable else 0o100644) << 16
    info.compress_type = zipfile.ZIP_STORED if name.endswith((".gz", ".xz", ".bz2")) else zipfile.ZIP_DEFLATED
    archive.writestr(info, data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=REPO / "native/build/corresponding-source/downloads")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    lock = json.loads((RUNTIME / "source-lock.json").read_text())
    if lock["schema"] != 1:
        raise RuntimeError("Unsupported source-lock schema")
    packages = lock["packages"]
    args.cache.mkdir(parents=True, exist_ok=True)
    if args.download:
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda row: download(row, args.cache), packages))
    records = verify(packages, args.cache)
    if args.verify_only:
        print("All sources and shipped binary mappings verified")
        return
    if args.output is None:
        parser.error("--output is required unless --verify-only is used")
    manifest = {
        "schema": 1, "runtime": "LumaScore bundled WebM runtime", "architecture": "arm64",
        "minimumMacOS": "27.0", "packages": records,
        "runtimeProvenanceSHA256": digest(RUNTIME / "provenance.json"),
        "buildScript": "tools/rebuild-webm-runtime.sh",
        "relocationScript": "tools/package-webm-runtime.py",
        "notes": "Pinned upstream sources with recorded packaging patches and original recipes; byte-identical Homebrew bottle reproduction is not claimed."
    }
    entries = {
        "README.md": (REPO / "docs/webm-corresponding-source.md").read_bytes(),
        "source-manifest.json": (json.dumps(manifest, indent=2) + "\n").encode(),
        "provenance.json": (RUNTIME / "provenance.json").read_bytes(),
        "SOURCE_DOWNLOAD.md": (RUNTIME / "SOURCE_DOWNLOAD.md").read_bytes(),
        "tools/rebuild-webm-runtime.sh": (REPO / "native/Tools/rebuild-webm-runtime.sh").read_bytes(),
        "tools/package-webm-runtime.py": (REPO / "native/Tools/package-webm-runtime.py").read_bytes(),
        "tools/LICENSE": (REPO / "LICENSE").read_bytes()
    }
    for directory in ("Licenses", "BuildRecipes", "BuildInfo", "Patches"):
        for path in sorted((RUNTIME / directory).rglob("*")):
            if path.is_file():
                entries[path.relative_to(RUNTIME).as_posix()] = path.read_bytes()
    for package in packages:
        path = args.cache / filename(package)
        entries["archives/" + path.name] = path.read_bytes()
    entries["SHA256SUMS.txt"] = "".join(
        hashlib.sha256(data).hexdigest() + "  " + name + "\n"
        for name, data in sorted(entries.items())
    ).encode()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=args.output.parent, suffix=".zip", delete=False) as stream:
        temporary = Path(stream.name)
    try:
        with zipfile.ZipFile(temporary, "w") as archive:
            for name, data in sorted(entries.items()):
                write_entry(archive, "LumaScore-WebMRuntime-source/" + name, data,
                            executable=name.startswith("tools/") and name.endswith((".sh", ".py")))
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None:
                raise RuntimeError("Generated source ZIP failed integrity check")
        temporary.chmod(0o644)
        temporary.replace(args.output)
    finally:
        temporary.unlink(missing_ok=True)
    print("Packaged", len(packages), "source packages:", args.output)
    print("SHA256", digest(args.output))


if __name__ == "__main__":
    main()
