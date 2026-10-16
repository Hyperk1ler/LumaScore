#!/bin/bash
set -euo pipefail
task_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_repo_root/native"
task_test_dir="$task_repo_root/native/build/tests"
mkdir -p "$task_test_dir/ModuleCache"
task_core=(Sources/Models.swift Sources/AudioAnalysis.swift Sources/MIDI.swift Sources/ChordAnalysis.swift Sources/Renderer.swift Sources/RendererScenes.swift Sources/Exporter.swift Sources/WebMTranscoder.swift Sources/StudioModel.swift Sources/FontCatalog.swift)
compile_test() {
  local task_name="$1"
  shift
  swiftc -O -module-cache-path "$task_test_dir/ModuleCache" "$@" -o "$task_test_dir/$task_name" > "$task_test_dir/$task_name-build.log" 2>&1 || { cat "$task_test_dir/$task_name-build.log"; return 1; }
}
run_test() {
  local task_name="$1"
  shift
  "$task_test_dir/$task_name" "$@" > "$task_test_dir/$task_name.log" 2>&1 || { cat "$task_test_dir/$task_name.log"; return 1; }
  tail -n 2 "$task_test_dir/$task_name.log"
}
compile_test audio Sources/AudioAnalysis.swift Tests/AudioAnalysisSelfTest.swift
run_test audio Fixtures/representative-5s.wav
compile_test chords -D CHORD_TEST_AUDIO_STUB Sources/Models.swift Sources/ChordAnalysis.swift Tests/ChordAnalysisTests.swift
run_test chords
compile_test presets "${task_core[@]}" Sources/PresetLibrary.swift Tests/PresetLibraryTests.swift
run_test presets
compile_test feedback "${task_core[@]}" Sources/CanvasShortcuts.swift Tests/FeedbackRegression.swift
run_test feedback
compile_test tracks "${task_core[@]}" Tests/TrackEditingRegression.swift
run_test tracks
compile_test performance "${task_core[@]}" Tests/PerformanceRegression.swift
run_test performance Fixtures/representative-5s.wav
compile_test metal4 "${task_core[@]}" Tests/Metal4Regression.swift
run_test metal4
compile_test scenes "${task_core[@]}" Tests/AudioTemplateRegression.swift
run_test scenes "$task_test_dir/scene-frames"
if [[ "${1:-}" == "--playback" ]]; then
  compile_test transport "${task_core[@]}" Tests/PlaybackTransportRegression.swift
  run_test transport Fixtures/representative-5s.wav
  compile_test boundary "${task_core[@]}" Tests/PlaybackBoundaryProbe.swift
  run_test boundary "$task_test_dir/boundary-audio.json" --audio --verify --fixture Fixtures/representative-5s.wav
fi
printf 'All selected tests passed. Logs: %s\n' "$task_test_dir"
