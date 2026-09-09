#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Dennis Michael Heine
#
# dlss5-install.sh -- DLSS 5 / DLAA for a Windows game under Steam Proton (Linux, NVIDIA)
#
#   dlss5-install.sh [options] /path/to/game.exe
#
# Installs ReShade 6.8.0 (add-on build) next to the given executable together
# with one of two add-on paths, downloads every dependency itself, and creates
# the fake DriverStore inside the Proton prefix that the add-ons need on Wine.
#
#   mode "nr"     (default) dlss5-bridge + addon-dlssnr-linux. Builds a
#                 substitute DLAA contract from ReShade depth and motion
#                 vectors; the NR add-on hooks the regular NGX exports and
#                 drives the model directly, bypassing driver dispatch. This is
#                 the only path that produces neural rendering on Ada.
#                 unwrap=0 is mandatory, or ReShade faults. The model build has
#                 to match the GPU, which --model auto handles: RTX 40 (Ada)
#                 needs rtx40, RTX 50 (Blackwell) needs ref.
#                 Requires vort_Motion.fx to compile; it does not on every
#                 runtime (E5017, attribute 'fastopt') -- use dlaa there.
#   mode "dlaa"   DLSS5-Reshade-AIO. Brings its own private D3D12 session and
#                 runs DLSS super resolution at native resolution. Cheaper and
#                 more mature, but its neural rendering goes through the
#                 driver's NGX dispatch, which refuses feature 18 on Ada
#                 (0xBAD00001); it is switched off there and only attempted on
#                 Blackwell.
#
# Re-running with a different --mode only switches over, it downloads nothing.
#
set -euo pipefail

# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option) any
# later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
# details.
#
# You should have received a copy of the GNU General Public License along with
# this program.  If not, see <https://www.gnu.org/licenses/>.

VERSION=1.1

RESHADE_VER=6.8.0
BRIDGE_VER=v1.4.8
DLSSNR_LINUX_VER=v0.2.1
AIO_VER=v2.2.1
AIO_SHA64=003532014748ac6bc5c6a9ef5048b31f8aec7690dbf79d5f523ae5e2a04ee2f8
DLSS_SDK_VER=v310.7.0

MODEL_REF_SHA=e16bcf15e16e13f527491cdf7845b2fe6521a738d8f7c9c721866a8496e1fc8e
MODEL_R40_SHA=4b8d19bc3eff58a084f5eca7489c921501c203450169fb82ff4f649a4482ba05

MODE=nr
MODEL=auto
PREFIX=""
DLSS_OVERRIDE=""
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/dlss5-installer"
DO_UNINSTALL=0
ASSUME_YES=0
EXE=""
GPUARCH=unknown
GPUNAME=""
CC=""

# Where the driver keeps its Wine/NGX DLLs differs between distributions.
NVWINE_CANDIDATES="
/usr/lib/x86_64-linux-gnu/nvidia/wine
/usr/lib64/nvidia/wine
/usr/lib/nvidia/wine
/usr/lib/nvidia-current/wine
/opt/cuda/lib64/nvidia/wine
$HOME/.local/share/flatpak/runtime/org.freedesktop.Platform.GL.nvidia-*/x86_64/*/*/files/lib/nvidia/wine
/var/lib/flatpak/runtime/org.freedesktop.Platform.GL.nvidia-*/x86_64/*/*/files/lib/nvidia/wine
"
NVWINE="${NVWINE_DIR:-}"

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  awk 'NR==1{next} /^# *(SPDX|Copyright)/{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
  cat <<'USAGE'
Options:
  --mode nr|dlaa     Which add-on path is active (default: nr)
  --model auto|rtx40|ref
                     Neural rendering model build (default: auto). auto reads
                     the GPU compute capability: 8.9 (Ada, RTX 40) -> rtx40,
                     10.0 and above (Blackwell, RTX 50) -> ref. Both builds
                     report version 310.8.0.0 but accept different hardware;
                     the wrong one answers 0xBAD00001.
  --prefix PATH      Proton prefix (the "pfx" directory). Without it the prefix
                     is derived from the Steam library holding the executable.
  --dlss PATH        Use a local nvngx_dlss.dll instead of the NVIDIA SDK one
  --cache DIR        Download cache (default: ~/.cache/dlss5-installer)
  --uninstall        Remove the installation and restore the backup
  -y, --yes          Do not prompt
  -h, --help         This help

Example:
  dlss5-install.sh --mode nr --model ref \
    "/media/games/SteamLibrary/steamapps/common/Some Game/x64/game64.exe"
USAGE
}

# ---------------------------------------------------------------- arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)      MODE="${2:?}"; shift 2 ;;
    --model)     MODEL="${2:?}"; shift 2 ;;
    --prefix)    PREFIX="${2:?}"; shift 2 ;;
    --dlss)      DLSS_OVERRIDE="${2:?}"; shift 2 ;;
    --cache)     CACHE="${2:?}"; shift 2 ;;
    --uninstall) DO_UNINSTALL=1; shift ;;
    -y|--yes)    ASSUME_YES=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          die "Unknown option: $1  (--help)" ;;
    *)           [ -z "$EXE" ] || die "Give exactly one executable."; EXE="$1"; shift ;;
  esac
done

[ -n "$EXE" ] || { usage; exit 1; }
case "$MODE"  in dlaa|nr) ;; *) die "--mode must be dlaa or nr." ;; esac
case "$MODEL" in auto|ref|rtx40) ;; *) die "--model must be auto, ref or rtx40." ;; esac

[ -f "$EXE" ] || die "Executable not found: $EXE"
EXE="$(readlink -f "$EXE")"
GAMEDIR="$(dirname "$EXE")"
DIS="$GAMEDIR/_disabled"
STATE="$GAMEDIR/.dlss5-install.state"

# Everything this script creates or replaces in the game directory.
OWNED="dxgi.dll
d3dcompiler_47.dll
ReShade.ini
ReShadePreset.ini
nvngx.dll
nvngx_dlss.dll
nvngx_dlssnr.dll
nvngx_dlssg.dll
dlss5-bridge.addon64
dlss5-bridge.cfg
dlssnr-linux.addon64
nvngx.dll_nrfwd.dll
standalone-dlssnr.addon64"

# Add-on files redistributed on every run. They are cleared from both locations
# first: two DLSS 5 add-ons in one directory make the feature create fault
# inside D3D12Core (dlss5-bridge #16).
ADDON_FILES="dlss5-bridge.addon64
dlssnr-linux.addon64
nvngx.dll_nrfwd.dll
standalone-dlssnr.addon64
nvngx.dll"

# ---------------------------------------------------------------- preflight
step "Checking requirements"

MISSING=""
for t in curl unzip sha256sum tar; do
  command -v "$t" >/dev/null || MISSING="$MISSING $t"
done
# 7-Zip is called 7z, 7za or 7zr depending on the distribution.
SEVENZIP=""
for t in 7z 7za 7zr; do command -v "$t" >/dev/null && { SEVENZIP="$t"; break; }; done
[ -n "$SEVENZIP" ] || MISSING="$MISSING 7z"
if [ -n "$MISSING" ]; then
  die "Missing tools:$MISSING
  Debian/Ubuntu : sudo apt install curl p7zip-full unzip tar coreutils
  Fedora        : sudo dnf install curl p7zip unzip tar coreutils
  Arch          : sudo pacman -S curl p7zip unzip tar coreutils
  openSUSE      : sudo zypper install curl p7zip-full unzip tar coreutils"
fi
ok "tools present ($SEVENZIP for archives)"

if command -v file >/dev/null; then
  case "$(file -b "$EXE")" in
    *x86-64*) ok "64-bit executable: $(basename "$EXE")" ;;
    *80386*)  die "That is a 32-bit executable. This stack is 64-bit only. Check whether the game ships a 64-bit client, often in an x64/ subdirectory." ;;
    *)        warn "could not determine bitness, continuing" ;;
  esac
fi

# Wine sets comm to the executable name truncated to 15 characters. pgrep -f
# would be wrong here: this script's own command line contains the exe path.
game_running() {
  local n p; n="$(basename "$EXE")"; n="${n:0:15}"
  for p in /proc/[0-9]*; do
    [ -r "$p/comm" ] || continue
    [ "$(cat "$p/comm" 2>/dev/null)" = "$n" ] && return 0
  done
  return 1
}
game_running && die "The game is still running. Close it first."
ok "game is not running"

if [ "$DO_UNINSTALL" = 0 ]; then
  [ -n "$NVWINE" ] || for c in $NVWINE_CANDIDATES; do
    [ -f "$c/_nvngx.dll" ] && { NVWINE="$c"; break; }
  done
  if [ -z "$NVWINE" ]; then
    c="$(find /usr/lib /usr/lib64 /opt -maxdepth 6 -name _nvngx.dll -path '*nvidia*' 2>/dev/null | head -1)"
    [ -n "$c" ] && NVWINE="$(dirname "$c")"
  fi
  [ -n "$NVWINE" ] || die "_nvngx.dll not found. This needs the proprietary NVIDIA driver
  (the package shipping the Wine/NGX DLLs, usually under .../nvidia/wine/).
  If it lives elsewhere, point NVWINE_DIR at that directory."
  ok "NVIDIA Wine libraries: $NVWINE"
  if command -v nvidia-smi >/dev/null; then
    DRV="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)"
    if [ -n "$DRV" ]; then
      ok "driver $DRV"
      case "$DRV" in
        [0-9]*) MAJ="${DRV%%.*}"
                [ "$MAJ" -ge 610 ] 2>/dev/null || warn "driver $DRV is older than 610; NGX refuses DLSS-NR there with 0xBAD00001" ;;
      esac
    fi
    GPUNAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
    CC="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 || true)"
    # Compute capability identifies the architecture more reliably than the
    # marketing name: 7.5 Turing, 8.0/8.6 Ampere, 8.9 Ada (RTX 40),
    # 10.0 and above Blackwell (RTX 50).
    case "$CC" in
      8.9)                   GPUARCH=ada ;;
      1[0-9].*|[2-9][0-9].*) GPUARCH=blackwell ;;
      7.*|8.*)               GPUARCH=older ;;
      *)                     GPUARCH=unknown ;;
    esac
    ok "GPU: ${GPUNAME:-unknown} (CC ${CC:-?}, architecture: $GPUARCH)"
  else
    warn "nvidia-smi not found, driver and GPU unchecked"
  fi
fi

# ------------------------------------------------- pick the model build
# Both builds carry version 310.8.0.0 but accept different hardware. Measured:
# on an RTX 4080 the reference build answers 0xBAD00001 FeatureNotSupported
# while the RTX40 build runs.
if [ "$MODEL" = auto ]; then
  case "$GPUARCH" in
    blackwell) MODEL=ref
               ok "model build selected: ref (310.8.0 reference, verified on RTX 50)" ;;
    ada)       MODEL=rtx40
               ok "model build selected: rtx40 (310.8.0-RTX40, verified on RTX 40)" ;;
    *)         MODEL=rtx40
               warn "architecture not conclusive ($GPUARCH), using rtx40"
               warn "if the log shows 0xBAD00001, try the other build: --model ref" ;;
  esac
fi

# ------------------------------------------------- locate the Proton prefix
if [ -z "$PREFIX" ]; then
  d="$GAMEDIR"
  while [ "$d" != "/" ]; do
    p="$(dirname "$d")"
    if [ "$(basename "$p")" = "common" ] && [ "$(basename "$(dirname "$p")")" = "steamapps" ]; then
      STEAMAPPS="$(dirname "$p")"
      INSTALLDIR="$(basename "$d")"
      APPID="$(grep -l "\"installdir\"[[:space:]]*\"$INSTALLDIR\"" "$STEAMAPPS"/appmanifest_*.acf 2>/dev/null \
               | head -1 | sed 's/.*appmanifest_\([0-9]*\)\.acf/\1/')"
      [ -n "${APPID:-}" ] && PREFIX="$STEAMAPPS/compatdata/$APPID/pfx"
      break
    fi
    d="$p"
  done
fi

if [ -n "$PREFIX" ] && [ -d "$PREFIX/drive_c" ]; then
  ok "Proton prefix: $PREFIX${APPID:+  (AppID $APPID)}"
else
  PREFIX=""
  warn "Proton prefix not found, skipping the DriverStore shim."
  warn "Without it the AIO add-on fails with 0x000000B7. Pass --prefix to fix."
fi

# ---------------------------------------------------------------- uninstall
if [ "$DO_UNINSTALL" = 1 ]; then
  step "Removing the installation from $GAMEDIR"
  for f in $OWNED dlss5-bridge.log ReShade.log ReShade.log1 \
           nvngx_dlssnr.310.8.0-reference.dll.bak nvngx_dlssnr.310.8.0-RTX40.dll.bak; do
    [ -e "$GAMEDIR/$f" ] && rm -f "$GAMEDIR/$f" && say "  removed: $f"
  done
  rm -rf "$DIS" "$GAMEDIR/reshade-shaders" "$GAMEDIR/licenses"
  rm -f "$STATE"
  BK="$(ls -d "$GAMEDIR"/_dlss5-backup-* 2>/dev/null | tail -1 || true)"
  if [ -n "$BK" ]; then
    say "  restoring backup: $(basename "$BK")"
    for f in "$BK"/*; do [ -e "$f" ] && cp -a "$f" "$GAMEDIR/"; done
  fi
  [ -n "$PREFIX" ] && rm -rf "$PREFIX"/drive_c/windows/system32/DriverStore/FileRepository/nvlti.inf_amd64_* && \
    say "  DriverStore shim removed"
  say ""
  say "Done. Clear the game's Steam launch options by hand."
  exit 0
fi

# ---------------------------------------------------------------- summary
step "About to do"
say "  executable : $EXE"
say "  target dir : $GAMEDIR"
say "  mode       : $MODE"
say "  model      : $MODEL"
say "  GPU        : ${GPUNAME:-unknown} (${GPUARCH})"
say "  cache      : $CACHE"
if [ "$ASSUME_YES" = 0 ]; then
  printf '\nContinue? [y/N] '
  read -r a; case "$a" in y|Y|j|J) ;; *) die "Aborted." ;; esac
fi

mkdir -p "$CACHE" "$DIS"
TMPROOTS="$(mktemp)"; trap 'rm -f "$TMPROOTS"' EXIT

# fetch <cache-filename> <url> [sha256]
fetch() {
  local out="$CACHE/$1" url="$2" want="${3:-}"
  if [ -s "$out" ]; then
    if [ -z "$want" ] || [ "$(sha256sum "$out" | cut -d' ' -f1)" = "$want" ]; then
      ok "cached: $1"; return 0
    fi
    warn "cached $1 does not match, downloading again"
    rm -f "$out"
  fi
  say "  downloading $1 ..."
  curl -fL --retry 3 --progress-bar -o "$out.part" "$url" || die "Download failed: $url"
  if [ -n "$want" ] && [ "$(sha256sum "$out.part" | cut -d' ' -f1)" != "$want" ]; then
    rm -f "$out.part"; die "Checksum mismatch for $1."
  fi
  mv "$out.part" "$out"
  ok "downloaded: $1"
}

# ---------------------------------------------------------------- downloads
step "Downloading dependencies"

if [ -s "$CACHE/ReShade64.dll" ]; then
  ok "cached: ReShade64.dll"
else
  fetch "ReShade_Setup_${RESHADE_VER}_Addon.exe" \
        "https://reshade.me/downloads/ReShade_Setup_${RESHADE_VER}_Addon.exe"
fi

fetch "dlss5-bridge.addon64" \
      "https://github.com/NIGos/dlss5-bridge/releases/download/${BRIDGE_VER}/dlss5-bridge.addon64"

fetch "dlssnr-linux.addon64" \
      "https://github.com/NapXDD/addon-dlssnr-linux/releases/download/${DLSSNR_LINUX_VER}/dlssnr-linux.addon64"
fetch "nvngx.dll_nrfwd.dll" \
      "https://github.com/NapXDD/addon-dlssnr-linux/releases/download/${DLSSNR_LINUX_VER}/nvngx.dll_nrfwd.dll"

# Since v2.1.0 the AIO ships one ready-laid-out archive per architecture
# instead of loose files, with published checksums.
fetch "DLSS5-ReShade-AIO-${AIO_VER}-64-bit.zip" \
      "https://github.com/kibblerz/DLSS5-Reshade-AIO/releases/download/${AIO_VER}/DLSS5-ReShade-AIO-${AIO_VER}-64-bit.zip" \
      "$AIO_SHA64"

# The NR model is 166 MB unpacked. If it already sits unpacked in the cache with
# a matching hash, the 110 MB zip is never downloaded.
ensure_model() {  # <zipname> <url> <sha256> <cache-filename>
  if [ -s "$CACHE/$4" ] && [ "$(sha256sum "$CACHE/$4" | cut -d' ' -f1)" = "$3" ]; then
    ok "cached: $4"; return 0
  fi
  fetch "$1" "$2"
  ( cd "$CACHE" && unzip -o -q "$1" nvngx_dlssnr.dll && mv -f nvngx_dlssnr.dll "$4" ) \
    || die "Could not unpack $1."
  [ "$(sha256sum "$CACHE/$4" | cut -d' ' -f1)" = "$3" ] || die "$4 has an unexpected hash."
  ok "unpacked and verified: $4"
}
if [ "$MODEL" = ref ]; then
  ensure_model nvngx_dlssnr_310.8.0.zip \
    "https://github.com/RankFTW/rhi-repo/releases/download/dlssnr-310.8.0/nvngx_dlssnr_310.8.0.zip" \
    "$MODEL_REF_SHA" model-ref.dll
else
  ensure_model nvngx_dlssnr_310.8.0-RTX40.zip \
    "https://github.com/RankFTW/rhi-repo/releases/download/dlssnr-310.8.0-RTX40/nvngx_dlssnr_310.8.0-RTX40.zip" \
    "$MODEL_R40_SHA" model-rtx40.dll
fi

if [ -n "$DLSS_OVERRIDE" ]; then
  [ -f "$DLSS_OVERRIDE" ] || die "--dlss: $DLSS_OVERRIDE not found."
  cp -f "$DLSS_OVERRIDE" "$CACHE/nvngx_dlss.dll"
  ok "using nvngx_dlss.dll from $DLSS_OVERRIDE"
else
  fetch "nvngx_dlss.dll" \
        "https://raw.githubusercontent.com/NVIDIA/DLSS/${DLSS_SDK_VER}/lib/Windows_x86_64/rel/nvngx_dlss.dll"
fi

# ReShade's built-in ReShade.fxh is not on disk, and effects that include it
# need a real copy in the search path. The slim branch is the official one.
fetch "reshade-shaders-slim.tar.gz" \
      "https://codeload.github.com/crosire/reshade-shaders/tar.gz/refs/heads/slim"

# vort_Shaders provides MotVectTexVort, which only the nr mode consumes.
if [ "$MODE" = nr ]; then
  fetch "vort_Shaders.tar.gz" \
        "https://codeload.github.com/vortigern11/vort_Shaders/tar.gz/refs/heads/main"
fi

# ---------------------------------------------------------------- unpacking
step "Preparing files"

if [ ! -s "$CACHE/ReShade64.dll" ]; then
  ( cd "$CACHE" && "$SEVENZIP" e -y "ReShade_Setup_${RESHADE_VER}_Addon.exe" ReShade64.dll >/dev/null ) \
    || die "Could not extract ReShade64.dll from the setup."
fi
ok "ReShade64.dll ($(stat -c%s "$CACHE/ReShade64.dll") bytes)"

case "$MODEL" in
  ref)   ok "model build: 310.8.0 reference (verified on RTX 50)" ;;
  rtx40) ok "model build: 310.8.0-RTX40 (verified on RTX 40 / Ada)" ;;
esac

# The AIO zip stores paths with backslashes. unzip resolves them but warns and
# exits 1, and it restores directory modes that block traversal.
AIOTMP="$(mktemp -d)"; trap 'rm -f "$TMPROOTS"; rm -rf "$AIOTMP"' EXIT
unzip -q -o "$CACHE/DLSS5-ReShade-AIO-${AIO_VER}-64-bit.zip" -d "$AIOTMP" || true
chmod -R u+rwX "$AIOTMP"
[ -f "$AIOTMP/standalone-dlssnr.addon64" ] || die "AIO zip did not unpack as expected."
[ -f "$AIOTMP/nvngx.dll" ]                 || die "AIO zip has no caller bridge."
# The rest of the script places these through the cache, under stable names.
install -m 644 "$AIOTMP/standalone-dlssnr.addon64" "$CACHE/standalone-dlssnr.addon64"
install -m 644 "$AIOTMP/nvngx.dll"                 "$CACHE/aio-nvngx.dll"
ok "AIO ${AIO_VER} unpacked ($(find "$AIOTMP" -type f | wc -l) files)"

# ---------------------------------------------------------------- backup
# Only back up on the very first run. Otherwise a mode switch would save this
# script's own files as "pre-existing" and uninstall would restore them.
if [ ! -e "$STATE" ]; then
  BACKUP="$GAMEDIR/_dlss5-backup-$(date +%Y%m%d-%H%M%S)"
  NEED_BK=0
  for f in $OWNED; do [ -e "$GAMEDIR/$f" ] && NEED_BK=1; done
  if [ "$NEED_BK" = 1 ]; then
    step "Backing up pre-existing files"
    mkdir -p "$BACKUP"
    for f in $OWNED; do
      [ -e "$GAMEDIR/$f" ] && cp -a "$GAMEDIR/$f" "$BACKUP/" && ok "saved: $f"
    done
    say "  -> $BACKUP"
  else
    ok "no previous installation found, nothing to back up"
  fi
fi

# ---------------------------------------------------------------- install
step "Installing into $GAMEDIR"

install -m 644 "$CACHE/ReShade64.dll" "$GAMEDIR/dxgi.dll";               ok "dxgi.dll  (ReShade $RESHADE_VER, add-on build, 64-bit)"
install -m 644 "$CACHE/nvngx_dlss.dll" "$GAMEDIR/nvngx_dlss.dll";        ok "nvngx_dlss.dll"

if [ -f "$NVWINE/nvngx_dlssg.dll" ]; then
  install -m 644 "$NVWINE/nvngx_dlssg.dll" "$GAMEDIR/nvngx_dlssg.dll";   ok "nvngx_dlssg.dll (from the driver)"
fi

case "$MODEL" in
  ref)   install -m 644 "$CACHE/model-ref.dll" "$GAMEDIR/nvngx_dlssnr.dll"
         OTHER=model-rtx40.dll; OTHERNAME=nvngx_dlssnr.310.8.0-RTX40.dll.bak ;;
  rtx40) install -m 644 "$CACHE/model-rtx40.dll" "$GAMEDIR/nvngx_dlssnr.dll"
         OTHER=model-ref.dll;   OTHERNAME=nvngx_dlssnr.310.8.0-reference.dll.bak ;;
esac
ok "nvngx_dlssnr.dll (build: $MODEL)"
if [ -s "$CACHE/$OTHER" ]; then
  install -m 644 "$CACHE/$OTHER" "$GAMEDIR/$OTHERNAME"
  ok "$OTHERNAME (the other build, kept for switching)"
fi

# Add-ons: clear both locations first, then place the active set in GAMEDIR and
# the other in _disabled/. Without clearing, a mode switch leaves both behind.
for f in $ADDON_FILES; do rm -f "$GAMEDIR/$f" "$DIS/$f"; done
put() { install -m 644 "$CACHE/$1" "$2/$3"; }
if [ "$MODE" = dlaa ]; then
  put standalone-dlssnr.addon64 "$GAMEDIR" standalone-dlssnr.addon64
  put aio-nvngx.dll             "$GAMEDIR" nvngx.dll
  put dlss5-bridge.addon64      "$DIS"     dlss5-bridge.addon64
  put dlssnr-linux.addon64      "$DIS"     dlssnr-linux.addon64
  put nvngx.dll_nrfwd.dll       "$DIS"     nvngx.dll_nrfwd.dll
  ok "active add-on: DLSS5-Reshade-AIO $AIO_VER"
else
  put dlss5-bridge.addon64      "$GAMEDIR" dlss5-bridge.addon64
  put dlssnr-linux.addon64      "$GAMEDIR" dlssnr-linux.addon64
  put nvngx.dll_nrfwd.dll       "$GAMEDIR" nvngx.dll_nrfwd.dll
  put standalone-dlssnr.addon64 "$DIS"     standalone-dlssnr.addon64
  put aio-nvngx.dll             "$DIS"     nvngx.dll
  ok "active add-ons: dlss5-bridge $BRIDGE_VER + addon-dlssnr-linux $DLSSNR_LINUX_VER"
fi

# ------------------------------------------------------- HLSL compiler
# Wine's built-in d3dcompiler_47 does not implement every HLSL attribute --
# [fastopt] among them -- and ReShade effects that use one fail to compile with
# "E5017: Aborting due to not yet implemented feature". Microsoft's
# redistributable compiler handles them. It is user-mode only and runs fine
# under Wine, unlike the D3D runtime DLLs, which must stay DXVK and vkd3d.
find_d3dcompiler() {
  # Every Steam library, not just this game's: libraryfolders.vdf lists them.
  # Paths contain spaces, so the search runs through -print0 rather than $(...).
  local vdf best="" bestsize=0 size f
  : > "$TMPROOTS"
  printf '%s\0' "$GAMEDIR" >> "$TMPROOTS"
  [ -n "${STEAMAPPS:-}" ] && printf '%s\0' "$STEAMAPPS" >> "$TMPROOTS"
  for vdf in "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf" \
             "$HOME/.steam/steam/steamapps/libraryfolders.vdf" \
             "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/libraryfolders.vdf"; do
    [ -f "$vdf" ] || continue
    sed -n 's/.*"path"[[:space:]]*"\(.*\)".*/\1\/steamapps/p' "$vdf" | tr '\n' '\0' >> "$TMPROOTS"
  done
  while IFS= read -r -d '' root; do
    [ -d "$root" ] || continue
    while IFS= read -r -d '' f; do
      case "$(file -b "$f" 2>/dev/null)" in *x86-64*) ;; *) continue ;; esac
      strings -a -el "$f" 2>/dev/null | grep -q 'Redistribution' || continue
      size="$(stat -c%s "$f")"
      if [ "$size" -gt "$bestsize" ]; then best="$f"; bestsize="$size"; fi
    done < <(find "$root" -maxdepth 4 -name d3dcompiler_47.dll -print0 2>/dev/null)
  done < "$TMPROOTS"
  [ -n "$best" ] && printf '%s\n' "$best"
}

if [ -f "$GAMEDIR/d3dcompiler_47.dll" ] && \
   strings -a -el "$GAMEDIR/d3dcompiler_47.dll" 2>/dev/null | grep -q 'Redistribution'; then
  ok "d3dcompiler_47.dll already in place"
else
  DXC="$(find_d3dcompiler || true)"
  if [ -n "${DXC:-}" ]; then
    install -m 644 "$DXC" "$GAMEDIR/d3dcompiler_47.dll"
    DXCVER="$(strings -a -el "$GAMEDIR/d3dcompiler_47.dll" 2>/dev/null | grep -A1 -m1 '^FileVersion$' | tail -1)"
    ok "d3dcompiler_47.dll ${DXCVER:-} (from ${DXC#$HOME/})"
  else
    warn "no Microsoft d3dcompiler_47.dll found on this system."
    warn "Wine's built-in one cannot compile every ReShade effect; vort_Motion.fx"
    warn "in particular fails with E5017 and the nr mode then has no motion vectors."
    warn "Install it into the prefix with:"
    warn "  WINEPREFIX=\"${PREFIX:-<prefix>}\" winetricks -q d3dcompiler_47"
  fi
fi

# ---------------------------------------------------------------- shaders
SH="$GAMEDIR/reshade-shaders/Shaders"
TX="$GAMEDIR/reshade-shaders/Textures"
mkdir -p "$SH" "$TX"
# v2.2.1 ships StandaloneBoundary.fx alongside DLSS5_AIO_Feed.fx.
[ -d "$AIOTMP/reshade-shaders/Shaders" ] && cp -a "$AIOTMP/reshade-shaders/Shaders"/. "$SH/"

# Standard collection goes flat into Shaders/, mainly for ReShade.fxh.
if [ ! -f "$SH/ReShade.fxh" ]; then
  tmp="$(mktemp -d)"; tar xzf "$CACHE/reshade-shaders-slim.tar.gz" -C "$tmp"
  root="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -1)"
  [ -d "$root/Shaders" ]  && cp -a "$root/Shaders"/.  "$SH/"
  [ -d "$root/Textures" ] && cp -a "$root/Textures"/. "$TX/"
  rm -rf "$tmp"
fi
ok "shaders: ReShade standard collection (slim)"
[ -d "$AIOTMP/licenses" ] && cp -a "$AIOTMP/licenses" "$GAMEDIR/" && ok "licenses/ from the AIO package"

# vort_Shaders, textures included, only for the nr mode. In dlaa mode it is dead
# weight: ReShade compiles every effect in the search path whether the technique
# is enabled or not, and vort_Motion.fx does not build on every runtime
# (E5017, attribute 'fastopt').
if [ "$MODE" = nr ]; then
  if [ ! -d "$SH/vort_Shaders" ]; then
    tmp="$(mktemp -d)"; tar xzf "$CACHE/vort_Shaders.tar.gz" -C "$tmp"
    root="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -1)"
    mkdir -p "$SH/vort_Shaders"
    if [ -d "$root/Shaders" ]; then cp -a "$root/Shaders"/. "$SH/vort_Shaders/"
    else                            cp -a "$root"/.         "$SH/vort_Shaders/"; fi
    [ -d "$root/Textures" ] && cp -a "$root/Textures"/. "$TX/"
    rm -rf "$tmp"
  fi
  ok "shaders: vort_Shaders and textures"
else
  rm -rf "$SH/vort_Shaders"
  ok "shaders: vort_Shaders skipped, dlaa does not use it"
fi

# ---------------------------------------------------------------- config
cat > "$GAMEDIR/ReShade.ini" <<'INI'
[GENERAL]
EffectSearchPaths=.\reshade-shaders\Shaders\**
TextureSearchPaths=.\reshade-shaders\Textures\**
PresetPath=.\ReShadePreset.ini
PerformanceMode=0
PreprocessorDefinitions=RESHADE_DEPTH_LINEARIZATION_FAR_PLANE=1000.0,RESHADE_DEPTH_INPUT_IS_UPSIDE_DOWN=0,RESHADE_DEPTH_INPUT_IS_REVERSED=1,RESHADE_DEPTH_INPUT_IS_LOGARITHMIC=0

[INPUT]
GamepadNavigation=0
KeyOverlay=36,0,0,0

[ADDON]
DisabledAddons=

[GENERIC_DEPTH]
DepthCopyBeforeClears=1
DepthCopyAtClearIndex=0
UseAspectRatioHeuristics=1

[Standalone.DLSSNR]
NeuralRendering=@NR_AIO@
EarlyProxyInitialization=0

[ADDON_DLSSNR_LINUX]
DetailStrength=1.000000
ColourStrength=0.000000
HighlightGuard=2.000000
WhitePointScale=1.000000
Intensity=1.000000
StructureIntensity=1.000000
GlobalIntensity=1.000000
Preset=0
Style=0

[PROXY]
EnableProxyLibrary=0
ProxyLibrary=
INI
# The AIO creates feature 18 through the driver's NGX dispatch. Ada refuses it
# (measured: 0xBAD00001) and only DLAA runs. On Blackwell the attempt is worth
# making; if it fails the add-on logs it and carries on with DLAA.
if [ "$GPUARCH" = blackwell ]; then NR_AIO=1; else NR_AIO=0; fi
sed -i "s/^NeuralRendering=@NR_AIO@/NeuralRendering=$NR_AIO/" "$GAMEDIR/ReShade.ini"
chmod 644 "$GAMEDIR/ReShade.ini"
ok "ReShade.ini (AIO NeuralRendering=$NR_AIO)"

# vort_MotionEffects provides MotVectTexVort. Without it the bridge builds no
# substitute contract and logs "motion vectors no".
if [ "$MODE" = nr ]; then
  printf 'Techniques=vort_MotionEffects@vort_Motion.fx\n' > "$GAMEDIR/ReShadePreset.ini"
  ok "ReShadePreset.ini (vort_MotionEffects enabled)"
else
  printf 'Techniques=\n' > "$GAMEDIR/ReShadePreset.ini"
  ok "ReShadePreset.ini (no technique, dlaa does not need one)"
fi
chmod 644 "$GAMEDIR/ReShadePreset.ini"

CFGSRC=""
[ -f "$GAMEDIR/dlss5-bridge.cfg" ] && CFGSRC="$GAMEDIR/dlss5-bridge.cfg"
[ -z "$CFGSRC" ] && [ -f "$DIS/dlss5-bridge.cfg" ] && CFGSRC="$DIS/dlss5-bridge.cfg"
if [ -n "$CFGSRC" ]; then
  ok "dlss5-bridge.cfg exists, left untouched"
else
cat > "$GAMEDIR/dlss5-bridge.cfg" <<'CFG'
# dlss5-bridge keep
# Game without its own DLSS -> substitute contract (DLAA at back buffer size).
synth=1
source=auto
stage=3
mode=2
ofa_grid=1
ofa_perf=5
# unwrap=0 is mandatory under Proton: with unwrap=1 ReShade's
# convert_to_original_cpu_descriptor_handle faults on vkd3d handles (0xC0000005).
unwrap=0
CFG
  CFGSRC="$GAMEDIR/dlss5-bridge.cfg"
  ok "dlss5-bridge.cfg written (unwrap=0)"
fi
if [ "$MODE" = nr ]; then CFGDST="$GAMEDIR/dlss5-bridge.cfg"; else CFGDST="$DIS/dlss5-bridge.cfg"; fi
[ "$CFGSRC" != "$CFGDST" ] && mv -f "$CFGSRC" "$CFGDST"
chmod 644 "$CFGDST"

# ---------------------------------------------------------------- driverstore
if [ -n "$PREFIX" ]; then
  step "Creating the DriverStore shim in the prefix"
  DS="$PREFIX/drive_c/windows/system32/DriverStore/FileRepository/nvlti.inf_amd64_a1b2c3d4e5f60789"
  mkdir -p "$DS"
  for f in _nvngx.dll nvngx.dll nvngx_dlssg.dll; do
    [ -f "$NVWINE/$f" ] && install -m 644 "$NVWINE/$f" "$DS/$f" && ok "$f"
  done
  say "  The add-ons look for the NGX core under"
  say "  C:\\windows\\system32\\DriverStore\\FileRepository\\nv*.inf_amd64_*"
  say "  Wine has no such directory. Without this copy: 0x000000B7."
fi

# ---------------------------------------------------------------- done
cat > "$STATE" <<STATEEOF
installer=$VERSION
date=$(date -Iseconds)
exe=$EXE
mode=$MODE
model=$MODEL
prefix=${PREFIX:-none}
STATEEOF

step "Done"
say ""
say "Set the game's Steam launch options (Properties -> General):"
say ""
say "    PROTON_FORCE_NVAPI=1 WINEDLLOVERRIDES=dxgi=n,b %command%"
say ""
say "  PROTON_FORCE_NVAPI is the GE-Proton and proton-cachyos spelling;"
say "  Valve's Proton calls it PROTON_ENABLE_NVAPI."
say "  Without dxgi=n,b, Wine loads its own dxgi and ReShade is never called."
say ""
say "In game, Home opens the ReShade overlay."
say ""
say "After the first launch:"
if [ "$MODE" = nr ]; then
  say "    grep -a 'nr-fwd' \"$GAMEDIR/ReShade.log\""
  say "  CreateFeature(18) => 0x1 means neural rendering is running."
  say "  0xbad00001 means the model build does not match the GPU; try the"
  say "  other one (--model ref or --model rtx40)."
else
  say "    grep -a 'DLAA' \"$GAMEDIR/ReShade.log\" | tail -3"
  say "  A line reading DLAA=<number>ms means the SR pipeline is running."
fi
say ""
say "Switch mode without downloading:  $0 --mode nr|dlaa \"$EXE\""
say "Remove:                           $0 --uninstall \"$EXE\""
