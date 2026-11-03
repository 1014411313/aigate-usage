function fail() { exit 2 }
BEGIN { if(T[root]!="object") fail(); key="high_temp_stop_charge"; val=ENVIRON["RUNTIME_VALUE"]; if(val=="") val="unknown"; raw="\""; for(i=1;i<=length(val);i++){c=substr(val,i,1); if(c=="\""||c=="\\")raw=raw "\\" c; else if(c ~ /[[:cntrl:]]/)fail(); else raw=raw c} raw=raw "\"" }
END {
  if(bad) exit 2
  out="{"; found=0
  for(i=1;i<=count[root];i++) { ch=children[root,i]; k=K[ch]; if(k==key){ if(found++) exit 2; out=out (i>1 ? "," : "") quote(k) ":" raw } else out=out (i>1 ? "," : "") quote(k) ":" json(ch) }
  if(!found) out=out (count[root] ? "," : "") quote(key) ":" raw
  print out "}"
}
