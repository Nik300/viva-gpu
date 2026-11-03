#!/usr/bin/perl
# loadsum.pl <log>: pipeline-cost columns of the stats/5s lines, plus totals
my %t; my @k=("draws","translations","disk cache hits","program links","program hits","variant links","programs drawn","pipelines","pipeline create ms","link ms","warm-up ms","translate ms","gpu-queue busy ms","pipeline sync ms");
my @n=qw(draws tr hits links phits var drawn pipes create link warm trans busy sync);
while(<>){ next unless /stats\/5s/; my %h; while(/ ([a-z\- ()~]+?)=(\d+)/g){$h{$1}=$2} next unless $h{"pipelines"}||$h{"program links"};
  print join(" ", map {"$n[$_]=".($h{$k[$_]}//0)} 0..$#k), "\n"; $t{$_}+=$h{$_} for @k }
print "TOTAL ", join(" ", map {"$n[$_]=".($t{$k[$_]}//0)} 0..$#k), "\n";
printf "GPU queue occupied = busy + pipeline sync = %d ms\n", $t{"gpu-queue busy ms"} + $t{"pipeline sync ms"};
