#!/bin/bash
set -euo pipefail
task_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_repo_root"
task_version="$(plutil -extract CFBundleShortVersionString raw native/Info.plist)"
task_product='native/build/DerivedData/Build/Products/Release/LumaScore.app'
if [[ ! -d "$task_product" ]]; then
  echo 'Build first: ./native/build.sh' >&2
  exit 1
fi
codesign --verify --deep --strict "$task_product"
mkdir -p outputs
rm -rf outputs/LumaScore.app
ditto "$task_product" outputs/LumaScore.app
# Release artifacts omit local build paths and development symbols.
/usr/bin/strip -S -x outputs/LumaScore.app/Contents/MacOS/LumaScore
codesign --force --sign - outputs/LumaScore.app
codesign --verify --deep --strict outputs/LumaScore.app
ditto -c -k --sequesterRsrc --keepParent outputs/LumaScore.app "outputs/LumaScore-v${task_version}-macOS.zip"
# Package only public sources, docs and runtime resources; omit all local evidence.
python3 - "$task_version" <<'PY'
from pathlib import Path
import sys,zipfile
version=sys.argv[1]
roots=[Path('native'),Path('docs'),Path('scripts')]
files=[Path('README.md'),Path('THIRD_PARTY_NOTICES.md'),Path('.gitignore'),Path('Design.pen')]
for root in roots:
 for p in root.rglob('*'):
  if p.is_file() and not any(part in {'build','build-perf','build-v2','WebMRuntimeBuild','xcuserdata','__pycache__'} for part in p.parts) and p.name != '.DS_Store':
   files.append(p)
with zipfile.ZipFile(f'outputs/LumaScore-v{version}-source.zip','w',zipfile.ZIP_DEFLATED) as archive:
 for p in sorted(files):
  archive.write(p,Path(f'LumaScore-{version}')/p)
PY
(cd outputs && shasum -a 256 "LumaScore-v${task_version}-macOS.zip" "LumaScore-v${task_version}-source.zip" > SHA256SUMS.txt)
echo "Packaged LumaScore ${task_version} in outputs/"
