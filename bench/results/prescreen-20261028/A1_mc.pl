#!/usr/bin/perl
# A1 model: c requests start decoding together; lengths ~ U[lo,hi] tokens; step ms(B) interpolated from L10 (B1 33, B4 41.4, B8 72.1)
# singleton tail = time when exactly one member remains (plain B=1 ~33 ms/tok); MTP alternative 1/50 tok/s = 20 ms/tok
use strict; srand(7);
sub step { my $b=shift; my @x=(1,4,8,16); my @y=(33.3,41.4,72.1,130); return $y[0] if $b<=1;
  for my $i(0..2){ if($b<=$x[$i+1]){ return $y[$i]+($y[$i+1]-$y[$i])*($b-$x[$i])/($x[$i+1]-$x[$i]); } } return $y[3]; }
my ($mtp_ms)=(20.0);
for my $cfg ([4,64,512],[8,64,512],[4,128,128],[8,128,128],[4,32,1024],[8,32,1024]) {
  my ($c,$lo,$hi)=@$cfg; my ($W,$T,$G)=(0,0,0); my $N=20000;
  for (1..$N) {
    my @l = sort {$a<=>$b} map { $lo+int(rand($hi-$lo+1)) } 1..$c;
    my ($t,$done,$tail)=(0,0,0);
    for my $i (0..$c-1) { my $steps=$l[$i]-$done; next if $steps<=0; my $b=$c-$i;
      my $ms=$steps*step($b); $t+=$ms; if($b==1){$tail+=$ms; $G+=$steps*(step(1)-$mtp_ms);} $done=$l[$i]; }
    $W+=$t; $T+=$tail; }
  printf "c=%d len U[%d,%d] tail_share=%.1f%% decode-wall gain if tail uses MTP(20ms/tok)=%.1f%%\n",$c,$lo,$hi,100*$T/$W,100*$G/$W;
}
