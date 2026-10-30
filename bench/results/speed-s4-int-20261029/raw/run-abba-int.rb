require 'json'
require 'fileutils'
require 'time'
ROOT='/Users/user/Desktop/Freelance/strim-engine/bench/results/speed-s4-int-20261029/raw'
MODEL=File.expand_path('~/.strim/models/qwen38-4bit')
BINS={'base'=>'/tmp/s4/build-base-int/release/S4IntegrationBench','fork'=>'/tmp/s4/build-int/release/S4IntegrationBench'}
CELLS={'c1'=>['decode',MODEL,'1','3','64'],'c4'=>['decode',MODEL,'4','3','64'],'c8'=>['decode',MODEL,'8','3','64'],'verify'=>['verify',MODEL,'3','12'],'n4096'=>['prefill',MODEL,'4096','3'],'n16384'=>['prefill',MODEL,'16384','3']}
def rows(path)
  File.readlines(path).map{|line|JSON.parse(line)}.reject{|r|r['kind']=='meta'}
end
if ARGV[0]=='block'
  block=ARGV[1];arm=ARGV[2];dir="#{ROOT}/abba/#{block}"
  FileUtils.mkdir_p(dir)
  File.write("#{dir}/start.txt",Time.now.utc.iso8601+"\n")
  system('uptime',out:"#{dir}/load.txt")
  system('sysctl','-n','vm.swapusage',out:"#{dir}/swap.txt")
  CELLS.each do |name,args|
    path="#{dir}/#{name}.jsonl"
    abort "BLOCKED: #{block} #{name}" unless system(BINS[arm],*args,out:path,err:"#{path}.stderr")
    rs=rows(path)
    groups=rs.group_by{|r|[r['kind'],r['c']||r['n']||r['width']]}
    abort "BLOCKED: #{block} #{name} missing samples" unless groups.values.all?{|a|a.map{|r|r['rep']}.sort==[-1,0,1,2]}
    ref="#{ROOT}/abba/1-1-base/#{name}.jsonl"
    if path!=ref
      baseline=rows(ref)
      fields=%w[kind c n width rep steps hashes hash next logit_hash]
      normalize=->(a){a.map{|r|r.select{|k,v|fields.include?(k)}}}
      unless normalize.call(rs)==normalize.call(baseline)
        File.write("#{ROOT}/abba/DIFF.json",JSON.pretty_generate({block:block,cell:name,base:normalize.call(baseline),current:normalize.call(rs)})+"\n")
        abort "BLOCKED: #{block} #{name} outputs differ"
      end
    end
  end
  File.write("#{dir}/end.txt",Time.now.utc.iso8601+"\n")
  puts "completed #{block}"
else
  [1,2].each do |cycle|
    %w[base fork fork base].each_with_index do |arm,index|
      block="#{cycle}-#{index+1}-#{arm}"
      puts "#{Time.now.utc.iso8601} waiting for GPU lock: #{block}";STDOUT.flush
      abort "BLOCKED: #{block}" unless system('lockf','-k','/tmp/strim-bench.lock',RbConfig.ruby,__FILE__,'block',block,arm)
    end
  end
end
