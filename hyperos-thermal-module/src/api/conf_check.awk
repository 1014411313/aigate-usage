function reject() { bad=1; exit 2 }
function integer(s,lo,hi) { return s ~ /^(0|[1-9][0-9]*)$/ && s+0>=lo && s+0<=hi }
BEGIN {
  split("unlock fv_guard pss_disable freepps cloud_guard fv_force apl_enable rearscreen",a," "); for(i in a) bool[a[i]]=1
  split("poll_interval foreground_interval bypass_current restart_cooldown enable_guard temp_guard lock_conf charge_node",a," "); for(i in a) prof[a[i]]=1
}
/^[ \t]*(#.*)?$/ { next }
{
  if(length($0)>4096 || $0 ~ /[[:cntrl:]]/ || $0 !~ /^[A-Za-z_][A-Za-z0-9_]*=/) reject()
  k=substr($0,1,index($0,"=")-1); v=substr($0,index($0,"=")+1); if(seen[k]++)reject()
  if(kind=="profile") {
    if(!(k in prof))reject()
    if(k=="charge_node") {if(v!="" && v!="/sys/class/xm_power/charger/charger_thermal/wired_chg_curr" && v !~ /^\/sys\/class\/power_supply\/battery\/(constant_charge_current_max|charge_control_limit|constant_charge_current|input_current_limit)$/)reject()}
    else if(k=="lock_conf" || k=="enable_guard") {if(!integer(v,0,1))reject()}
    else if(k=="bypass_current") {if(!integer(v,0,5000000))reject()}
    else if(k=="temp_guard") {if(!integer(v,0,1000))reject()}
    else if(!integer(v,(k=="restart_cooldown"?0:1),3600))reject()
  } else {
    if(k in bool) {if(!integer(v,0,1))reject()}
    else if(k=="cycle_fake") {if(v!="" && !integer(v,0,20000))reject()}
    else if(k=="fv_v") {if(v!="" && !integer(v,4300,4700))reject()}
    else if(k=="term_v") {if(v!="" && !integer(v,2800,3500))reject()}
    else if(k=="thermal_ceil") {if(v!="" && !integer(v,0,1000))reject()}
    else if(k=="pss_low_soc" || k=="pss_low_hyst") {if(!integer(v,0,100))reject()}
    else if(k=="power_limit") {if(v !~ /^(inf|fast|mid|slow)$/)reject()}
    else if(k=="baa_fmt") {if(v !~ /^(auto|enc|plain)$/)reject()}
    else if(k=="power_mech") {if(v !~ /^(curr|ctrl)$/)reject()}
    else if(k=="dev_code") {if(v !~ /^[A-Za-z0-9_]*$/)reject()}
    else if(k=="backup_dir") {if(v !~ /^\/(sdcard|storage\/emulated\/0)(\/[A-Za-z0-9_. -]+)*$/ || v ~ /\.\./)reject()}
    else if(k ~ /^(fast_w|mid_w|slow_w|mid_ctrl|slow_ctrl|max_ma|cg_min_write_gap|cg_disc_min_sec|apl_max_ma|closed_loop)$/) {if(!integer(v,0,100000))reject()}
    else reject()
  }
}
END { if(bad)exit 2 }
