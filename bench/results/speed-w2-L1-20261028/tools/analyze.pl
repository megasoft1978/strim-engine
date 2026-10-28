# usage: perl analyze.pl server.trace T0 T1 : units with start ts in [T0,T1]; durations; per-request prefill/first-token
use strict; my ($f,$t0,$t1)=@ARGV; open my $fh,'<',$f or die;
my @u;
while(<$fh>){ next unless /^(\d+\.\d+) \[engine\] unit (\d+) (\S+?)(\(\d+\))? (.*)$/; my ($ts,$n,$k,$id,$rest)=($1,$2,$3,$4,$5);
  $id =~ s/[()]//g; my @reqs = ($rest =~ /r(\d+):I?B?g(\d+)/g); push @u,{ts=>$ts,n=>$n,k=>$k,id=>$id,raw=>$rest};
}
for my $i (0..$#u){ my $d = ($i<$#u)? $u[$i+1]{ts}-$u[$i]{ts} : 0; $u[$i]{d}=$d; }
my %first; my %prefillTime; my %pdur; 
my $start=undef;
for my $i (0..$#u){ my $x=$u[$i]; next if $x->{ts}<$t0 || $x->{ts}>$t1;
  $start//=$x->{ts};
  if($x->{k} eq 'prefill'){ push @{$pdur{$x->{id}}}, sprintf("%.0f",$x->{d}*1000); }
  $x->{mark}=1;
  printf "%8.3f %-12s %-3s %6.0f ms  %s\n", $x->{ts}-$start, $x->{k}, $x->{id}, $x->{d}*1000, substr($x->{raw},0,120);
}
for my $id (sort keys %pdur){ print "prefill units id=$id ms=[@{$pdur{$id}}]\n" }
