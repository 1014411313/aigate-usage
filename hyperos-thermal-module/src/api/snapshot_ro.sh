#!/system/bin/sh
XBT=${SNAP_XBT:-${0%/*}/../battery}
SYS=${SNAP_SYSROOT:-/sys}
PROC=${SNAP_PROCROOT:-/proc}
ODM=${SNAP_ODMROOT:-/odm}
CONF=$XBT/config/settings.conf

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*|[!A-Za-z0-9_]*) continue ;; esac
  case "$line" in *=*) key=${line%%=*} ;; *) continue ;; esac
  case "$key" in *[!A-Za-z0-9_]*) continue ;; esac
  eval "cfg_$key=\${line#*=}"
done < "$CONF" 2>/dev/null
cfg() { eval 'value=${cfg_'"$1"'-}'; printf '%s' "${value:-${2:-}}"; }
read1() { REPLY=; if [ -r "$1" ]; then IFS= read -r REPLY < "$1"; fi; printf '%s' "$REPLY"; }
alive() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  awk '{sub(/^.*[)] /,""); if($1!="Z" && $1!="X")ok=1} END{exit !ok}' "$PROC/$1/stat" 2>/dev/null
}
put() { printf '%s=%s\n' "$1" "$2"; }
code=$(cfg dev_code unsupported)
case "$code" in
  xuanyuan) name='小米15 Ultra'; maxw=90; maxma=8000 ;;
  dada) name='小米15'; maxw=90; maxma=12000 ;;
  haotian) name='小米15 Pro'; maxw=90; maxma=8000 ;;
  nezha) name='小米17 Ultra'; maxw=90; maxma=8000 ;;
  myron) name='Redmi K90 Pro Max'; maxw=100; maxma=9000 ;;
  annibale) name='Redmi K90'; maxw=100; maxma=9000 ;;
  bixi) name='小米 MIX Flip2'; maxw=67; maxma=6500 ;;
  onyx) name='Redmi Turbo 4 Pro'; maxw=90; maxma=8000 ;;
  popsicle) name='小米17 Pro Max'; maxw=100; maxma=9000 ;;
  miro) name='Redmi K80 Pro'; maxw=120; maxma=10250 ;;
  songyuan) name='Redmi K100 Pro Max'; maxw=100; maxma=9200 ;;
  warsaw) name='Redmi K90 Ultra'; maxw=100; maxma=9000 ;;
  pudding) name='小米17'; maxw=100; maxma=9200 ;;
  pandora) name='小米17 Pro'; maxw=100; maxma=9000 ;;
  byron) name='小米17 Max'; maxw=100; maxma=9200 ;;
  *) code=unsupported; name='未知机型（未支持）'; maxw=0; maxma=6800 ;;
esac
mode=$(cfg power_limit inf)
case "$mode" in inf|fast|mid|slow) ;; *) mode=inf ;; esac
put power_w "$mode"
for key in unlock cloud_guard freepps apl_enable cycle_fake fv_force fv_v term_v; do
  default=; case "$key" in unlock|cloud_guard) default=1 ;; freepps|apl_enable|fv_force) default=0 ;; esac
  put "$key" "$(cfg "$key" "$default")"
done
put power_limit "$mode"
put dev_code "$code"; put dev_name "$name"; put dev_maxw "$maxw"
put fast_w "$(cfg fast_w 40)"; put mid_w "$(cfg mid_w 25)"; put slow_w "$(cfg slow_w 10)"
awk -F= '$1=="version"{print "version=" substr($0,index($0,"=")+1);exit}' "$XBT/module.prop" 2>/dev/null
nodes=; first=
for path in "$SYS/class/xm_power/charger/charger_thermal/wired_chg_curr" "$SYS/class/xm_power/charger/charger_thermal/wired_chg_curr2" "$SYS/class/xm_power/charger/charger_thermal/wireless_chg_curr"; do
  [ -w "$path" ] || continue
  [ -n "$first" ] || first=$path
  nodes=${nodes:+$nodes,}$path
done
if [ -z "$nodes" ]; then
  for path in "$SYS/class/power_supply/main/constant_charge_current_max" "$SYS/class/power_supply/battery/constant_charge_current_max" "$SYS/class/power_supply/battery/constant_charge_current"; do
    [ -e "$path" ] || continue
    [ -n "$first" ] || first=$path
    nodes=${nodes:+$nodes,}$path
  done
fi
if [ -n "$nodes" ]; then put direct_control 1; else put direct_control 0; fi
put direct_nodes "$nodes"; put current_node "$first"
if [ -n "$first" ] && [ -w "$first" ]; then put node_ok 1; else put node_ok 0; fi
put thermal_remove "$(read1 "$SYS/class/xm_power/charger/charger_thermal/wired_thermal_remove")"
put ctrl_limit "$(read1 "$SYS/class/xm_power/charger/charger_thermal/wired_ctrl_limit")"
for pair in 'cg charge_guard' 'apl apl'; do
  set -- $pair
  pid=$(read1 "$XBT/state/$1.pid"); live=0
  alive "$pid" && live=1
  put "$2_alive" "$live"
  if [ "$1" = cg ]; then put charge_guard_ok "$live"; else apl_live=$live; put apl_pid "$pid"; fi
done
watchdog=$(timeout 2 pgrep -f 'HyperOS_XJ/battery/scripts/[g]uard_watchdog\.sh' 2>/dev/null | head -n 1)
put watchdog_alive "$watchdog"
put apl_target_ma "$(read1 "$XBT/state/apl_target_ma")"
cap=
if [ -r "$PROC/device-tree/soc/mca_strategy_quick_charge/div_max_curr" ]; then
  cap=$(od -An -tu1 -v "$PROC/device-tree/soc/mca_strategy_quick_charge/div_max_curr" 2>/dev/null | awk '{for(i=1;i<=NF;i++)a[++n]=$i} END{if(n<4)exit;for(i=1;i+3<=n;i+=4){v=a[i]*16777216+a[i+1]*65536+a[i+2]*256+a[i+3];if(v>m)m=v}print m}')
fi
put apl_cap_ma "$cap"
if [ -f "$XBT/state/apl_lock_until" ]; then put apl_locked 1; else put apl_locked 0; fi
profile=$XBT/state/apl_profile.$code.kv
if [ -f "$profile" ]; then put apl_profile 1; else put apl_profile 0; fi
awk -F= '/^b[0-9]=/ {if($2+0>m)m=$2+0} /^_reset_/ {v=substr($0,index($0,"=")+1)} END{print "apl_best_ma=" (m>0?m:"");print "apl_reset_reason=" v}' "$profile" 2>/dev/null
put freepps_runtime "$(read1 "${XBT%/HyperOS_XJ/battery}/freepps/free")"
source_file=$XBT/baa/payload_BAA_config_$code.json
target_file=$ODM/etc/charger/BAA_config_$code.json
src_hash=$(sha256sum "$source_file" 2>/dev/null); src_hash=${src_hash%% *}
dst_hash=$(sha256sum "$target_file" 2>/dev/null); dst_hash=${dst_hash%% *}
src_label=$(stat -c '%C' "$source_file" 2>/dev/null)
dst_label=$(stat -c '%C' "$target_file" 2>/dev/null)
if [ -n "$src_hash" ] && [ "$src_hash" = "$dst_hash" ] && [ -n "$dst_label" ] && { [ "$dst_label" = "$src_label" ] || [ "$dst_label" = u:object_r:batteryantiaging_cfg_file:s0 ]; }; then put baa_state active
else put baa_state inactive; fi
image=
if [ "$code" != unsupported ]; then
  if [ -f "$XBT/dtbo/$code.img" ]; then image=$code.img
  elif [ -f "$XBT/dtbo/local.img" ]; then image=local.img; fi
fi
if [ -n "$image" ]; then put dtbo_local 1; else put dtbo_local 0; fi
put dtbo_image "$image"
os=$(getprop ro.mi.os.version.name 2>/dev/null)$(getprop ro.mi.os.version.incremental 2>/dev/null)
case "$os" in *OS4*) put dtbo_os4 1 ;; '') put dtbo_os4 '' ;; *) put dtbo_os4 0 ;; esac
manifest=$(cfg backup_dir /sdcard/Download/dtbo_backup)/manifest.txt
last=$(awk '/install_flash_OK|install_flash_SKIP|install_flash_.*FAIL|install_flash_ABORT|flash_OK|flash_VERIFY_FAIL/{l=$0} END{print l}' "$manifest" 2>/dev/null)
case "$last" in *flash_OK*) result=OK ;; *SKIP*) result=SKIP ;; *_FAIL*|*ABORT*) result=FAIL ;; *) result= ;; esac
put dtbo_flash "$result"
put dtbo_flash_time "$(printf '%s\n' "$last" | awk '{if(NF>=2)print $1 " " $2;else print $1}')"
put fv_set "$(cfg fv_v '')"; put fv_applied "$(read1 "$XBT/state/fv_force_applied")"
put fv_vterm_orig "$(read1 "$XBT/state/fv_vterm_orig")"
vterm=
for path in "$XBT/state/fv_vterm_orig" "$XBT/baa/stock_BAA_config_$code.json" "$XBT/state/fv_force_backup/normal_plain.json" "$XBT/baa/modes/normal_plain.json" "$XBT/baa/modes/normal_nocloud_plain.json"; do
  [ -r "$path" ] || continue
  vterm=$(awk '/^[0-9]+$/{if($0+0>m)m=$0+0} {s=$0;while(match(s,/"vterm"[[:space:]]*:[[:space:]]*[0-9]+/)){v=substr(s,RSTART,RLENGTH);sub(/^.*:/,"",v);if(v+0>m)m=v+0;s=substr(s,RSTART+RLENGTH)}} END{if(m>0)print m}' "$path")
  [ -n "$vterm" ] && break
done
put fv_vterm "$vterm"; put vterm_max "$vterm"
node=$(read1 "$XBT/state/volt_fv_node"); node=${node%%|*}
case "$node" in /sys/*) node=$SYS/${node#/sys/} ;; esac
if [ -n "$node" ] && [ -r "$node" ]; then
  put fv_node_path "$node"; put fv_node_now "$(read1 "$node" | tr -cd '0-9')"
fi
power=$(read1 "$SYS/class/xm_power/charger/charger_common/power_max")
case "$power" in ''|*[!0-9]*) put power_max_w '' ;; *) put power_max_w "$((power/1000000))" ;; esac
# target_ma follows the existing tier calculation without deleting stale APL state.
voltage=$(read1 "$SYS/class/power_supply/battery/voltage_now")
maxma=$(cfg max_ma "$maxma")
if [ "$mode" = inf ]; then
  limit=20000
  for value in "$cap" "$(cfg apl_max_ma '')"; do
    case "$value" in ''|*[!0-9]*) continue ;; esac
    [ "$value" -gt 0 ] && [ "$value" -lt "$limit" ] && limit=$value
  done
  target=
  if [ "$(cfg apl_enable 0)" = 1 ] && [ "$apl_live" = 1 ]; then target=$(read1 "$XBT/state/apl_target_ma"); fi
  case "$target" in ''|*[!0-9]*) target=$limit ;; *) [ "$target" -ge 2000 ] || target=$limit; [ "$target" -le "$limit" ] || target=$limit ;; esac
else
  watts=$(cfg "${mode}_w" ''); case "$mode:$watts" in fast:) watts=40 ;; mid:) watts=25 ;; slow:) watts=10 ;; esac
  target=$(awk -v w="$watts" -v v="$voltage" -v cap="$maxma" 'BEGIN{if(w!~/^[0-9]+$/||v!~/^[0-9]+$/||v<=0)exit;r=int((w*1e9/v+50)/100)*100;if(r<500)r=500;if(r>12000)r=12000;if(cap~/^[0-9]+$/&&r>cap)r=cap;print r}')
fi
put target_ma "$target"
