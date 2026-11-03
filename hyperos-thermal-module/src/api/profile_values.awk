END {
  if(bad)exit 2
  for(i=1;i<=count[root];i++) {ch=children[root,i];printf "%s=%s\n",K[ch],V[ch]}
}
