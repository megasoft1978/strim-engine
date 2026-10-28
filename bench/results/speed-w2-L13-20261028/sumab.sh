#!/bin/bash
# usage: sumab.sh NAME -> per metric: median A, median B, delta% (B vs A) over sessions
R=$(cd "$(dirname "$0")" && pwd); N=$1
for arm in A B; do for d in $R/raw/$N/*_$arm; do "$R/cellvals.sh" $d/strim/pass1 | sed "s/^/$arm /"; done; done | awk 'NF==3{k=$1" "$2; v[k]=v[k]" "$3} END{for(k in v){n=split(v[k],a," "); for(i=1;i<=n;i++)for(j=i+1;j<=n;j++)if(a[j]+0<a[i]+0){t=a[i];a[i]=a[j];a[j]=t}; m=(n%2)?a[(n+1)/2]:(a[n/2]+a[n/2+1])/2; split(k,p," "); med[p[1]","p[2]]=m; ns[p[2]]=1; cnt[k]=n}
 for(m in ns) printf "%-8s A=%-10.4g B=%-10.4g delta=%+.2f%% (n=%d/%d)\n", m, med["A,"m], med["B,"m], (med["B,"m]/med["A,"m]-1)*100, cnt["A "m], cnt["B "m]}' | sort
