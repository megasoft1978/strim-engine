#!/usr/bin/perl
# A3: list SDPA calls for cold prefill; route per MLX use_fallback()/has_fused_kernel (D=256, causal, no array mask, M5 Max NAX available, macOS>=26.2):
#   qL>=1024 -> fused NAX headdim-split (sdpa_full_self_attention_nax); 8<qL<1024 (D=256) -> UNFUSED fallback by design ("unfused path is faster for these shapes").
# Hq*D=6144 (Hq=24, D=256), 16 full-attention layers. fused rate 41.7 TF/s measured (L0 table4k); fallback rate unknown: bounded 1x..4x slower.
use strict;
sub plan { my($n,$blk)=@_; my @c; my $p=0; while($p<$n){ my $e=($p+$blk<=$n)?$p+$blk:$n; push @c,[$p,$e-$p]; $p=$e;} return @c; }
for my $pol (["fixed1024",1024],["prod-cap1536",1536]) {
 for my $n (4107,16395,32779) {
  my @c=plan($n,$pol->[1]); my ($tf,$tu,$nf,$nu,$fl_f,$fl_u)=(0,0,0,0,0,0); my @lst;
  for my $x (@c){ my($off,$q)=@$x; my $pairs=$q*$off+$q*($q+1)/2; my $fl=16*4*6144*$pairs; my $path=$q>=1024?"fused-NAX":"fallback";
    if($q>=1024){$nf++;$fl_f+=$fl}else{$nu++;$fl_u+=$fl} push @lst,"qL=$q/kL=".($off+$q)."/$path"; }
  my $t_f=$fl_f/41.7e12*1000; my $t_u1=$fl_u/41.7e12*1000;
  printf "%-12s prompt %5d: %2d calls/layer-group: %d fused, %d fallback | sdpa fused %.0f ms, fallback(1x..4x) %.1f..%.1f ms => fallback share of SDPA %.2f%%..%.2f%%\n",
    $pol->[0],$n,scalar(@c),$nf,$nu,$t_f,$t_u1,4*$t_u1,100*$t_u1/($t_f+$t_u1),100*4*$t_u1/($t_f+4*$t_u1);
  print "   ".join("  ",@lst[($#lst>6?($#lst-3):0)..$#lst])." (last calls)\n";
 } }
