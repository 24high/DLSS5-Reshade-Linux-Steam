#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Dennis Michael Heine
#
# dlss5-install-x86.sh -- DLSS 5 / DLAA for a 32-bit Windows game under Steam Proton
#
#   dlss5-install-x86.sh [options] /path/to/game32.exe
#
# NGX exists only as 64-bit code: NVIDIA ships no 32-bit runtime, the driver
# places _nvngx.dll in system32 and leaves syswow64 empty, and the DLSS SDK has
# no Windows_x86 build. DLSS5-Reshade-AIO works around that with two processes.
# A 32-bit add-on loads inside the game and starts a 64-bit wrapper that does
# the NGX work, so the game folder ends up with two ReShade installations:
#
#   game.exe
#   dxgi.dll                     32-bit ReShade, add-on build
#   standalone-dlssnr.addon32    the carrier
#   host64/
#     dxgi.dll                   64-bit ReShade, add-on build
#     AIO DLSS5 32-bit Wrapper.exe
#     standalone-dlssnr.addon64  where neural rendering actually runs
#     nvngx_dlssnr.dll  nvngx_dlss.dll  nvngx_dlssg.dll
#
# This is the AIO path only. The nr mode of dlss5-install.sh is not available
# here: dlss5-bridge and addon-dlssnr-linux ship 64-bit add-ons exclusively.
#
# For a D3D9 game pass --api d3d9. The proxy beside the game must then be named
# d3d9.dll, and no second proxy named dxgi.dll may sit next to it -- the bridge
# needs Windows' real DXGI.
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

VERSION=1.0

RESHADE_VER=6.8.0
AIO_VER=v2.2.1
DLSS_SDK_VER=v310.7.0

MODEL_REF_SHA=e16bcf15e16e13f527491cdf7845b2fe6521a738d8f7c9c721866a8496e1fc8e
MODEL_R40_SHA=4b8d19bc3eff58a084f5eca7489c921501c203450169fb82ff4f649a4482ba05

API=dxgi
MODEL=auto
PREFIX=""
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/dlss5-installer"
DO_UNINSTALL=0
ASSUME_YES=0
EXE=""
GPUARCH=unknown
GPUNAME=""
CC=""

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
  --api dxgi|d3d9    Name of the ReShade proxy beside the game (default: dxgi).
                     Use d3d9 for a native Direct3D 9 game.
  --model auto|rtx40|ref
                     Neural rendering model build (default: auto), chosen from
                     the GPU compute capability: 8.9 (Ada) -> rtx40,
                     10.0 and above (Blackwell) -> ref.
  --prefix PATH      Proton prefix, if it cannot be derived from the exe path
  --cache DIR        Download cache (default: ~/.cache/dlss5-installer)
  --uninstall        Remove the installation and restore the backup
  -y, --yes          Do not prompt
  -h, --help         This help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --api)       API="${2:?}"; shift 2 ;;
    --model)     MODEL="${2:?}"; shift 2 ;;
    --prefix)    PREFIX="${2:?}"; shift 2 ;;
    --cache)     CACHE="${2:?}"; shift 2 ;;
    --uninstall) DO_UNINSTALL=1; shift ;;
    -y|--yes)    ASSUME_YES=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          die "Unknown option: $1  (--help)" ;;
    *)           [ -z "$EXE" ] || die "Give exactly one executable."; EXE="$1"; shift ;;
  esac
done

[ -n "$EXE" ] || { usage; exit 1; }
case "$API"   in dxgi|d3d9) ;; *) die "--api must be dxgi or d3d9." ;; esac
case "$MODEL" in auto|ref|rtx40) ;; *) die "--model must be auto, ref or rtx40." ;; esac
[ -f "$EXE" ] || die "Executable not found: $EXE"
EXE="$(readlink -f "$EXE")"
GAMEDIR="$(dirname "$EXE")"
HOST64="$GAMEDIR/host64"
STATE="$GAMEDIR/.dlss5-install.state"

OWNED="dxgi.dll
d3d9.dll
d3dcompiler_47.dll
ReShade.ini
ReShadePreset.ini
standalone-dlssnr.addon32
dlss5-aio-x86.cfg"

# ---------------------------------------------------------------- preflight
step "Checking requirements"

MISSING=""
for t in curl unzip sha256sum tar; do
  command -v "$t" >/dev/null || MISSING="$MISSING $t"
done
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
    *80386*)  ok "32-bit executable: $(basename "$EXE")" ;;
    *x86-64*) die "That is a 64-bit executable. Use dlss5-install.sh for it -- it
  offers the nr mode, which this script cannot." ;;
    *)        warn "could not determine bitness, continuing" ;;
  esac
fi

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
  [ -n "$NVWINE" ] || die "_nvngx.dll not found. This needs the proprietary NVIDIA driver.
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

if [ "$MODEL" = auto ]; then
  case "$GPUARCH" in
    blackwell) MODEL=ref;   ok "model build selected: ref (verified on RTX 50)" ;;
    ada)       MODEL=rtx40; ok "model build selected: rtx40 (verified on RTX 40)" ;;
    *)         MODEL=rtx40
               warn "architecture not conclusive ($GPUARCH), using rtx40"
               warn "if the log shows 0xBAD00001, try the other build: --model ref" ;;
  esac
fi

if [ -z "$PREFIX" ]; then
  d="$GAMEDIR"
  while [ "$d" != "/" ]; do
    p="$(dirname "$d")"
    if [ "$(basename "$p")" = "common" ] && [ "$(basename "$(dirname "$p")")" = "steamapps" ]; then
      STEAMAPPS="$(dirname "$p")"
      APPID="$(grep -l "\"installdir\"[[:space:]]*\"$(basename "$d")\"" "$STEAMAPPS"/appmanifest_*.acf 2>/dev/null \
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
  warn "Without it the add-on fails with 0x000000B7. Pass --prefix to fix."
fi

# ---------------------------------------------------------------- uninstall
if [ "$DO_UNINSTALL" = 1 ]; then
  step "Removing the installation from $GAMEDIR"
  for f in $OWNED ReShade.log ReShade.log1; do
    [ -e "$GAMEDIR/$f" ] && rm -f "$GAMEDIR/$f" && say "  removed: $f"
  done
  rm -rf "$HOST64" "$GAMEDIR/reshade-shaders" "$GAMEDIR/licenses"
  rm -f "$STATE"
  say "  removed: host64/, reshade-shaders/, licenses/"
  # A dxgi.dll moved aside for a D3D9 game belongs back where it was.
  if [ -f "$GAMEDIR/dxgi.dll.disabled-by-dlss5" ]; then
    mv -f "$GAMEDIR/dxgi.dll.disabled-by-dlss5" "$GAMEDIR/dxgi.dll"
    say "  restored: dxgi.dll (was moved aside for the D3D9 proxy)"
  fi
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
say "  proxy      : $API.dll (32-bit ReShade) + host64/dxgi.dll (64-bit ReShade)"
say "  model      : $MODEL"
say "  GPU        : ${GPUNAME:-unknown} (${GPUARCH})"
say "  cache      : $CACHE"
if [ "$ASSUME_YES" = 0 ]; then
  printf '\nContinue? [y/N] '
  read -r a; case "$a" in y|Y|j|J) ;; *) die "Aborted." ;; esac
fi

mkdir -p "$CACHE"
TMPROOTS="$(mktemp)"; trap 'rm -f "$TMPROOTS"' EXIT

fetch() {
  local out="$CACHE/$1" url="$2" want="${3:-}"
  if [ -s "$out" ]; then
    if [ -z "$want" ] || [ "$(sha256sum "$out" | cut -d' ' -f1)" = "$want" ]; then
      ok "cached: $1"; return 0
    fi
    warn "cached $1 does not match, downloading again"; rm -f "$out"
  fi
  say "  downloading $1 ..."
  curl -fL --retry 3 --progress-bar -o "$out.part" "$url" || die "Download failed: $url"
  if [ -n "$want" ] && [ "$(sha256sum "$out.part" | cut -d' ' -f1)" != "$want" ]; then
    rm -f "$out.part"; die "Checksum mismatch for $1."
  fi
  mv "$out.part" "$out"; ok "downloaded: $1"
}

# find_d3dcompiler <32|64> -- newest Microsoft redistributable of that bitness
find_d3dcompiler() {
  local want="$1" vdf best="" bestsize=0 size f pat
  case "$want" in 32) pat='*80386*' ;; 64) pat='*x86-64*' ;; esac
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
      case "$(file -b "$f" 2>/dev/null)" in $pat) ;; *) continue ;; esac
      strings -a -el "$f" 2>/dev/null | grep -q 'Redistribution' || continue
      size="$(stat -c%s "$f")"
      if [ "$size" -gt "$bestsize" ]; then best="$f"; bestsize="$size"; fi
    done < <(find "$root" -maxdepth 4 -name d3dcompiler_47.dll -print0 2>/dev/null)
  done < "$TMPROOTS"
  [ -n "$best" ] && printf '%s\n' "$best"
}

# ---------------------------------------------------------------- downloads
step "Downloading dependencies"

if [ -s "$CACHE/ReShade32.dll" ] && [ -s "$CACHE/ReShade64.dll" ]; then
  ok "cached: ReShade32.dll and ReShade64.dll"
else
  fetch "ReShade_Setup_${RESHADE_VER}_Addon.exe" \
        "https://reshade.me/downloads/ReShade_Setup_${RESHADE_VER}_Addon.exe"
fi

fetch "DLSS5-ReShade-AIO-${AIO_VER}-32-bit.zip" \
      "https://github.com/kibblerz/DLSS5-Reshade-AIO/releases/download/${AIO_VER}/DLSS5-ReShade-AIO-${AIO_VER}-32-bit.zip"

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
  MODELFILE=model-ref.dll
else
  ensure_model nvngx_dlssnr_310.8.0-RTX40.zip \
    "https://github.com/RankFTW/rhi-repo/releases/download/dlssnr-310.8.0-RTX40/nvngx_dlssnr_310.8.0-RTX40.zip" \
    "$MODEL_R40_SHA" model-rtx40.dll
  MODELFILE=model-rtx40.dll
fi

fetch "nvngx_dlss.dll" \
      "https://raw.githubusercontent.com/NVIDIA/DLSS/${DLSS_SDK_VER}/lib/Windows_x86_64/rel/nvngx_dlss.dll"

fetch "reshade-shaders-slim.tar.gz" \
      "https://codeload.github.com/crosire/reshade-shaders/tar.gz/refs/heads/slim"

# ---------------------------------------------------------------- unpacking
step "Preparing files"

if [ ! -s "$CACHE/ReShade32.dll" ] || [ ! -s "$CACHE/ReShade64.dll" ]; then
  ( cd "$CACHE" && "$SEVENZIP" e -y "ReShade_Setup_${RESHADE_VER}_Addon.exe" ReShade32.dll ReShade64.dll >/dev/null ) \
    || die "Could not extract the ReShade DLLs from the setup."
fi
ok "ReShade32.dll ($(stat -c%s "$CACHE/ReShade32.dll") bytes), ReShade64.dll ($(stat -c%s "$CACHE/ReShade64.dll") bytes)"

# The AIO zip stores paths with backslashes. unzip resolves them but warns and
# exits 1, and it restores directory modes that block traversal.
AIOTMP="$(mktemp -d)"; trap 'rm -f "$TMPROOTS"; rm -rf "$AIOTMP"' EXIT
unzip -q -o "$CACHE/DLSS5-ReShade-AIO-${AIO_VER}-32-bit.zip" -d "$AIOTMP" || true
chmod -R u+rwX "$AIOTMP"
[ -f "$AIOTMP/standalone-dlssnr.addon32" ] || die "AIO zip did not unpack as expected."
[ -d "$AIOTMP/host64" ]                    || die "AIO zip has no host64 directory."
ok "AIO ${AIO_VER} unpacked ($(find "$AIOTMP" -type f | wc -l) files)"

# ---------------------------------------------------------------- backup
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

cp -a "$AIOTMP/host64" "$GAMEDIR/"
cp -a "$AIOTMP/licenses" "$GAMEDIR/" 2>/dev/null || true
install -m 644 "$AIOTMP/standalone-dlssnr.addon32" "$GAMEDIR/standalone-dlssnr.addon32"
[ -f "$AIOTMP/dlss5-aio-x86.cfg" ] && [ ! -f "$GAMEDIR/dlss5-aio-x86.cfg" ] && \
  install -m 644 "$AIOTMP/dlss5-aio-x86.cfg" "$GAMEDIR/dlss5-aio-x86.cfg"
chmod -R u+rwX "$HOST64"
ok "standalone-dlssnr.addon32 and host64/ in place"

# 32-bit ReShade beside the game, 64-bit ReShade inside host64.
install -m 644 "$CACHE/ReShade32.dll" "$GAMEDIR/$API.dll"
install -m 644 "$CACHE/ReShade64.dll" "$HOST64/dxgi.dll"
ok "$API.dll (ReShade $RESHADE_VER, 32-bit) and host64/dxgi.dll (64-bit)"

# A D3D9 game must not have a second proxy named dxgi.dll beside it.
if [ "$API" = d3d9 ] && [ -f "$GAMEDIR/dxgi.dll" ]; then
  mv -f "$GAMEDIR/dxgi.dll" "$GAMEDIR/dxgi.dll.disabled-by-dlss5"
  warn "moved a stray dxgi.dll aside: it blocks the AIO bridge on D3D9"
fi

# NVIDIA runtimes belong inside host64, never beside the 32-bit executable.
install -m 644 "$CACHE/$MODELFILE"     "$HOST64/nvngx_dlssnr.dll"
install -m 644 "$CACHE/nvngx_dlss.dll" "$HOST64/nvngx_dlss.dll"
ok "host64/nvngx_dlssnr.dll (build: $MODEL), host64/nvngx_dlss.dll"
if [ -f "$NVWINE/nvngx_dlssg.dll" ]; then
  install -m 644 "$NVWINE/nvngx_dlssg.dll" "$HOST64/nvngx_dlssg.dll"
  ok "host64/nvngx_dlssg.dll (from the driver)"
fi

# Both ReShade instances need Microsoft's HLSL compiler, each in its own
# bitness: Wine's built-in one rejects attributes the effects use (E5017).
for bits in 32 64; do
  case "$bits" in 32) dst="$GAMEDIR/d3dcompiler_47.dll" ;; 64) dst="$HOST64/d3dcompiler_47.dll" ;; esac
  if [ -f "$dst" ] && strings -a -el "$dst" 2>/dev/null | grep -q 'Redistribution'; then
    ok "${bits}-bit d3dcompiler_47.dll already in place"; continue
  fi
  src="$(find_d3dcompiler "$bits" || true)"
  if [ -n "${src:-}" ]; then
    install -m 644 "$src" "$dst"
    ok "${bits}-bit d3dcompiler_47.dll (from ${src#$HOME/})"
  else
    warn "no ${bits}-bit Microsoft d3dcompiler_47.dll found on this system."
    warn "ReShade effects that use unimplemented attributes will fail with E5017."
    warn "  WINEPREFIX=\"${PREFIX:-<prefix>}\" winetricks -q d3dcompiler_47"
  fi
done

# ---------------------------------------------------------------- shaders
for base in "$GAMEDIR" "$HOST64"; do
  SH="$base/reshade-shaders/Shaders"; TX="$base/reshade-shaders/Textures"
  mkdir -p "$SH" "$TX"
  if [ ! -f "$SH/ReShade.fxh" ]; then
    tmp="$(mktemp -d)"; tar xzf "$CACHE/reshade-shaders-slim.tar.gz" -C "$tmp"
    root="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -1)"
    [ -d "$root/Shaders" ]  && cp -a "$root/Shaders"/.  "$SH/"
    [ -d "$root/Textures" ] && cp -a "$root/Textures"/. "$TX/"
    rm -rf "$tmp"
  fi
done
# The AIO's own effects: DLSS5_Feed* beside the game, DLSS5_AIO_Feed inside host64.
[ -d "$AIOTMP/reshade-shaders/Shaders" ] && \
  cp -a "$AIOTMP/reshade-shaders/Shaders"/. "$GAMEDIR/reshade-shaders/Shaders/"
[ -d "$AIOTMP/host64/reshade-shaders/Shaders" ] && \
  cp -a "$AIOTMP/host64/reshade-shaders/Shaders"/. "$HOST64/reshade-shaders/Shaders/"
chmod -R u+rwX "$GAMEDIR/reshade-shaders" "$HOST64/reshade-shaders"
ok "shaders: ReShade standard collection plus the AIO effects, in both trees"

# ---------------------------------------------------------------- config
cat > "$GAMEDIR/ReShade.ini" <<'INI'
[GENERAL]
EffectSearchPaths=.\reshade-shaders\Shaders\**
TextureSearchPaths=.\reshade-shaders\Textures\**
PresetPath=.\ReShadePreset.ini
PerformanceMode=0

[INPUT]
GamepadNavigation=0
KeyOverlay=36,0,0,0

[ADDON]
DisabledAddons=

[GENERIC_DEPTH]
DepthCopyBeforeClears=1
DepthCopyAtClearIndex=0
UseAspectRatioHeuristics=1

[PROXY]
EnableProxyLibrary=0
ProxyLibrary=
INI
chmod 644 "$GAMEDIR/ReShade.ini"
[ -f "$GAMEDIR/ReShadePreset.ini" ] || printf 'Techniques=\n' > "$GAMEDIR/ReShadePreset.ini"
chmod 644 "$GAMEDIR/ReShadePreset.ini"
ok "ReShade.ini and ReShadePreset.ini (host64 keeps the ones from the AIO zip)"

# ---------------------------------------------------------------- driverstore
if [ -n "$PREFIX" ]; then
  step "Creating the DriverStore shim in the prefix"
  DS="$PREFIX/drive_c/windows/system32/DriverStore/FileRepository/nvlti.inf_amd64_a1b2c3d4e5f60789"
  mkdir -p "$DS"
  for f in _nvngx.dll nvngx.dll nvngx_dlssg.dll; do
    [ -f "$NVWINE/$f" ] && install -m 644 "$NVWINE/$f" "$DS/$f" && ok "$f"
  done
  say "  The host64 process looks for the NGX core under"
  say "  C:\\windows\\system32\\DriverStore\\FileRepository\\nv*.inf_amd64_*"
  say "  Wine has no such directory. Without this copy: 0x000000B7."
fi

# ---------------------------------------------------------------- done
cat > "$STATE" <<STATEEOF
installer=dlss5-install-x86.sh $VERSION
date=$(date -Iseconds)
exe=$EXE
mode=aio-x86
api=$API
model=$MODEL
aio=$AIO_VER
prefix=${PREFIX:-none}
STATEEOF

if [ "$API" = d3d9 ]; then
  OVERRIDES='WINEDLLOVERRIDES="d3d9=n,b;dxgi=n,b"'
else
  OVERRIDES='WINEDLLOVERRIDES=dxgi=n,b'
fi

step "Done"
say ""
say "Set the game's Steam launch options (Properties -> General):"
say ""
say "    PROTON_FORCE_NVAPI=1 $OVERRIDES %command%"
say ""
say "  PROTON_FORCE_NVAPI is the GE-Proton and proton-cachyos spelling;"
say "  Valve's Proton calls it PROTON_ENABLE_NVAPI."
say "  The override is inherited by the 64-bit host process, which needs dxgi."
say ""
say "In game, Home opens the ReShade overlay. The AIO page sits in the game's"
say "own Add-ons tab; the 32-bit add-on starts the 64-bit wrapper by itself."
say ""
say "After the first launch:"
say "    grep -a 'DLAA\\|FAILED' \"$GAMEDIR/ReShade.log\" | tail -5"
say "    ls -la \"$HOST64\"/*.log 2>/dev/null"
say ""
say "Remove:  $0 --uninstall \"$EXE\""
