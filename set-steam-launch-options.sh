#!/usr/bin/env bash
#
# set-steam-launch-options.sh -- write the launch options for one Steam AppID
#
#   set-steam-launch-options.sh <appid>
#
# Steam must be closed: it rewrites localconfig.vdf on exit and would discard
# the change. Setting the options by hand in the game's properties does the
# same job and needs no script.
#
set -euo pipefail

OPTS='PROTON_FORCE_NVAPI=1 WINEDLLOVERRIDES=dxgi=n,b %command%'
APPID="${1:?usage: $(basename "$0") <appid>}"

case "$APPID" in ''|*[!0-9]*) echo "AppID must be numeric." >&2; exit 1 ;; esac
if pgrep -x steam >/dev/null; then
  echo "Steam is still running. Close it completely and try again." >&2
  exit 1
fi

shopt -s nullglob
found=0
for CFG in "$HOME"/.local/share/Steam/userdata/*/config/localconfig.vdf \
           "$HOME"/.steam/steam/userdata/*/config/localconfig.vdf; do
  [ -f "$CFG" ] || continue
  cp -a "$CFG" "$CFG.bak-$(date +%Y%m%d-%H%M%S)"
  APPID="$APPID" OPTS="$OPTS" python3 - "$CFG" <<'PY'
import os, re, sys
path  = sys.argv[1]
appid = os.environ["APPID"]
opts  = os.environ["OPTS"]
text  = open(path, encoding="utf-8", errors="surrogateescape").read()

m = re.search(r'^(\t+)"%s"\n\1\{\n' % re.escape(appid), text, re.M)
if not m:
    print("  %s: AppID %s not found, skipped" % (path, appid)); sys.exit(0)

indent = m.group(1) + "\t"
start  = m.end()
end    = text.index("\n" + m.group(1) + "}", start) + 1
block  = text[start:end]

line = '%s"LaunchOptions"\t\t"%s"\n' % (indent, opts)
if re.search(r'^\s*"LaunchOptions"', block, re.M):
    block = re.sub(r'^\s*"LaunchOptions".*\n', line, block, count=1, flags=re.M)
    what = "replaced"
else:
    block = line + block
    what = "added"

open(path, "w", encoding="utf-8", errors="surrogateescape").write(text[:start] + block + text[end:])
print("  %s: LaunchOptions %s" % (path, what))
PY
  found=1
done

[ "$found" = 1 ] || { echo "No localconfig.vdf found." >&2; exit 1; }
echo
echo "Launch options: $OPTS"
echo "Start Steam again; the option is in the game's properties."
