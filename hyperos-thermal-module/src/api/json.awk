function die(msg) { bad=1; print "JSON: " msg > "/dev/stderr"; exit 2 }
function ws() { while (pos<=length(src) && substr(src,pos,1) ~ /[ \t\r\n]/) pos++ }
function hex(s,   i,x,c) { x=0; for(i=1;i<=length(s);i++) { c=index("0123456789abcdef",tolower(substr(s,i,1)))-1; if(c<0) die("invalid unicode escape"); x=x*16+c } return x }
function utf(n) {
  if(n<128) return sprintf("%c",n)
  if(n<2048) return sprintf("%c%c",192+int(n/64),128+n%64)
  if(n<65536) return sprintf("%c%c%c",224+int(n/4096),128+int(n/64)%64,128+n%64)
  return sprintf("%c%c%c%c",240+int(n/262144),128+int(n/4096)%64,128+int(n/64)%64,128+n%64)
}
function string(   c,e,h,l,start,out) {
  if(substr(src,pos++,1)!="\"") die("expected string")
  start=pos-1; out=""
  while(pos<=length(src)) {
    c=substr(src,pos++,1)
    if(c=="\"") { text=out; token=substr(src,start,pos-start); return }
    if(c ~ /[[:cntrl:]]/ && c!=sprintf("%c",127)) die("control character in string")
    if(c=="\\") {
      e=substr(src,pos++,1)
      if(e=="u") {
        if(length(substr(src,pos,4))!=4) die("short unicode escape")
        h=hex(substr(src,pos,4)); pos+=4
        if(h>=55296 && h<=56319) {
          if(substr(src,pos,2)!="\\u") die("missing low surrogate")
          pos+=2; l=hex(substr(src,pos,4)); pos+=4
          if(l<56320 || l>57343) die("invalid low surrogate")
          h=65536+(h-55296)*1024+l-56320
        } else if(h>=56320 && h<=57343) die("unpaired surrogate")
        out=out utf(h)
      } else if(e=="\"" || e=="\\" || e=="/") out=out e
      else if(e=="b") out=out sprintf("%c",8)
      else if(e=="f") out=out sprintf("%c",12)
      else if(e=="n") out=out "\n"
      else if(e=="r") out=out "\r"
      else if(e=="t") out=out "\t"
      else die("invalid escape")
    } else out=out c
  }
  die("unterminated string")
}
function parse(depth,   id,c,key,rawkey,child,lit) {
  if(depth>48 || ++nodes>20000) die("document too complex")
  id=nodes; ws(); c=substr(src,pos,1)
  if(c=="{" || c=="[") {
    T[id]=(c=="{" ? "object" : "array"); pos++; ws()
    if(substr(src,pos,1)==(c=="{" ? "}" : "]")) { pos++; return id }
    while(1) {
      ws()
      if(c=="{") {
        string(); key=text; rawkey=token; ws()
        if(substr(src,pos++,1)!=":") die("expected colon")
        if((id SUBSEP key) in members) die("duplicate object key")
      }
      child=parse(depth+1); children[id,++count[id]]=child
      if(c=="{") { members[id,key]=child; K[child]=key; KR[child]=rawkey }
      ws(); lit=substr(src,pos++,1)
      if(lit==(c=="{" ? "}" : "]")) return id
      if(lit!=",") die("expected comma or end")
    }
  }
  if(c=="\"") { string(); T[id]="string"; V[id]=text; R[id]=token; return id }
  lit=substr(src,pos)
  if(match(lit,/^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) { T[id]="number"; V[id]=R[id]=substr(lit,1,RLENGTH); pos+=RLENGTH; return id }
  if(substr(lit,1,4)=="true" || substr(lit,1,5)=="false") { T[id]="bool"; V[id]=R[id]=(substr(lit,1,4)=="true" ? "true" : "false"); pos+=length(R[id]); return id }
  if(substr(lit,1,4)=="null") { T[id]="null"; R[id]="null"; pos+=4; return id }
  die("invalid value")
}
function json(id,   out,i,ch) {
  if(T[id]!="object" && T[id]!="array") return (T[id]=="string" ? quote(V[id]) : R[id])
  out=(T[id]=="object" ? "{" : "[")
  for(i=1;i<=count[id];i++) { ch=children[id,i]; out=out (i>1 ? "," : "") (T[id]=="object" ? quote(K[ch]) ":" : "") json(ch) }
  return out (T[id]=="object" ? "}" : "]")
}
function pretty(id,indent,   out,i,ch) {
  if(T[id]!="object" && T[id]!="array") return (T[id]=="string" ? quote(V[id]) : R[id])
  out=(T[id]=="object" ? "{" : "[")
  for(i=1;i<=count[id];i++) { ch=children[id,i]; out=out (i>1 ? "," : "") "\n" indent "  " (T[id]=="object" ? quote(K[ch]) ": " : "") pretty(ch,indent "  ") }
  return out (count[id] ? "\n" indent : "") (T[id]=="object" ? "}" : "]")
}
function member(id,key) { return members[id,key]+0 }
function quote(s,   out,i,c,x) {
  out="\""; for(i=1;i<=length(s);i++) { c=substr(s,i,1); if(c=="\"" || c=="\\") out=out "\\" c; else if(c ~ /[[:cntrl:]]/) { for(x=0;x<128;x++) if(c==sprintf("%c",x)) break; out=out sprintf("\\u%04x",x) } else out=out c } return out "\""
}
function lookup(id,path,   n,a,i,j,ch) {
  if(path=="") return id
  n=split(path,a,".")
  for(i=1;i<=n;i++) { ch=member(id,a[i]); if(!ch) return 0; id=ch }
  return id
}
BEGIN {
  while((getline line)>0) { src=src line "\n"; if(length(src)>1048576) die("document too large") }
  pos=1; root=parse(0); ws(); if(pos<=length(src)) die("trailing data")
  if(mode=="get") { id=lookup(root,path); if(!id) exit 3; print T[id] "\t" json(id) }
  else if(mode=="root") print json(root)
}
