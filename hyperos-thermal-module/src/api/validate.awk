function require(ok,msg) { if(!ok) die(msg) }
function obj(id) { require(T[id]=="object","expected object") }
function keys(id,list,   a,n,i,ch,allowed) {
  obj(id); n=split(list,a," "); for(i=1;i<=n;i++) allowed[a[i]]=1
  for(i=1;i<=count[id];i++) { ch=children[id,i]; require(K[ch] in allowed,"unknown key: " K[ch]) }
}
function exact(id,list,   a,n,i) { keys(id,list); n=split(list,a," "); for(i=1;i<=n;i++) require(member(id,a[i]),"missing key: " a[i]) }
function enum(id,list) { require(T[id]=="string" && index("|" list "|","|" V[id] "|")>0,"invalid enum") }
function number(id,lo,hi,integer) { require(T[id]=="number" && V[id]+0>=lo && V[id]+0<=hi && (!integer || V[id] ~ /^(0|[1-9][0-9]*)$/),"number outside range") }
function boolean(id) { require(T[id]=="bool","expected boolean") }
function webui(id) {
  exact(id,"liquid_glass wallpaper_preset blob_count noise bg_hue blob_size blob_blur blob_op blob_drift blob_speed bg_blur bg_sat bg_hue_dur noise_op")
  boolean(member(id,"liquid_glass")); boolean(member(id,"noise")); boolean(member(id,"bg_hue"))
  enum(member(id,"wallpaper_preset"),"default|amber|ice|lime|violet")
  number(member(id,"blob_count"),0,3,1); number(member(id,"blob_size"),40,170,0); number(member(id,"blob_blur"),20,200,0)
  number(member(id,"blob_op"),.2,1.6,0); number(member(id,"blob_drift"),0,40,0); number(member(id,"blob_speed"),5,40,0)
  number(member(id,"bg_blur"),0,20,0); number(member(id,"bg_sat"),.4,2.2,0); number(member(id,"bg_hue_dur"),10,120,0); number(member(id,"noise_op"),.05,.6,0)
}
function settings(id,   a,n,i,k) {
  exact(id,"schema enabled default_mode charge_mode charge_level sleep_level time_start time_end time_level game_mode game_level game_apps game_fps game_bypass bypass_temp_on bypass_temp_off bypass_level bypass_current hyperos4 no_hitemp_stop charge_gov power_plan_on power_plan_start power_plan_end power_plan_mode webui_defaults")
  number(member(id,"schema"),2,2,1)
  n=split("enabled charge_mode game_mode game_bypass hyperos4 no_hitemp_stop charge_gov power_plan_on",a," "); for(i=1;i<=n;i++) boolean(member(id,a[i]))
  n=split("default_mode charge_level sleep_level time_level game_level",a," "); for(i=1;i<=n;i++) enum(member(id,a[i]),"default|unlimited|level_1|level_2|level_3|level_4|level_5")
  n=split("time_start time_end power_plan_start power_plan_end",a," "); for(i=1;i<=n;i++) number(member(id,a[i]),0,23,1)
  number(member(id,"game_fps"),0,240,1); number(member(id,"bypass_temp_on"),0,60,1); number(member(id,"bypass_temp_off"),0,60,1)
  number(member(id,"bypass_level"),0,100,1); number(member(id,"bypass_current"),0,5000000,1)
  k=member(id,"game_apps"); require(T[k]=="string" && length(V[k])<=16384 && V[k] !~ /[^A-Za-z0-9._|]/,"invalid package list")
  enum(member(id,"power_plan_mode"),"inf|fast|mid|slow"); webui(member(id,"webui_defaults"))
}
function rear(id,   f,i,a,n,rgb,c) {
  exact(id,"enabled fields accent theme font_scale"); boolean(member(id,"enabled"))
  f=member(id,"fields"); require(T[f]=="array" && count[f]==4,"fields must contain four entries")
  for(i=1;i<=4;i++) enum(children[f,i],"temp|soc|volt|cur|power|des|full|health|cycle|fake|proto|rm|soh|status")
  enum(member(id,"theme"),"aurora|holographic|neon-dark|aurora-vivid|cyber|lava|glacier|moonsea")
  number(member(id,"font_scale"),.7,1.5,0)
  c=member(id,"accent"); require(T[c]=="string","accent must be RGB string")
  rgb=V[c]; gsub(/ /,"",rgb); n=split(rgb,a,","); require(n==3,"accent must have three channels")
  for(i=1;i<=n;i++) require(a[i] ~ /^[0-9]+$/ && a[i]+0<=255,"invalid RGB channel")
}
function profile(id,   k,i,ch) {
  exact(id,"poll_interval foreground_interval bypass_current restart_cooldown lock_conf charge_node")
  number(member(id,"poll_interval"),1,3600,1); number(member(id,"foreground_interval"),1,3600,1)
  number(member(id,"bypass_current"),0,5000000,1); number(member(id,"restart_cooldown"),0,3600,1); number(member(id,"lock_conf"),0,1,1)
  ch=member(id,"charge_node"); require(T[ch]=="string","invalid charge node")
  if(V[ch]!="") enum(ch,"/sys/class/xm_power/charger/charger_thermal/wired_chg_curr|/sys/class/power_supply/battery/constant_charge_current_max|/sys/class/power_supply/battery/charge_control_limit|/sys/class/power_supply/battery/constant_charge_current|/sys/class/power_supply/battery/input_current_limit")
}
END {
  if(bad) exit 2
  if(check=="settings") settings(root)
  else if(check=="rear") rear(root)
  else if(check=="profile") profile(root)
  else if(check=="ui") { obj(root); require(length(src)<=524288,"UI JSON too large") }
  else if(check=="object") obj(root)
  else if(check=="keys") keys(root,allowed)
  else if(check=="raw") { id=lookup(root,path); require(id,"missing field"); require(T[id]!="object" && T[id]!="array" && T[id]!="null","expected scalar"); require(V[id] !~ /[[:cntrl:]]/,"control characters in field"); print V[id]; exit }
  else if(check=="text") { id=lookup(root,path); require(T[id]=="string","expected string"); require(index(V[id],sprintf("%c",0))==0,"NUL in text"); printf "%s",V[id]; exit }
  else if(check=="type") { id=lookup(root,path); require(id,"missing field"); print T[id]; exit }
  else if(check=="extract") { id=lookup(root,path); require(id,"missing field"); print json(id); exit }
  else if(check=="add_webui") { obj(root); require(!member(root,"webui_defaults"),"webui_defaults already present"); out=json(root); print substr(out,1,length(out)-1) (count[root] ? "," : "") "\"webui_defaults\":" ENVIRON["API_WEBUI"] "}"; exit }
  if(check=="settings") print pretty(root,"")
  else if(check!="") print json(root)
}
