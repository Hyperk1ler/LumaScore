#!/bin/zsh
set -eu
task_native_root="$(cd "$(dirname "$0")" && pwd)"
xcodebuild -project "$task_native_root/LumaScore.xcodeproj" -scheme LumaScore -configuration Release -derivedDataPath "$task_native_root/build/DerivedData" CODE_SIGN_IDENTITY=- build
