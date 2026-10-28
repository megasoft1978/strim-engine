# usage: itl_an.pl OUTDIR -> ITL of s1,s2 (gaps between SSE lines), overall and inside arrival windows; arrival TTFT
use strict; my $d=shift;
sub rd { my $f=shift; open my $h,'<',$f or return (); my @t=map{chomp;$_}<$h>; return @t }
my %mk; open my $m,'<',"$d/marks.txt"; while(<$m>){ my($n,$t)=split; $mk{$n}=$t if $t } close $m;
my (@all, %win);
for my $s (qw(s1 s2)) { my @t=rd("$d/$s.ts"); for my $i (1..$#t){ my $g=$t[$i]-$t[$i-1]; push @all,$g; } }
sub pct { my($p,@v)=@_; return 0 unless @v; my @s=sort{$a<=>$b}@v; my $i=int($p*@s); $i=$#s if $i>$#s; $i=0 if $i<0; return $s[$i] }
for my $a (qw(a512 a4k)) { my @t=rd("$d/$a.ts"); my $ttft = @t ? sprintf("%.3f",$t[0]-$mk{$a}) : "NA"; print "$a TTFT_s=$ttft\n"; }
printf "ITL s1+s2 all: n=%d p50=%.3f p95=%.3f max=%.3f s\n", scalar(@all), pct(0.5,@all), pct(0.95,@all), pct(1,@all);
# gaps whose end falls inside [arrival start, arrival first token + 1 s] for a512 and a4k
for my $a (qw(a512 a4k)) { my @g; my @t0; my $lo=$mk{$a}; my @at=rd("$d/$a.ts"); my $hi=@at?$at[0]+1:$lo+30;
  for my $s (qw(s1 s2)) { my @t=rd("$d/$s.ts"); for my $i (1..$#t){ push @g,$t[$i]-$t[$i-1] if $t[$i]>=$lo && $t[$i]<=$hi } }
  printf "ITL during %s arrival: n=%d p95=%.3f max=%.3f s\n", $a, scalar(@g), pct(0.95,@g), pct(1,@g);
}
