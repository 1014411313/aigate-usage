#!/system/bin/sh
MODDIR=$(CDPATH= cd -- "${0%/*}/.." && pwd -P) || exit 1
API_DIR=$MODDIR/api
XBT=$MODDIR/battery
CONF=$XBT/config/settings.conf
. "$API_DIR/config_io.sh"
[ "$#" = 4 ] || exit 2
[ "$1" = "$CONF" ] && [ "$2" = "$XBT" ] || exit 2
case "$3" in ''|*[!A-Za-z0-9_]*) exit 2 ;; esac
newline=$(printf '\nX'); newline=${newline%X}
case "$4" in *"$newline"*|*"$(printf '\r')"*) exit 2 ;; esac
mkdir -p "$XBT/state" "$XBT/config" || exit 1
WORK=$(mktemp -d "$XBT/state/cfg-write.XXXXXXXXXX") || exit 1
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
attempt=0
until lock_acquire "$XBT/state/.config-write.lock" "$XBT/state/.config-write.reap"; do
  attempt=$((attempt+1))
  [ "$attempt" -lt 15 ] || exit 6
  sleep 1
done
input=$CONF
[ -f "$input" ] || input=/dev/null
CFG_KEY=$3 CFG_VALUE=$4 awk ' 
BEGIN { key=ENVIRON["CFG_KEY"]; value=ENVIRON["CFG_VALUE"] }
index($0,key "=")==1 { if(!seen++) print key "=" value; next }
{ print }
END { if(!seen) print key "=" value }
' "$input" > "$WORK/next.conf" || exit 1
commit_config battery/config/settings.conf "$WORK/next.conf" || exit 8
cmp -s "$WORK/next.conf" "$CONF" && cmp -s "$CONF" "$BAK/battery/config/settings.conf"
