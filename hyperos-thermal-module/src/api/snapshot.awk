function valid(v) { return v ~ /^-?([0-9]+)(\.[0-9]+)?$/ }
function q(s,   o,i,c,n) { o="\""; for(i=1;i<=length(s);i++){c=substr(s,i,1);if(c=="\""||c=="\\")o=o "\\" c;else if(c=="\n")o=o "\\n";else if(c=="\r")o=o "\\r";else if(c=="\t")o=o "\\t";else{n=ord(c);if(n<32)o=o sprintf("\\u%04x",n);else o=o c}}return o "\"" }
function ord(c,   i) { for(i=1;i<256;i++)if(sprintf("%c",i)==c)return i;return 0 }
function setkv(s,   p,k) { p=index(s,"=");if(!p)return;k=substr(s,1,p-1);if(k~/^[A-Za-z0-9_]+$/)kv[k]=substr(s,p+1) }
function cfgval(k,d) { return (cfg[k]!=""?cfg[k]:d) }
function rearparse(s,   x) {
  fields="\"temp\",\"soc\",\"volt\",\"cur\"";theme="aurora";accent="78,161,255";scale="1";rear_enabled="false"
  if(match(s,/"enabled":true/))rear_enabled="true"
  if(match(s,/"fields":\[[^]]*\]/))fields=substr(s,RSTART+10,RLENGTH-11)
  if(match(s,/"theme":"[^"]+"/))theme=substr(s,RSTART+9,RLENGTH-10)
  if(match(s,/"accent":"[0-9]+,[0-9]+,[0-9]+"/))accent=substr(s,RSTART+10,RLENGTH-11)
  if(match(s,/"font_scale":[0-9.]+/)){x=substr(s,RSTART+13,RLENGTH-13);if(valid(x))scale=x}
}
{
 if(substr($0,1,3)=="KV:"){setkv(substr($0,4));next}
 if(substr($0,1,5)=="FAST:"){s=substr($0,6);p=index(s,"=");if(p)fast[substr(s,1,p-1)]=substr(s,p+1);setkv(s);next}
 if(substr($0,1,4)=="CFG:"){s=substr($0,5);p=index(s,"=");if(p)cfg[substr(s,1,p-1)]=substr(s,p+1);next}
 if(substr($0,1,5)=="REAR:"){rear=substr($0,6);next}
}
END {
 soc=fast["soc"];st=fast["status"];c=fast["battery_current_ma"];charging=(st=="Charging"||st=="Full")
 cur="null";power="null"
 if(valid(c)){i=c+0;if(charging&&i<0)i=-i;if(!charging&&i>0)i=-i;cur=sprintf("%.3f",i/1000);if(valid(fast["battery_power_w"])){p=fast["battery_power_w"]+0;if(!charging)p=-p;power=sprintf("%.1f",p)}}
 temp=valid(fast["temp_c"])?sprintf("%.1f",(fast["temp_c"]+0)/10):"null"
 volt=valid(fast["voltage_uv"])?sprintf("%.3f",(fast["voltage_uv"]+0)/1000000):"null"
 pack=valid(fast["pack_voltage_uv"])?sprintf("%.3f",(fast["pack_voltage_uv"]+0)/1000000):"null"
 full=valid(fast["charge_full_mah"])?sprintf("%.0f",fast["charge_full_mah"]+0):"null"
 des=valid(fast["charge_design_mah"])?sprintf("%.0f",fast["charge_design_mah"]+0):"null"
 cycle=fast["cycle_real"];if(!valid(cycle))cycle=fast["cycle"];cycle=valid(cycle)?sprintf("%.0f",cycle+0):"null"
 fake=cfgval("cycle_fake","");fake=(fake!=""&&valid(fake))?sprintf("%.0f",fake+0):"null"
 rm=valid(kv["rm_uah"])?sprintf("%.0f",(kv["rm_uah"]+0)/1000):"null"
 soh=kv["soh"];gsub(/%/,"",soh);soh=valid(soh)?sprintf("%.1f",soh+0):"null"
 health="null";if(valid(full)&&valid(des)&&(des+0)>0)health=sprintf("%.1f",(full+0)*100/(des+0))
 proto=fast["charge_proto"];if(proto=="")proto=kv["proto_real"]
 timestamp=cfgval("_timestamp","0");if(timestamp!~/^[0-9]+$/)timestamp="0"
 fresh=(valid(soc)&&soc+0>=0&&soc+0<=100&&st!=""&&valid(c)&&valid(fast["voltage_uv"]))?"true":"false"
 mode=cfgval("_mode","unknown");tt=valid(cfg["_thermal_temp"])?sprintf("%.1f",cfg["_thermal_temp"]+0):"null";ts=valid(cfg["_thermal_soc"])?sprintf("%.0f",cfg["_thermal_soc"]+0):"null"
 rearparse(rear)
 printf "{\"schema\":1,\"timestamp\":%s,\"fresh\":%s,\"soc\":%s,\"status\":%s,\"charging\":%s,\"temp\":%s,\"volt\":%s,\"pack_volt\":%s,\"cur\":%s,\"power\":%s,\"des\":%s,\"full\":%s,\"health\":%s,\"cycle\":%s,\"fake\":%s,\"proto\":%s,\"rm\":%s,\"soh\":%s,\"mode\":%s,\"fields\":[%s],\"theme\":%s,\"accent\":%s,\"font_scale\":%s,\"rearscreen\":%s,\"thermal\":{\"current\":{\"temp\":%s,\"soc\":%s,\"mode\":%s},\"desired\":{\"mode\":%s},\"effective\":{\"mode\":%s},\"actual\":{\"mode\":%s}},",timestamp,fresh,(valid(soc)?sprintf("%.0f",soc+0):"null"),q(st),charging?"true":"false",temp,volt,pack,cur,power,des,full,health,cycle,fake,q(proto),rm,soh,q(mode),fields,q(theme),q(accent),scale,rear_enabled,tt,ts,q(mode),q(cfgval("_desired","")),q(cfgval("_effective","")),q(cfgval("_actual",mode))
 printf "\"power_mode\":%s,\"unlock\":%s,\"pps\":%s,\"apl\":%s,\"cloud\":%s,\"fv_v\":%s,\"term_v\":%s,\"fv_force\":%s,\"kv\":{" ,q(cfgval("power_limit","inf")),q(cfgval("unlock","1")),q(cfgval("freepps","0")),q(cfgval("apl_enable","0")),q(cfgval("cloud_guard","1")),q(cfgval("fv_v","")),q(cfgval("term_v","")),q(cfgval("fv_force","0"))
 sep="";for(k in kv){printf "%s%s:%s",sep,q(k),q(kv[k]);sep=","}print "}}"
}