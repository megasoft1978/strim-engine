require 'json'
require 'fileutils'
ROOT='/Users/user/Desktop/Freelance/strim-engine/bench/results/speed-s4-int-20261029'
MODEL=File.expand_path('~/.strim/models/qwen38-4bit')
HEAD=File.expand_path('~/.strim/models/qwen38-mtp-4bit')
BINS={'base'=>'/tmp/s4/build-base-int/release/strim','fork'=>'/tmp/s4/build-int/release/strim'}
def normalized(kind,text)
  lines=text.lines.map(&:strip)
  case kind
  when 'gen16' then lines.grep(/^ids:/)
  when 'benchspec0' then lines.grep(/^parity:/)
  when /^prefix/
    lines.grep(/(?:^PASS|^FAIL|^hash |^miss ref:|^hot:|^append-logits:|^hot-continue|^checkprefix:)/).map{|l|l.sub(/  prefill [\d.]+ s$/, '').sub(/(hash [a-f0-9]+\s+tokens \[.*\])\s+[\d.]+ s$/, '\\1')}
  when 'engine'
    lines.grep(/(?:^S4_ENGINE |identical-to-solo|^PASS|^FAIL|enginebench:)/).map{|l|l.include?('identical-to-solo') ? l.sub(/: agg .* identical-to-solo /, ': identical-to-solo ') : l}
  when /^batch/ then lines
  end
end
cases=[['gen16',['gen',MODEL,'16']],['benchspec0',['benchspec',MODEL,HEAD,'64','0']]]
[4096,8192].each{|n|cases << ["prefix#{n}",['checkprefix',MODEL,n.to_s,'3',HEAD]]}
cases << ['engine',['enginebench',MODEL,HEAD,'--only=concurrent-decode']]
[1,4,6,7,8].each{|b|cases << ["batch#{b}",['checkbatchparity',MODEL,'512',b.to_s,'16']]}
results={}
FileUtils.mkdir_p("#{ROOT}/raw/gates")
cases.each do |name,args|
  puts "#{Time.now.utc.iso8601 rescue Time.now} waiting lock #{name}"; STDOUT.flush
  # One lock across both arms, released between cases. Never remove the lock.
  command = [RbConfig.ruby,__FILE__,'pair',name,*args]
  if ARGV[0]!='pair'
    ok=system('lockf','-k','/tmp/strim-bench.lock',*command)
    abort "BLOCKED: #{name}" unless ok
    results[name]=JSON.parse(File.read("#{ROOT}/raw/gates/#{name}.json"))
    File.write("#{ROOT}/raw/gates.json",JSON.pretty_generate(results)+"\n")
    next
  end
  break
end if ARGV[0]!='pair'
if ARGV[0]=='pair'
  name=ARGV[1];args=ARGV.drop(2)
  outputs={}
  BINS.each do |arm,binary|
    path="#{ROOT}/raw/gates/#{name}-#{arm}.txt"
    warn "#{Time.now} running #{name} #{arm}"
    binary = binary.sub(/strim$/, "S4IntegrationBench") if name == "engine"
    ok=system(binary,*args,out:path,err:"#{path}.stderr")
    abort "BLOCKED: #{name} #{arm} exit #{$?.exitstatus}" unless ok
    text=File.read(path)
    abort "BLOCKED: #{name} #{arm} reports failure" if text.match?(/parity: MISMATCH|\bFAIL\b|FAILED|SUSPECT/)
    outputs[arm]=normalized(name,text)
    abort "BLOCKED: empty oracle #{name}" if outputs[arm].nil? || outputs[arm].empty?
  end
  same=outputs['base']==outputs['fork']
  result={identical:same,base:outputs['base'],fork:outputs['fork']}
  File.write("#{ROOT}/raw/gates/#{name}.json",JSON.pretty_generate(result)+"\n")
  unless same
    system('diff','-u',"#{ROOT}/raw/gates/#{name}-base.txt","#{ROOT}/raw/gates/#{name}-fork.txt",out:"#{ROOT}/raw/gates/#{name}.diff")
    abort "BLOCKED: #{name} outputs differ"
  end
  puts "PASS #{name}: identical"
end
