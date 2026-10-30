require 'json'
ROOT='/Users/user/Desktop/Freelance/strim-engine/bench/results/speed-s4-int-20261029'
def median(a)
  a=a.sort;n=a.size;raise 'empty sample' if n==0
  n.odd? ? a[n/2] : (a[n/2-1]+a[n/2])/2.0
end
groups={}
paths=Dir["#{ROOT}/raw/abba/*/*.jsonl"].sort
raise "incomplete ABBA: #{paths.size}/48 files" unless paths.size==48
paths.each do |path|
  cycle,index,arm=File.basename(File.dirname(path)).split('-')
  rows=File.readlines(path).map{|l|JSON.parse(l)}.select{|r|r['rep'] && r['rep']>=0}
  rows.group_by{|r|[r['kind'],r['c']||r['n']||r['width']]}.each do |key,rs|
    raise "bad reps #{path}" unless rs.map{|r|r['rep']}.sort==[0,1,2]
    metric={'decode'=>'aggregate_tps','prefill'=>'tps','verify'=>'ms'}[key[0]]
    (groups[key]||=[]) << {cycle:cycle.to_i,index:index.to_i,arm:arm,median:median(rs.map{|r|r[metric]}),samples:rs.map{|r|r[metric]},peak_bytes:rs.map{|r|r['mlx_peak_bytes']}.max,outputs:rs.map{|r|r['hashes']||r['hash']||r['logit_hash']||r['next']}.uniq}
  end
end
rows=groups.map do |key,bs|
  raise "bad block count #{key}" unless bs.size==8
  raise "output mismatch #{key}" unless bs.flat_map{|b|b[:outputs]}.uniq.size==1
  a=bs.select{|b|b[:arm]=='base'};b=bs.select{|r|r[:arm]=='fork'}
  am=median(a.map{|r|r[:median]});bm=median(b.map{|r|r[:median]})
  cycles=bs.group_by{|r|r[:cycle]}.map do |cycle,rs|
    aa=rs.select{|r|r[:arm]=='base'}.map{|r|r[:median]};bb=rs.select{|r|r[:arm]=='fork'}.map{|r|r[:median]}
    raise "cycle incomplete #{key}" unless aa.size==2 && bb.size==2
    {cycle:cycle,change_pct:(Math.sqrt(bb.inject(:*))/Math.sqrt(aa.inject(:*))-1)*100,noise_pct:[(aa[1]/aa[0]-1).abs,(bb[1]/bb[0]-1).abs].max*100}
  end
  {kind:key[0],size:key[1],unit:{'verify'=>'ms/pass','decode'=>'aggregate tok/s','prefill'=>'tok/s'}[key[0]],base:am,fork:bm,change_pct:(bm/am-1)*100,cycles:cycles,base_peak_bytes:a.map{|r|r[:peak_bytes]}.max,fork_peak_bytes:b.map{|r|r[:peak_bytes]}.max,identical_outputs:true,blocks:bs}
end
c8=rows.find{|r|r[:kind]=='decode'&&r[:size]==8};c1=rows.find{|r|r[:kind]=='decode'&&r[:size]==1}
noise=c1[:cycles].map{|r|r[:noise_pct]}.max
keep=c8[:change_pct]>=2 && c1[:change_pct]>=-noise
result={keep:keep,c1_noise_pct:noise,rows:rows}
File.write("#{ROOT}/raw/analysis.json",JSON.pretty_generate(result)+"\n")
puts JSON.pretty_generate(result.reject{|k,v|k==:rows})
rows.each{|r|puts "#{r[:kind]} #{r[:size]}: #{r[:base].round(3)} -> #{r[:fork].round(3)} (#{r[:change_pct].round(3)}%); #{r[:cycles]}"}
abort 'BLOCKED: keep gate failed' unless keep
