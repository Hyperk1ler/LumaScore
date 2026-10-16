#!/usr/bin/env python3
"""Build isolated export experiments, then measure them serially on fixed media."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys

CORE = ('Models.swift', 'AudioAnalysis.swift', 'MIDI.swift', 'ChordAnalysis.swift',
        'Renderer.swift', 'RendererScenes.swift', 'Exporter.swift',
        'WebMTranscoder.swift', 'StudioModel.swift', 'FontCatalog.swift')
MODES = {
    'baseline': ('baseline', {}),
    'prefetch3': ('scheduling', {'LUMASCORE_EXPORT_PREFETCH': '3'}),
    'prefetch6': ('scheduling', {'LUMASCORE_EXPORT_PREFETCH': '6', 'LUMASCORE_EXPORT_PREFETCH_MB': '192'}),
    'prefetch3-reviewed': ('scheduling-reviewed', {}),
    'nv12': ('nv12', {}),
    'receiver-immediate': ('receiver', {'LUMASCORE_RECEIVER_MODE': 'immediate'}),
    'receiver-async': ('receiver', {'LUMASCORE_RECEIVER_MODE': 'async'}),
}


def main():
    native = Path(__file__).resolve().parents[1]
    experiment = native / 'Experiments/ExportPipeline'
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New directory for copies, binaries and reports')
    parser.add_argument('--trials', type=int, default=3)
    parser.add_argument('--variants', default=','.join(n for n in MODES if n != 'prefetch3-reviewed'),
                        help='Comma-separated variants; prefetch3-reviewed is an additional, unmeasured candidate')
    parser.add_argument('--cases', default='audio1080,hybrid1080,hybrid4k')
    parser.add_argument('--fixture-seconds', type=int, choices=(5, 30), default=5)
    parser.add_argument('--keep-video', action='store_true')
    parser.add_argument('--build-only', action='store_true')
    args = parser.parse_args()
    if sys.platform != 'darwin': parser.error('A Mac with Metal and Xcode is required')
    names = args.variants.split(',')
    if args.trials < 1 or not names or any(n not in MODES for n in names): parser.error('Invalid trials or variants')
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    lock = json.loads((experiment/'source-lock.json').read_text())
    for name in CORE:
        actual = hashlib.sha256((native/'Sources'/name).read_bytes()).hexdigest()
        if actual != lock['baseSourceSHA256'][name]:
            raise RuntimeError(f'{name} differs from the locked baseline; rebase the experiment patches explicitly')
    for name, expected in lock['fixtureSHA256'].items():
        actual = hashlib.sha256((native/'Fixtures'/name).read_bytes()).hexdigest()
        if actual != expected: raise RuntimeError(f'{name} fixture checksum mismatch')
    for variant in set(MODES[n][0] for n in names) - {'baseline'}:
        actual = hashlib.sha256((experiment/(variant+'.patch')).read_bytes()).hexdigest()
        if actual != lock['patchSHA256'][variant]: raise RuntimeError(f'{variant} patch checksum mismatch')
    binaries = {}
    for variant in dict.fromkeys(MODES[n][0] for n in names):
        work = args.output/variant
        shutil.copytree(native/'Sources', work/'Sources')
        shutil.copy2(experiment/'ExportBenchmark.swift', work/'ExportBenchmark.swift')
        if variant != 'baseline':
            subprocess.run(['/usr/bin/patch', '-p1', '-f', '-i', str(experiment/(variant+'.patch'))], cwd=work, check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        binary = work/'export-benchmark'
        command = ['xcrun', 'swiftc', '-O', '-swift-version', '5', '-target', platform.machine()+'-apple-macos13.0',
                   '-module-cache-path', str(work/'ModuleCache')]
        command += [str(work/'Sources'/n) for n in CORE] + [str(work/'ExportBenchmark.swift'), '-o', str(binary)]
        print('Building '+variant, flush=True)
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (work/'build.log').write_text(result.stdout)
        if result.returncode: raise RuntimeError(f'{variant} compile failed: {work}/build.log')
        binaries[variant] = binary
    if args.build_only: return
    fixtures = native/'Fixtures'
    midi = str(fixtures/f'representative-{args.fixture_seconds}s.mid')
    audio = str(fixtures/f'representative-{args.fixture_seconds}s.wav')
    cases = {
        'audio1080': ['--audio', audio, '--scene', 'audio', '--template', 'Record Sleeve', '--title', 'Night Signal', '--resolution', '1080', '--crt', '--fisheye', '0.3', '--metronome'],
        'hybrid1080': ['--midi', midi, '--audio', audio, '--scene', 'hybrid', '--resolution', '1080', '--crt'],
        'hybrid4k': ['--midi', midi, '--audio', audio, '--scene', 'hybrid', '--resolution', '2160', '--glow-radius', '40', '--fisheye', '0.6'],
    }
    selected = args.cases.split(',')
    if any(c not in cases for c in selected): parser.error('Unknown case')
    report_dir = args.output/'results'; report_dir.mkdir()
    runs = []
    frames = (args.fixture_seconds + 2)*60
    for case in selected:
        for trial in range(args.trials):
            order = names[trial % len(names):] + names[:trial % len(names)]
            # With two variants, reversing odd rotations would cancel the
            # rotation and put baseline first in every trial.
            if len(names) > 2 and trial % 2: order.reverse()
            for mode in order:
                variant, extra = MODES[mode]
                stem = f'{case}-{trial+1}-{mode}'
                video, report = report_dir/(stem+'.mp4'), report_dir/(stem+'.json')
                command = [str(binaries[variant]), '--fps', '60', '--intro', '2', '--glow', '0.4',
                           '--output', str(video), '--report', str(report)] + cases[case]
                if trial == 0: command += ['--frame', str(report_dir/(stem+'.png'))]
                env = dict(os.environ)
                for key in ('MTL_DEBUG_LAYER', 'LUMASCORE_EXPORT_PREFETCH', 'LUMASCORE_EXPORT_PREFETCH_MB', 'LUMASCORE_RECEIVER_MODE'): env.pop(key, None)
                env.update(extra)
                result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
                (report_dir/(stem+'.log')).write_text(result.stdout)
                if result.returncode or f'VERIFIED {frames} frames' not in result.stdout:
                    raise RuntimeError(f'{stem} failed; inspect {stem}.log')
                stats = json.loads(report.read_text())
                runs.append({'case': case, 'trial': trial+1, 'variant': mode, **stats})
                print(f'{stem}: {stats["framesPerSecond"]:.2f} fps', flush=True)
                (report_dir/'runs.json').write_text(json.dumps(runs, indent=2)+'\n')
                if not args.keep_video: video.unlink()
    summary = []
    for case in selected:
        base = [r['framesPerSecond'] for r in runs if r['case']==case and r['variant']=='baseline']
        for mode in names:
            records = [r for r in runs if r['case']==case and r['variant']==mode]
            fps = statistics.median(r['framesPerSecond'] for r in records)
            summary.append({'case':case,'variant':mode,'fps':fps,
                            'changePercent':(fps/statistics.median(base)-1)*100 if base else None,
                            'minFPS':min(r['framesPerSecond'] for r in records),
                            'maxFPS':max(r['framesPerSecond'] for r in records)})
    output = {'platform':platform.platform(),'trials':args.trials,'frames':frames,'summary':summary,'runs':runs}
    (report_dir/'summary.json').write_text(json.dumps(output, indent=2)+'\n')
    print('Results: '+str(report_dir/'summary.json'))


if __name__ == '__main__':
    main()
