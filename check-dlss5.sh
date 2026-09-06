#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Dennis Michael Heine
#
# check-dlss5.sh -- report the state of a dlss5-install.sh installation
#
#   check-dlss5.sh [/path/to/game.exe | /path/to/gamedir]
#
# With no argument, looks for .dlss5-install.state next to the script's parent
# directory, then in the current directory. Reads the installed mode, model and
# Proton prefix from that file; falls back to sniffing the game directory when
# the file is absent (installations made before the installer existed).
#
set -uo pipefail

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

MODEL_REF_SHA=e16bcf15e16e13f527491cdf7845b2fe6521a738d8f7c9c721866a8496e1fc8e
MODEL_R40_SHA=4b8d19bc3eff58a084f5eca7489c921501c203450169fb82ff4f649a4482ba05
NVWINE="${NVWINE_DIR:-}"
if [ -z "$NVWINE" ]; then
  for c in /usr/lib/x86_64-linux-gnu/nvidia/wine /usr/lib64/nvidia/wine \
           /usr/lib/nvidia/wine /usr/lib/nvidia-current/wine; do
    [ -f "$c/_nvngx.dll" ] && { NVWINE="$c"; break; }
  done
fi

FAILED=0
sec()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; FAILED=$((FAILED+1)); }
info() { printf '  [--]   %s\n' "$*"; }
quote(){ sed 's/^/         /'; }

# ------------------------------------------------------------ locate install
GAMEDIR=""
case "${1:-}" in
  "")  d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
       for c in "$d/.." "$d/../x64" "$PWD"; do
         [ -f "$c/.dlss5-install.state" ] && GAMEDIR="$(cd "$c" && pwd)" && break
       done
       if [ -z "$GAMEDIR" ]; then
         for c in "$d/../x64" "$d/.." "$PWD"; do
           [ -f "$c/dxgi.dll" ] && GAMEDIR="$(cd "$c" && pwd)" && break
         done
       fi
       [ -n "$GAMEDIR" ] || { echo "No installation found. Pass the game exe or directory." >&2; exit 1; } ;;
  -h|--help) awk 'NR==1{next} /^# *(SPDX|Copyright)/{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
  *)   if   [ -f "$1" ]; then GAMEDIR="$(cd "$(dirname "$1")" && pwd)"
       elif [ -d "$1" ]; then GAMEDIR="$(cd "$1" && pwd)"
       else echo "Not found: $1" >&2; exit 1
       fi ;;
esac

STATE="$GAMEDIR/.dlss5-install.state"
MODE=""; MODEL=""; PREFIX=""; EXE=""; INSTALLED=""
if [ -f "$STATE" ]; then
  MODE="$(sed -n 's/^mode=//p'   "$STATE")"
  MODEL="$(sed -n 's/^model=//p' "$STATE")"
  PREFIX="$(sed -n 's/^prefix=//p' "$STATE")"
  EXE="$(sed -n 's/^exe=//p'     "$STATE")"
  INSTALLED="$(sed -n 's/^date=//p;s/^datum=//p' "$STATE")"  # datum= is the pre-1.1 spelling
  case "$PREFIX" in none|keiner) PREFIX="" ;; esac
else
  # No state file: work out the mode from what is present.
  if   [ -f "$GAMEDIR/dlss5-bridge.addon64" ];      then MODE=nr
  elif [ -f "$GAMEDIR/standalone-dlssnr.addon64" ]; then MODE=dlaa
  fi
fi

# Prefix not recorded: derive it from the Steam library holding the exe.
if [ -z "$PREFIX" ]; then
  d="$GAMEDIR"
  while [ "$d" != "/" ]; do
    p="$(dirname "$d")"
    if [ "$(basename "$p")" = common ] && [ "$(basename "$(dirname "$p")")" = steamapps ]; then
      sa="$(dirname "$p")"
      id="$(grep -l "\"installdir\"[[:space:]]*\"$(basename "$d")\"" "$sa"/appmanifest_*.acf 2>/dev/null \
            | head -1 | sed 's/.*appmanifest_\([0-9]*\)\.acf/\1/')"
      [ -n "$id" ] && [ -d "$sa/compatdata/$id/pfx" ] && PREFIX="$sa/compatdata/$id/pfx"
      break
    fi
    d="$p"
  done
fi

sec "Installation"
info "directory : $GAMEDIR"
[ -n "$EXE" ]       && info "exe       : $EXE"
[ -n "$INSTALLED" ] && info "installed : $INSTALLED"
if [ -n "$MODE" ]; then
  info "mode      : $MODE${STATE_MISSING:-}$([ -f "$STATE" ] || printf ' (guessed, no state file)')"
else
  bad "no DLSS 5 add-on found in this directory"
fi
[ -n "$PREFIX" ] && info "prefix    : $PREFIX" || bad "Proton prefix not found"

# ------------------------------------------------------------------- files
sec "Files"
case "$MODE" in
  nr)   WANT="dxgi.dll dlss5-bridge.addon64 dlssnr-linux.addon64 nvngx.dll_nrfwd.dll nvngx_dlss.dll nvngx_dlssnr.dll" ;;
  dlaa) WANT="dxgi.dll standalone-dlssnr.addon64 nvngx.dll nvngx_dlss.dll nvngx_dlssnr.dll nvngx_dlssg.dll" ;;
  *)    WANT="dxgi.dll" ;;
esac
for f in $WANT; do
  if [ -f "$GAMEDIR/$f" ]; then ok "$f ($(stat -c%s "$GAMEDIR/$f") bytes)"; else bad "$f missing"; fi
done

# Only one DLSS 5 add-on may sit in the folder; two make the feature create
# fault inside D3D12Core (dlss5-bridge #16).
n=0
for f in dlss5-bridge.addon64 standalone-dlssnr.addon64; do
  [ -f "$GAMEDIR/$f" ] && n=$((n+1))
done
[ "$n" -gt 1 ] && bad "two DLSS 5 add-ons present at once -- feature create will fault"

# --------------------------------------------------------------- compiler
sec "HLSL compiler"
D="$GAMEDIR/d3dcompiler_47.dll"
if [ -f "$D" ]; then
  if strings -a -el "$D" 2>/dev/null | grep -q 'Redistribution'; then
    v="$(strings -a -el "$D" 2>/dev/null | grep -A1 -m1 '^FileVersion$' | tail -1)"
    ok "Microsoft d3dcompiler_47.dll ${v:-}"
  else
    bad "d3dcompiler_47.dll present but not the Microsoft redistributable"
  fi
else
  bad "no d3dcompiler_47.dll next to the executable"
  info "Wine's built-in compiler rejects some HLSL attributes (E5017, 'fastopt'),"
  info "which breaks vort_Motion.fx and leaves the bridge without motion vectors"
fi

# ------------------------------------------------------------------- model
sec "Neural rendering model"
h="$(sha256sum "$GAMEDIR/nvngx_dlssnr.dll" 2>/dev/null | cut -d' ' -f1)"
case "$h" in
  "$MODEL_REF_SHA") ok  "310.8.0 reference build (verified on RTX 50 / Blackwell)"; HAVE=ref ;;
  "$MODEL_R40_SHA") ok  "310.8.0-RTX40 build (verified on RTX 40 / Ada)";           HAVE=rtx40 ;;
  "")               bad "nvngx_dlssnr.dll missing";                                  HAVE="" ;;
  *)                bad "unknown build, sha256 $h";                                  HAVE="?" ;;
esac
if command -v nvidia-smi >/dev/null 2>&1; then
  CC="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1)"
  GPU="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
  case "$CC" in
    8.9)                   ARCH=ada;       WANTM=rtx40 ;;
    1[0-9].*|[2-9][0-9].*) ARCH=blackwell; WANTM=ref ;;
    *)                     ARCH="other";   WANTM="" ;;
  esac
  info "$GPU (CC $CC, $ARCH)"
  if [ -n "$WANTM" ] && [ -n "$HAVE" ] && [ "$HAVE" != "$WANTM" ]; then
    bad "$ARCH needs the '$WANTM' build -- the other one answers 0xBAD00001"
  fi
fi

# -------------------------------------------------------------- driverstore
sec "DriverStore shim"
if [ -n "$PREFIX" ]; then
  DS="$(ls -d "$PREFIX"/drive_c/windows/system32/DriverStore/FileRepository/nv*.inf_amd64_* 2>/dev/null | head -1)"
  if [ -n "$DS" ] && [ -f "$DS/_nvngx.dll" ]; then
    a="$(stat -c%s "$DS/_nvngx.dll")"
    b="$(stat -c%s "$NVWINE/_nvngx.dll" 2>/dev/null || echo 0)"
    if [ "$a" = "$b" ]; then
      ok "_nvngx.dll matches the installed driver"
    else
      bad "_nvngx.dll is $a bytes, driver ships $b -- rerun the installer after a driver update"
    fi
  else
    bad "no nv*.inf_amd64_* package in the prefix -- the add-on fails with 0x000000B7"
  fi
else
  info "skipped, no prefix"
fi

# ---------------------------------------------------------------- reshade log
sec "ReShade"
RL="$GAMEDIR/ReShade.log"
if [ -f "$RL" ]; then
  line="$(grep -a "Initializing crosire" "$RL" | tail -1)"
  if [ -n "$line" ]; then
    ver="$(printf '%s\n' "$line" | sed "s/.*ReShade version '//; s/'.*//")"
    host="$(printf '%s\n' "$line" | sed "s/.*into '//; s/' (.*//" | tr '\\\\' '/')"
    info "ReShade $ver"
    case "$host" in
      *[Ll]auncher*) bad "loaded into the launcher, not the game client -- point the installer at the real client exe" ;;
      *)             ok "injected into $(basename "$host")" ;;
    esac
  fi
  a="$(grep -ac 'Registered add-on' "$RL")"
  [ "$a" -gt 0 ] && ok "$a add-on registration(s)" || bad "no add-on registered"
  grep -a 'Registered add-on' "$RL" | sed 's/.*Registered add-on //' | sort -u | quote
  e="$(grep -aE '\| ERROR \|' "$RL" | grep -avE 'Failed to install hook for D3D10' | tail -5)"
  if [ -n "$e" ]; then
    bad "errors in ReShade.log:"
    printf '%s\n' "$e" | sed 's/.*| ERROR | //' | quote
  else
    ok "no errors (D3D10 hook noise ignored)"
  fi
else
  bad "ReShade.log missing -- ReShade never loaded"
  info "check the Steam launch options: WINEDLLOVERRIDES=dxgi=n,b %command%"
fi

# ------------------------------------------------------------ mode specifics
if [ "$MODE" = nr ]; then
  sec "Neural rendering (addon-dlssnr-linux)"
  c="$(grep -a 'nr-fwd: CreateFeature(18)' "$RL" 2>/dev/null | tail -1)"
  if [ -z "$c" ]; then
    bad "no CreateFeature(18) in the log -- the NGX hooks never fired"
    info "the bridge must be the one driving NGX; the AIO add-on bypasses the exports"
  elif printf '%s\n' "$c" | grep -q '0x1 (Success)'; then
    ok "CreateFeature(18) succeeded"
    last="$(grep -a 'nr-fwd: EvaluateFeature' "$RL" | tail -1 | sed 's/.*EvaluateFeature #//; s/ .*//')"
    f="$(grep -ac 'nr-fwd: EvaluateFeature .* => 0x[^1]' "$RL")"
    [ -n "$last" ] && ok "$last evaluates, $f failures"
  else
    bad "$(printf '%s\n' "$c" | sed 's/.*nr-fwd: //')"
    info "wrong model build for this GPU -- rerun the installer with --model auto"
  fi
  grep -a 'NOT the tested model build' "$RL" >/dev/null 2>&1 && \
    info "the add-on flags this model as untested; that warning is expected on the RTX40 build"

  sec "Bridge (dlss5-bridge)"
  BL="$GAMEDIR/dlss5-bridge.log"
  if [ -f "$BL" ]; then
    grep -aq 'unwrap=0' "$BL" && ok "unwrap=0 in effect" \
                              || bad "unwrap is not 0 -- ReShade will fault in the descriptor converter"
    grep -a 'exception\|faulted in\|disabling to protect' "$BL" | tail -3 | quote
    grep -a 'frames delivered so far' "$BL" | tail -1 | sed 's/^/  /'
    grep -a 'frames: bridge CPU' "$BL" | tail -1 | sed 's/^/  /'
  else
    bad "dlss5-bridge.log missing -- the bridge never loaded"
  fi

elif [ "$MODE" = dlaa ]; then
  sec "Super resolution (DLSS5-Reshade-AIO)"
  SL=""
  [ -n "$PREFIX" ] && SL="$PREFIX/drive_c/users/steamuser/AppData/Local/RHI/Logs/standalone-dlssnr.log"
  if [ -n "$SL" ] && [ -f "$SL" ]; then
    grep -aq 'NGX core: LoadLibraryExW.*error=0' "$SL" && ok "NGX core loaded from the DriverStore shim" \
                                                       || bad "NGX core did not load"
    grep -a 'CreateFeature(feature=SuperSampling)' "$SL" | tail -1 | sed 's/^  */  /' | quote
    grep -a 'FAILED at' "$SL" | tail -2 | quote
    grep -a 'performance telemetry' "$SL" | tail -1 | \
      sed 's/.*GPU /  GPU /; s/; skips.*//' | quote
  else
    bad "standalone-dlssnr.log missing"
  fi
fi

# ------------------------------------------------------------------- verdict
sec "Result"
if [ "$FAILED" -eq 0 ]; then
  ok "no problems found"
else
  bad "$FAILED check(s) failed"
fi
exit $((FAILED > 0))
