#!/bin/bash
# Build the source bundle into a private prefix; never installs into /opt/homebrew.
set -euo pipefail
task_bundle_root="$(cd "$(dirname "$0")/.." && pwd)"
task_mode="${1:---prepare-only}"
task_work="${2:-$task_bundle_root/build}"
if [[ "$task_mode" != '--prepare-only' && "$task_mode" != '--build' ]]; then
  echo 'Usage: tools/rebuild-webm-runtime.sh [--prepare-only|--build] [work-directory]' >&2
  exit 1
fi
mkdir -p "$task_work"
task_work="$(cd "$task_work" && pwd)"
if [[ "$task_work" =~ [[:space:]] ]]; then
  echo 'Choose a work directory without whitespace; upstream configure flags use space-separated paths.' >&2
  exit 1
fi
if [[ ! -f "$task_bundle_root/source-manifest.json" ]]; then
  echo 'Run this script from the unpacked WebMRuntime source bundle.' >&2
  exit 1
fi
python3 - "$task_bundle_root" "$task_work" <<'PY'
import hashlib,json,shutil,sys,tarfile
from pathlib import Path
root=Path(sys.argv[1]);work=Path(sys.argv[2])
if not hasattr(tarfile,'data_filter'):
    raise SystemExit('Use Python 3.12+ (or a patched Python with tarfile.data_filter).')
manifest=json.loads((root/'source-manifest.json').read_text())
for package in manifest['packages']:
    archive=root/package['archive']
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=package['sourceSHA256']:
        raise SystemExit('Source checksum mismatch: '+package['package'])
    destination=work/'sources'/package['package']
    stamp=destination/'.lumascore-source-sha256'
    if stamp.exists() and stamp.read_text().strip()==package['sourceSHA256']:
        continue
    if destination.exists():
        raise SystemExit('Existing unverified source directory; choose a fresh work directory: '+str(destination))
    destination.parent.mkdir(parents=True,exist_ok=True)
    extraction=work/'extract'/package['package'];extraction.mkdir(parents=True,exist_ok=True)
    with tarfile.open(archive) as bundle:
        bundle.extractall(extraction,filter='data')
    entries=list(extraction.iterdir())
    if len(entries)!=1 or not entries[0].is_dir():
        raise SystemExit('Unexpected archive layout: '+package['package'])
    shutil.move(str(entries[0]),destination)
    stamp.write_text(package['sourceSHA256']+'\n')
print('All 13 source archives verified and safely extracted.')
PY
task_source="$task_work/sources"
if [[ ! -f "$task_source/libvpx/.lumascore-patched" ]]; then
  patch -F 0 -d "$task_source/libvpx" -p1 < "$task_bundle_root/Patches/libvpx-darwin27.patch"
  touch "$task_source/libvpx/.lumascore-patched"
fi
if [[ ! -f "$task_source/lame/.lumascore-patched" ]]; then
  patch -F 0 -d "$task_source/lame" -p1 < "$task_bundle_root/Patches/lame-export-symbol.patch"
  touch "$task_source/lame/.lumascore-patched"
fi
# Git archive lacks history used by x264's version.sh. Restore the recorded stamp.
python3 - "$task_bundle_root" "$task_source/x264" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]);source=Path(sys.argv[2]);header=(root/'BuildInfo/x264_config.h').read_text()
lines=[line for line in header.splitlines() if line.startswith(('#define X264_REV ', '#define X264_REV_DIFF ', '#define X264_VERSION ', '#define X264_POINTVER '))]
if len(lines)!=4:raise SystemExit('Incomplete original x264 version stamp')
script=source/'version.sh'
if not (source/'version.sh.upstream').exists():script.rename(source/'version.sh.upstream')
script.write_text("#!/bin/sh\ncat <<'LUMASCORE_X264_VERSION'\n"+'\n'.join(lines)+"\nLUMASCORE_X264_VERSION\n")
script.chmod(0o755)
PY
echo 'Recorded libvpx/LAME patches and x264 version stamp prepared.'
if [[ "$task_mode" == '--prepare-only' ]]; then exit 0; fi
[[ "$(uname -s)" == 'Darwin' && "$(uname -m)" == 'arm64' ]] || { echo 'This runtime build targets Apple Silicon macOS.' >&2; exit 1; }
for task_tool in clang clang++ make cmake meson ninja pkg-config perl; do
  command -v "$task_tool" >/dev/null || { echo "Missing general build tool: $task_tool" >&2; exit 1; }
done
export CC=clang CXX=clang++ MACOSX_DEPLOYMENT_TARGET=27.0
task_jobs="${JOBS:-$(sysctl -n hw.ncpu)}"
task_cellar="$task_work/Cellar"
task_prefix() { printf '%s/%s/%s' "$task_cellar" "$1" "$2"; }
task_paths="$(python3 - "$task_bundle_root" "$task_cellar" <<'PY'
import json,sys
from pathlib import Path
for p in json.loads((Path(sys.argv[1])/'source-manifest.json').read_text())['packages']:
 print(str(Path(sys.argv[2])/p['package']/p['version']))
PY
)"
task_pkg_dirs=''
task_dependency_includes=''
task_dependency_libs=''
while IFS= read -r task_path; do
  task_pkg_dirs="${task_pkg_dirs:+$task_pkg_dirs:}$task_path/lib/pkgconfig:$task_path/share/pkgconfig"
  task_dependency_includes="$task_dependency_includes -I$task_path/include"
  task_dependency_libs="$task_dependency_libs -L$task_path/lib"
done <<< "$task_paths"
export PKG_CONFIG_LIBDIR="$task_pkg_dirs"
export CMAKE_PREFIX_PATH="${task_paths//$'\n'/;}"
task_meson() { local task_setup=(meson setup "$1/build" "$1${3:-}" --prefix="$2" --libdir=lib --buildtype=release --wrap-mode=nodownload); if [[ -f "$1/build/build.ninja" ]]; then task_setup+=(--reconfigure); fi; "${task_setup[@]}"; meson compile -C "$1/build" -j "$task_jobs"; meson install -C "$1/build"; }
task_cmake() { local task_dir="$1" task_dest="$2"; shift 2; cmake -S "$task_dir" -B "$task_dir/build" -DCMAKE_INSTALL_PREFIX="$task_dest" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 "$@"; cmake --build "$task_dir/build" --parallel "$task_jobs"; cmake --install "$task_dir/build"; }
task_autoconf() { local task_dir="$1" task_dest="$2"; shift 2; (cd "$task_dir"; ./configure --prefix="$task_dest" "$@"; make -j "$task_jobs"; make install); }
task_meson "$task_source/dav1d" "$(task_prefix dav1d 1.5.3)"
task_autoconf "$task_source/lame" "$(task_prefix lame 3.100)" --disable-dependency-tracking --disable-debug --enable-nasm
task_meson "$task_source/libvmaf" "$(task_prefix libvmaf 3.2.1)" /libvmaf
task_vpx_prefix="$(task_prefix libvpx 1.17.0)"
mkdir -p "$task_source/libvpx/macbuild"
(cd "$task_source/libvpx/macbuild"; ../configure --prefix="$task_vpx_prefix" --disable-dependency-tracking --disable-examples --disable-unit-tests --enable-pic --enable-runtime-cpu-detect --enable-shared --enable-vp9-highbitdepth "--target=arm64-darwin$(uname -r | cut -d. -f1)-gcc"; make -j "$task_jobs"; make install)
task_ssl_prefix="$(task_prefix openssl@3 3.6.5)"
(cd "$task_source/openssl@3"; perl ./Configure --prefix="$task_ssl_prefix" --openssldir="$task_ssl_prefix/etc/openssl" --libdir=lib no-ssl3 no-ssl3-method no-zlib darwin64-arm64-cc enable-ec_nistp_64_gcc_128; make -j "$task_jobs"; make install MANSUFFIX=ssl)
task_autoconf "$task_source/opus" "$(task_prefix opus 1.6.1)" --disable-doc
task_cmake "$task_source/svt-av1" "$(task_prefix svt-av1 4.1.0)" -DBUILD_SHARED_LIBS=ON
task_autoconf "$task_source/x264" "$(task_prefix x264 r3222)" --disable-lsmash --disable-swscale --disable-ffms --enable-shared --enable-static --enable-strip
task_x265="$task_source/x265"
task_x265_prefix="$(task_prefix x265 4.3)"
mkdir -p "$task_x265/8bit"
for task_bits in 10 12; do
  task_extra=(); if [[ "$task_bits" == 12 ]]; then task_extra=(-DMAIN12=ON); else task_extra=(-DENABLE_HDR10_PLUS=ON); fi
  cmake -S "$task_x265/source" -B "$task_x265/${task_bits}bit" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DENABLE_SHARED=OFF -DENABLE_CLI=OFF "${task_extra[@]}"
  cmake --build "$task_x265/${task_bits}bit" --parallel "$task_jobs"
  cp "$task_x265/${task_bits}bit/libx265.a" "$task_x265/8bit/libx265_main${task_bits}.a"
done
cmake -S "$task_x265/source" -B "$task_x265/8bit" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 -DCMAKE_INSTALL_PREFIX="$task_x265_prefix" -DCMAKE_INSTALL_RPATH="$task_x265_prefix/lib" -DLINKED_10BIT=ON -DLINKED_12BIT=ON '-DEXTRA_LINK_FLAGS=-L.' '-DEXTRA_LIB=x265_main10.a;x265_main12.a'
cmake --build "$task_x265/8bit" --parallel "$task_jobs"
(cd "$task_x265/8bit"; mv libx265.a libx265_main.a; libtool -static -o libx265.a libx265_main.a libx265_main10.a libx265_main12.a)
cmake --install "$task_x265/8bit"
task_autoconf "$task_source/xz" "$(task_prefix xz 5.8.4)" --disable-silent-rules --disable-nls
task_sdl_prefix="$(task_prefix sdl3 3.4.18)"
# Substitute the isolated prefix in place of Homebrew's original SDL pc edit.
python3 - "$task_source/sdl3/cmake/sdl3.pc.in" "$task_sdl_prefix" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);p.write_text(p.read_text().replace('@SDL_PKGCONFIG_PREFIX@',sys.argv[2]))
PY
task_cmake "$task_source/sdl3" "$task_sdl_prefix" -DSDL_TESTS=OFF -DSDL_X11_XTEST=OFF
task_sdl2_prefix="$(task_prefix sdl2-compat 2.32.74)"
task_cmake "$task_source/sdl2-compat" "$task_sdl2_prefix" -DCMAKE_INSTALL_RPATH="$task_sdl_prefix/lib"
ln -sf sdl2-compat.pc "$task_sdl2_prefix/lib/pkgconfig/sdl2.pc"
task_ffmpeg_prefix="$(task_prefix ffmpeg 9.0.2)"
(cd "$task_source/ffmpeg"; ./configure --prefix="$task_ffmpeg_prefix" --extra-cflags="$task_dependency_includes" --extra-ldflags="$task_dependency_libs" --enable-shared --enable-pthreads --enable-version3 --cc=clang --host-cflags= --host-ldflags= --enable-ffplay --enable-gpl --enable-libsvtav1 --enable-libopus --enable-libx264 --enable-libmp3lame --enable-libdav1d --enable-libvmaf --enable-libvpx --enable-libx265 --enable-openssl --enable-videotoolbox --enable-audiotoolbox --enable-neon; make -j "$task_jobs"; make install)
# Retain upstream license texts and the original recipe alongside each prefix.
python3 - "$task_bundle_root" "$task_work" <<'PY'
from pathlib import Path
import json,shutil,sys
root=Path(sys.argv[1]);work=Path(sys.argv[2])
for package in json.loads((root/'source-manifest.json').read_text())['packages']:
 source=work/'sources'/package['package'];prefix=work/'Cellar'/package['package']/package['version']
 (prefix/'.brew').mkdir(exist_ok=True)
 shutil.copy2(root/package['formula'],prefix/'.brew'/(package['package']+'.rb'))
 for pattern in ('LICENSE*','COPYING*','NOTICE*','PATENTS*'):
  for p in source.glob(pattern):
   if p.is_file():shutil.copy2(p,prefix/p.name)
PY
python3 "$task_bundle_root/tools/package-webm-runtime.py" --ffmpeg-prefix "$task_ffmpeg_prefix" --output "$task_work/WebMRuntime"
"$task_work/WebMRuntime/ffmpeg" -version
echo "Rebuilt and relocated runtime: $task_work/WebMRuntime"
