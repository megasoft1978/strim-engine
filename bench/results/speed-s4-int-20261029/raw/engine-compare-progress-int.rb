require 'json'
require 'digest'
root='/Users/user/Desktop/Freelance/strim-engine/bench/results/speed-s4-int-20261029/raw/gates'
def rows(path)
  return [] unless File.exist?(path)
  File.readlines(path).select{|l|l.end_with?("\n")&&l.start_with?('S4_ENGINE ')}.map{|l|JSON.parse(l.sub(/^S4_ENGINE /,''))}
end
a=rows("#{root}/engine-base.txt");b=rows("#{root}/engine-fork.txt")
b.each_with_index do |r,i|
  next if a[i]==r
  diff={run_index:i,base:a[i],fork:r}
  if a[i]
    diff[:sequences]=(0...[a[i]['tokens'].size,r['tokens'].size].max).filter_map do |seq|
      x=a[i]['tokens'][seq]||[];y=r['tokens'][seq]||[];next if x==y
      first=(0...[x.size,y.size].max).find{|j|x[j]!=y[j]}
      {sequence:seq,first_difference:first,base_length:x.size,fork_length:y.size,base_token:x[first],fork_token:y[first],base_sha256:Digest::SHA256.hexdigest(x.pack('l<*')),fork_sha256:Digest::SHA256.hexdigest(y.pack('l<*'))}
    end
  end
  File.write("#{root}/engine-live-diff.json",JSON.pretty_generate(diff)+"\n")
  puts "BLOCKED: engine run #{i} differs; #{diff[:sequences]}";exit 2
end
puts "engine fork: #{b.size}/#{a.size} complete runs identical so far"
