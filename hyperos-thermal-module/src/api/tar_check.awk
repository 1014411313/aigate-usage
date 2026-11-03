function fail() { bad=1; exit 2 }
function str(off,len,   s,i,x) { s=""; for(i=off;i<off+len;i++){x=b[i];if(x==0)break;if(x<32 || x>126)fail();s=s sprintf("%c",x)} return s }
function oct(off,len,   s,i,x,n,done) { n=0;done=0;for(i=off;i<off+len;i++){x=b[i];if(x==0 || x==32){done=1;continue}if(done || x<48 || x>55)fail();n=n*8+x-48}return n }
function header(   i,zero,name,prefix,type,size,sum,want,blocks) {
  zero=1;for(i=1;i<=512;i++)if(b[i]!=0)zero=0
  if(zero){ended=1;return}
  if(ended)fail()
  name=str(1,100);prefix=str(346,155);if(prefix!="") name=prefix "/" name
  type=b[157]; if(type!=0 && type!=48)fail()
  if(str(158,100)!="")fail()
  if(name !~ /^(config\/(settings.json|rearscreen.json|bypass_manual)|profiles\/[A-Za-z0-9_ .-]+\.conf|battery\/config\/settings.conf|ui\/ui-settings.json)$/)fail()
  if(name ~ /(^|\/)\.\.?($|\/)/ || name ~ /\.\./ || seen[name]++)fail()
  want=oct(149,8);sum=0;for(i=1;i<=512;i++)sum+=((i>=149&&i<=156)?32:b[i]);if(sum!=want)fail()
  size=oct(125,12);if(size>1048576)fail()
  total+=size;if(total>4194304 || ++files>64)fail()
  print name
  skip=int((size+511)/512)*512
}
{
  for(z=1;z<=NF;z++) {
    x=$z+0
    if(skip>0){skip--;continue}
    b[++offset]=x
    if(offset==512){header();offset=0}
  }
}
END { if(bad || offset || skip || !ended || !files)exit 2 }
