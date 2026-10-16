#!/usr/bin/env python3
"""Paired, alternating full-export benchmarks using the checked-in media fixtures."""
import argparse
import json
import platform
from pathlib import Path
import statistics
import subprocess


def main():
    native = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=native / "build/DerivedData/Build/Products/Release/LumaScore.app/Contents/MacOS/LumaScore")
    parser.add_argument("--baseline", type=Path, help="Optional older executable; default compares legacy/automatic in the same build")
    parser.add_argument("--output", type=Path, required=True, help="New result directory")
    parser.add_argument("--trials", type=int, default=3)
    parser.add_argument("--keep-video", action="store_true")
    args = parser.parse_args()
    if args.trials < 1:
        parser.error("--trials must be positive")
    args.output.mkdir(parents=True, exist_ok=False)
    app = args.app.resolve()
    midi = str(native / "Fixtures/representative-5s.mid")
    audio = str(native / "Fixtures/representative-5s.wav")
    cases = {
        "midi-1080": ["--midi", midi, "--resolution", "1080", "--glow", "0"],
        "audio-1080": ["--audio", audio, "--scene", "audio", "--template", "Record Sleeve", "--title", "Night Signal", "--resolution", "1080", "--glow", "0.4", "--crt", "--fisheye", "0.3", "--metronome"],
        "hybrid-1080": ["--midi", midi, "--audio", audio, "--scene", "hybrid", "--resolution", "1080", "--glow", "0.4", "--crt"],
        "midi-bloom-4k": ["--midi", midi, "--resolution", "2160", "--glow", "0.4", "--glow-radius", "40", "--fisheye", "0.6"],
    }
    records = []
    for case, options in cases.items():
        for trial in range(args.trials):
            for backend in (["legacy", "automatic"] if trial % 2 == 0 else ["automatic", "legacy"]):
                stem = f"{case}-{trial + 1}-{backend}"
                video = args.output / (stem + ".mp4")
                report = args.output / (stem + ".json")
                binary = args.baseline.resolve() if backend == "legacy" and args.baseline else app
                command = [str(binary), "--benchmark", "--renderer", backend, "--fps", "60", "--intro", "2", "--output", str(video), "--report", str(report)] + options
                result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
                (args.output / (stem + ".log")).write_text(result.stdout)
                if result.returncode != 0 or "VERIFIED 420 frames" not in result.stdout:
                    raise RuntimeError(f"{stem} failed; see {stem}.log")
                stats = json.loads(report.read_text())
                records.append({"case": case, "trial": trial + 1, "requestedBackend": backend, **stats})
                print(f"{stem}: {stats['framesPerSecond']:.1f} fps, CPU {stats['cpuBuildMeanMS']:.4f} ms, GPU {stats['gpuMeanMS']:.4f} ms", flush=True)
                if not args.keep_video:
                    video.unlink()
    summary = []
    for case in cases:
        row = {"case": case}
        for backend in ("legacy", "automatic"):
            samples = [r for r in records if r["case"] == case and r["requestedBackend"] == backend]
            row[backend] = {key: statistics.median(r[key] for r in samples) for key in ("framesPerSecond", "cpuBuildMeanMS", "gpuMeanMS", "peakResidentMB")}
        row["throughputChangePercent"] = (row["automatic"]["framesPerSecond"] / row["legacy"]["framesPerSecond"] - 1) * 100
        summary.append(row)
    output = {"platform": platform.platform(), "trials": args.trials, "framesPerExport": 420, "baseline": "older executable" if args.baseline else "same build legacy reference", "summary": summary, "runs": records}
    (args.output / "summary.json").write_text(json.dumps(output, indent=2, ensure_ascii=False) + "\n")
    for row in summary:
        print(f"MEDIAN {row['case']}: {row['throughputChangePercent']:+.1f}%", flush=True)


if __name__ == "__main__":
    main()
