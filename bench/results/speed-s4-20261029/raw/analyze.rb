require 'json'
ROOT='/Users/user/Desktop/Freelance/strim-engine/bench/results/speed-s4-20261029'
def median(values)
  a=values.sort; n=a.size
  n.odd? ? a[n/2] : (a[n/2-1]+a[n/2])/2.0
end
def read_rows(path)
  File.readlines(path).map { |line| JSON.parse(line) rescue nil }.compact.select { |r| r['rep'] && r['rep'] >= 0 }
end
summary={}
%w[cap fuse].each do |part|
  grouped={}
  Dir["#{ROOT}/raw/#{part}/*/*.jsonl"].sort.each do |path|
    block=File.basename(File.dirname(path)); cycle,index,arm=block.split('-')
    read_rows(path).group_by { |r| [r['kind'],r['c'] || r['n'] || r['width']] }.each do |key,rows|
      metric={'decode'=>'aggregate_tps','prefill'=>'tps','verify'=>'ms'}[key[0]]
      (grouped[key] ||= []) << {block:block,cycle:cycle.to_i,index:index.to_i,arm:arm,median:median(rows.map{|r|r[metric]}),samples:rows.map{|r|r[metric]}}
    end
  end
  summary[part]=grouped.map do |key,blocks|
    base_arm=part=='cap' ? 'base' : '0'
    a=blocks.select{|b|b[:arm]==base_arm}; b=blocks.reject{|r|r[:arm]==base_arm}
    next if a.empty? || b.empty?
    am=median(a.map{|r|r[:median]}); bm=median(b.map{|r|r[:median]})
    cycles=blocks.group_by{|r|r[:cycle]}.map do |cycle,rs|
      aa=rs.select{|r|r[:arm]==base_arm}.map{|r|r[:median]}
      bb=rs.reject{|r|r[:arm]==base_arm}.map{|r|r[:median]}
      next unless aa.size==2 && bb.size==2
      # Ratio of geometric means cancels linear time drift in log performance.
      gain=(Math.sqrt(bb.inject(:*))/Math.sqrt(aa.inject(:*))-1)*100
      noise=[(aa[1]/aa[0]-1).abs,(bb[1]/bb[0]-1).abs].max*100
      {cycle:cycle,gain_pct:gain,same_arm_drift_pct:noise}
    end.compact
    {kind:key[0],size:key[1],metric:{'decode'=>'aggregate tok/s','prefill'=>'tok/s','verify'=>'ms/pass'}[key[0]],base:am,candidate:bm,change_pct:(bm/am-1)*100,
     request_base:key[0]=='decode' ? am/key[1] : nil,request_candidate:key[0]=='decode' ? bm/key[1] : nil,cycles:cycles,blocks:blocks}
  end.compact
end
File.write("#{ROOT}/raw/analysis.json",JSON.pretty_generate(summary)+"\n")
summary.each do |part,rows|
  puts part
  rows.each do |r|
    puts "#{r[:kind]} #{r[:size]}: #{r[:base].round(4)} -> #{r[:candidate].round(4)} #{r[:metric]} (#{r[:change_pct].round(3)}%); cycles #{r[:cycles]}"
  end
end
