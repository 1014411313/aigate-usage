END {
  if(bad)exit 2
  id=member(root,"enabled"); if(T[root]!="object" || T[id]!="bool")exit 2
  V[id]=R[id]=(enabled==1 ? "true" : "false")
  print json(root)
}
