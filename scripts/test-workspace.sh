#!/bin/bash
set -euo pipefail
task_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_repo_root/native"
task_test_dir="$task_repo_root/native/build/tests"
mkdir -p "$task_test_dir/ModuleCache"
task_sources=()
for task_source in Sources/*.swift; do
  [[ "$task_source" == Sources/App.swift ]] || task_sources+=("$task_source")
done
if [[ "${1:-}" != --toolbar-only ]]; then
swiftc -O -module-cache-path "$task_test_dir/ModuleCache" "${task_sources[@]}" Tests/WorkspaceLayoutRegression.swift -o "$task_test_dir/workspace" > "$task_test_dir/workspace-build.log" 2>&1 || { cat "$task_test_dir/workspace-build.log"; exit 1; }
"$task_test_dir/workspace" "$task_test_dir/workspace-frames" > "$task_test_dir/workspace.log" 2>&1 || { cat "$task_test_dir/workspace.log"; exit 1; }
cat "$task_test_dir/workspace.log"
fi
swiftc -O -module-cache-path "$task_test_dir/ModuleCache" "${task_sources[@]}" Tests/NativeToolbarRegression.swift -o "$task_test_dir/toolbar" > "$task_test_dir/toolbar-build.log" 2>&1 || { cat "$task_test_dir/toolbar-build.log"; exit 1; }
python3 - "$task_test_dir/toolbar" "$task_test_dir/workspace-frames/native-toolbar.png" "$task_test_dir/toolbar.log" > "$task_test_dir/toolbar-launch.log" 2>&1 <<'PY'
import subprocess,sys,plistlib,shutil
from pathlib import Path
binary,image,log=map(Path,sys.argv[1:])
bundle=binary.parent/'ToolbarTest.app'
contents=bundle/'Contents'
(contents/'MacOS').mkdir(parents=True,exist_ok=True)
shutil.copy2(binary,contents/'MacOS'/'toolbar')
with (contents/'Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleExecutable':'toolbar','CFBundleIdentifier':'local.lumascore.toolbar-test','CFBundleName':'LumaScore Toolbar Test','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0'},f)
log.write_text('')
log.with_suffix('.err').write_text('')
try:
    result=subprocess.run(['/usr/bin/open','-W','-n','--stdout',str(log),'--stderr',str(log.with_suffix('.err')),'--env','LUMASCORE_TEST_CAPTURE='+str(image),'--env','LUMASCORE_TEST_NATIVE_ROOT='+str(binary.parent.parent.parent),str(bundle)],timeout=20)
    sys.exit(0 if result.returncode==0 and 'PASS SwiftUI' in log.read_text() else 1)
except subprocess.TimeoutExpired:
    sys.exit('Toolbar test exceeded 20 seconds')
PY
cat "$task_test_dir/toolbar.log"
