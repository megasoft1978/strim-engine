#!/usr/bin/perl
# A2: expected-value replay of the adaptive depth controller (SpecStream.round constants) vs fixed best depth and a
# per-workload cost-per-emitted-token optimum, Qd = 1 + sum_{i<=d} S_i. S_i = prefix-survival P(accepted >= i).
# Pass cost c(d) = 33 + 4.5 d ms (fit: d0 33.4, d2 ~41, d4 ~51 from L10 sweep, 4K ctx; 16K adds ~+4 flat -> same shape).
use strict;
sub c { my $d=shift; return 33.3+4.5*$d; }
my %shape = (
 iid      => sub { my($a,$i)=@_; my $p=pfrom($a); return $p**$i; },        # constant per-position acceptance
 decay    => sub { my($a,$i)=@_; my $q=0.614; my $p=2*$a/(1+$q); $p=1 if $p>1; return $p*$q**($i-1); }, # fit to prose d2/d4 pair
 sticky   => sub { my($a,$i)=@_; my $q=0.6+0.4*(($a-0.5)/0.5); $q=1 if $q>1; my $p=2*$a/(1+$q); $p=1 if $p>1; return $p*$q**($i-1); }, # code: runs
);
sub pfrom { my $a=shift; return 1 if $a>=0.9999; my($lo,$hi)=(0,1); for(1..60){my $m=($lo+$hi)/2; my $s=$m+$m*$m; if($s/2<$a){$lo=$m}else{$hi=$m}} return $lo; }
sub Q { my($S,$a,$d)=@_; my $q=1; $q+=$S->($a,$_) for 1..$d; return $q; }
sub frac { my($S,$a,$d)=@_; my $s=0; $s+=$S->($a,$_) for 1..$d; return $s/$d; }
printf "%-7s %5s | ctrl_rest_d  T_ctrl  best_fixed(d) T_best  gain%%  | cost-per-token(d1..4 incl d1) T_best1  gain%%\n","shape","a(d2)";
my %sum; my %n;
# workload weights: acceptance values observed in L3b logs (mtp_accept) bucketed
my @as = (0.62,0.66,0.70,0.74,0.78,0.85,0.92,1.0); my @w = (3,5,8,6,3,1,1,6);
for my $name (sort keys %shape) { my $S=$shape{$name};
 for my $ai (0..$#as) { my $a=$as[$ai];
  my ($d,$ew,$rs,$tt,$tk)=(2,0.5,0,0,0); my ($Tms,$Ttok)=(0,0);
  for my $r (1..400) {
    if ($rs>=2) { my $cl = $d>=3?0.84:0.82; if($ew>$cl && $d<4){$d++;$rs=0} elsif($ew<0.60 && $d>2){$d--;$rs=0} }
    my $f=frac($S,$a,$d); $ew=0.7*$ew+0.3*$f; $rs++;
    if($r>200){ $Ttok+=Q($S,$a,$d); $Tms+=c($d); } }
  my $Tc=1000*$Ttok/$Tms;
  my ($bd,$bT)=(0,0); for my $dd (2..4){ my $t=1000*Q($S,$a,$dd)/c($dd); if($t>$bT){$bT=$t;$bd=$dd} }
  my ($b1,$b1T)=(0,0); for my $dd (1..4){ my $t=1000*Q($S,$a,$dd)/c($dd); if($t>$b1T){$b1T=$t;$b1=$dd} }
  my $g=100*($bT/$Tc-1); my $g1=100*($b1T/$Tc-1);
  $sum{$name}+=$g1*$w[$ai]; $n{$name}+=$w[$ai];
  printf "%-7s %5.2f | %4d %9.1f %7d %9.1f %6.2f | %4d %9.1f %6.2f\n",$name,$a,$d,$Tc,$bd,$bT,$g,$b1,$b1T,$g1;
 } }
printf "weighted mean oracle-fixed-depth gain over controller (stationary): %s=%.2f%%\n",$_,$sum{$_}/$n{$_} for sort keys %sum;
