#!/system/bin/sh
# status_fast.sh —— 极轻量实时状态（主页高频刷新专用）
# 只读最常变的 5 个节点，一次 awk 读完并直接算好：不 source common.sh、
# 不调用任何函数，单次约十几毫秒。慢变字段（容量/健康度/循环/协议等）交给 status_kv.sh 定期刷新。
BAT=/sys/class/power_supply/battery
_f=""
for _x in "$BAT/capacity" "$BAT/status" "$BAT/temp" "$BAT/current_now" "$BAT/voltage_now"; do
    [ -f "$_x" ] && _f="$_f $_x"
done
[ -n "$_f" ] || exit 0

eval "$(awk 'FNR==1 { n=split(FILENAME,p,"/"); v[p[n]]=$0 }
END {
    i=v["current_now"]; u=v["voltage_now"];
    if(i=="" ) i=0; if(u=="") u=0;
    im=i/1000; if(im<0) im=-im;
    printf "soc=\"%s\"\n", v["capacity"];
    printf "status=\"%s\"\n", v["status"];
    printf "temp_c=\"%s\"\n", v["temp"];
    printf "battery_current_ma=\"%d\"\n", im;
    printf "voltage_uv=\"%s\"\n", u;
    printf "battery_power_w=\"%.1f\"\n", im*u/1000000000;
}' $_f 2>/dev/null)"

[ -n "$soc" ] || exit 0
echo "soc=$soc"
echo "status=$status"
echo "temp_c=$temp_c"
echo "battery_current_ma=$battery_current_ma"
echo "voltage_uv=$voltage_uv"
echo "battery_power_w=$battery_power_w"
