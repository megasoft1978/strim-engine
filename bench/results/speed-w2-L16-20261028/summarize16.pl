#!/usr/bin/perl
# usage: summarize16.pl raw   -> per-arm per-cell decode tok/s (median over rounds), mean emitted/pass, ms/pass by depth, accept by position
use strict; use warnings; my $raw = shift || "raw";
my %tps; my %tr;  # tps{arm}{cell}[round], tr{arm}{cell} list of [d,acc,ms]
for my $arm (glob "$raw/*") { my $an = $arm; $an =~ s{.*/}{};
  for my $rd (glob "$arm/r*") { my $r = $rd; $r =~ s{.*/r}{};
    my $p = (glob "$rd/strim/pass*")[0] or next;
    my @cells = (["w3","ctx-4096","4K"],["w3","ctx-16384","16K"],["w3_32k","ctx-32768","32K"]);
    for my $c (@cells) { my $f = "$p/$c->[0]/raw.jsonl"; next unless -f $f; open my $h,"<",$f;
      while (<$h>) { next unless /"kind": "request"/ && /"variant": "$c->[1]"/; if (/"decode_tps": ([\d.]+)/) { push @{$tps{$an}{$c->[2]}}, $1 } } }
    if (-f "$p/w6/raw.jsonl") { open my $h,"<","$p/w6/raw.jsonl"; my @v; while (<$h>) { push @v,$1 if /"kind": "request"/ && /"decode_tps": ([\d.]+)/ } 
      push @{$tps{$an}{"agent"}}, @v ? (sort {$a<=>$b} @v)[$#v/2] : (); }
    # trace segmentation
    open my $s,"<","$p/server.txt" or next; my ($prev,$idx)=(undef,0); my @names=(undef,undef,"4K","16K","32K","agent","agent","agent","agent");
    while (<$s>) { next unless /^TRACE ctx=(\d+) d=(\d+) acc=(\d+) ms=([\d.]+)/; my ($ctx,$d,$acc,$ms)=($1,$2,$3,$4); next if $ctx<1000;
      if (!defined $prev || $ctx < $prev || $ctx-$prev > 8) { $idx++ } $prev=$ctx;
      my $n = $names[$idx] // next; push @{$tr{$an}{$n}}, [$d,$acc,$ms]; } } }
sub med { my @s = sort {$a<=>$b} @_; @s ? $s[$#s/2] : 0 }
print "## decode tok/s (median per round; rounds listed)\n| arm | 4K | 16K | 32K | agent(4 prompts, median) |\n|---|---|---|---|---|\n";
for my $an (sort keys %tps) { print "| $an |"; for my $c (qw(4K 16K 32K agent)) { my @v=@{$tps{$an}{$c}||[]}; printf " %.1f (%s) |", med(@v), join("/",map{sprintf "%.1f",$_}@v) } print "\n" }
print "\n## W4 512-tok aggregate tok/s c=4/c=8 per round\n";
for my $arm (sort glob "$raw/*") { my @l;
  for my $f (sort glob "$arm/r*/strim/pass*/w4s/summary.md") { open my $h,"<",$f; my ($c4,$c8) = ("-","-");
    while (<$h>) { $c4=$1 if /distinct-c4 \| aggregate_tps \| ([\d.]+)/; $c8=$1 if /distinct-c8 \| aggregate_tps \| ([\d.]+)/ }
    push @l, "$c4/$c8" }
  print "$arm: @l\n" if @l }
print "\n## trace stats per arm/cell: rounds, mean emitted/pass, mean depth, ms/pass by depth, P(acc>=i | d>=i)\n";
for my $an (sort keys %tr) { for my $c (qw(4K 16K 32K agent)) { my @t=@{$tr{$an}{$c}||[]}; next unless @t; my ($e,$dd)=(0,0); my (%n,%ms,%ge,%dn);
  for (@t) { my($d,$acc,$ms)=@$_; $e+=1+$acc; $dd+=$d; $n{$d}++; $ms{$d}+=$ms; for my $i (1..$d) { $dn{$i}++; $ge{$i}++ if $acc>=$i } }
  printf "%s %s: n=%d emitted/pass=%.3f depth=%.2f | ms:", $an,$c,scalar(@t),$e/@t,$dd/@t; printf " d%d=%.1f(n%d)",$_,$ms{$_}/$n{$_},$n{$_} for sort keys %n;
  print " | P:"; printf " %d=%.3f",$_,($ge{$_}||0)/$dn{$_} for sort keys %dn; print "\n" } }
