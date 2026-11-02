#!/system/bin/sh
# status_fast.sh —— 极轻量实时状态（主页高频刷新专用）
# 一次 awk 读完这批节点：不 source common.sh、不调用任何函数，单次约二三十毫秒。
# 面板要求全字段秒级刷新，容量/健康度/循环/充电协议这些低频项也并入快速路径；
# 伪装次数来自模块配置（cfg_get），仍由 status_kv.sh 定期刷新。
BAT=/sys/class/power_supply/battery
_rt=""
for _p in /sys/class/power_supply/usb/real_type \
          /sys/class/xm_power/charger/charger_common/real_type \
          /sys/class/qcom-battery/real_type; do
    [ -f "$_p" ] && { _rt="$_p"; break; }
done
if [ -z "$_rt" ] && [ -f /sys/class/power_supply/usb/typec_mode ]; then
    _rt=/sys/class/power_supply/usb/typec_mode
fi
_f=""
for _x in "$BAT/capacity" "$BAT/status" "$BAT/temp" "$BAT/current_now" "$BAT/voltage_now" \
          "$BAT/charge_full" "$BAT/charge_full_design" "$BAT/health" \
          /sys/class/xm_power/fg_master/qmax_cyclecount /sys/class/xm_power/fg_master/cyclecount \
          "$BAT/cycle_count" "$_rt"; do
    [ -n "$_x" ] && [ -f "$_x" ] && _f="$_f $_x"
done
[ -n "$_f" ] || exit 0

eval "$(awk 'FNR==1 { n=split(FILENAME,p,"/"); v[p[n]]=$0 }
END {
    i=v["current_now"]; u=v["voltage_now"];
    if(i=="" ) i=0; if(u=="") u=0;
    im=i/1000; ima=im; if(ima<0) ima=-ima;
    printf "soc=\"%s\"\n", v["capacity"];
    printf "status=\"%s\"\n", v["status"];
    printf "temp_c=\"%s\"\n", v["temp"];
    # 保留符号：放电为负。旧版在这里取绝对值，和 status_kv 的符号相反，
    # 快读/全读交替时界面电流会周期性跳正负。
    printf "battery_current_ma=\"%d\"\n", im;
    printf "voltage_uv=\"%s\"\n", u;
    printf "battery_power_w=\"%.1f\"\n", ima*u/1000000000;
    # 容量/健康度/循环/协议：读空输出空串，前端沿用上次值，避免闪成 0 或 --
    cf=v["charge_full"]; cd=v["charge_full_design"];
    if(cf ~ /^[0-9]+$/) printf "charge_full_mah=\"%d\"\n", cf/1000; else print "charge_full_mah=\"\"";
    if(cd ~ /^[0-9]+$/) printf "charge_design_mah=\"%d\"\n", cd/1000; else print "charge_design_mah=\"\"";
    print "health=\"" v["health"] "\"";
    cyf=""; if(v["cyclecount"] ~ /^[0-9]+$/) cyf=v["cyclecount"];
    cyc=cyf; if(cyc=="") cyc=v["cycle_count"];
    if(cyc !~ /^[0-9]+$/) cyc="";
    cr=""; if(v["qmax_cyclecount"] ~ /^[0-9]+$/) cr=v["qmax_cyclecount"];
    if(cr=="") cr=cyf;
    printf "cycle=\"%s\"\n", cyc;
    printf "cycle_real=\"%s\"\n", cr;
    rt=v["real_type"]; if(rt=="") rt=v["typec_mode"];
    print "charge_proto=\"" rt "\"";
}' $_f 2>/dev/null)"

[ -n "$soc" ] || exit 0
echo "soc=$soc"
echo "status=$status"
echo "temp_c=$temp_c"
echo "battery_current_ma=$battery_current_ma"
echo "voltage_uv=$voltage_uv"
echo "battery_power_w=$battery_power_w"
echo "charge_full_mah=$charge_full_mah"
echo "charge_design_mah=$charge_design_mah"
echo "health=$health"
echo "cycle=$cycle"
echo "cycle_real=$cycle_real"
echo "charge_proto=$charge_proto"
