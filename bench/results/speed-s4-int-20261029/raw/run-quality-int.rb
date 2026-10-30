require 'json'
require 'fileutils'
ROOT='/Users/user/Desktop/Freelance/strim-engine/bench/results/speed-s4-int-20261029/raw'
MODEL=File.expand_path('~/.strim/models/qwen38-4bit')
BINS={'base'=>'/tmp/s4/build-base-int/release/S4IntegrationBench','fork'=>'/tmp/s4/build-int/release/S4IntegrationBench'}
FileUtils.mkdir_p("#{ROOT}/quality")
%w[qualitybatch qualityverify quality].each do |mode|
  %w[base fork].each do |arm|
    dest="/tmp/s4/quality-int/#{arm}"
    args=[BINS[arm],mode,MODEL,dest]
    args << '/tmp/s4/quality-int/base' if arm=='fork'
    path="#{ROOT}/quality/#{mode}-#{arm}.jsonl"
    puts "waiting for GPU lock: #{mode} #{arm}"; STDOUT.flush
    ok=system('lockf','-k','/tmp/strim-bench.lock',*args,out:path,err:"#{path}.stderr")
    abort "BLOCKED: #{mode} #{arm}" unless ok
    rows=File.readlines(path).map{|l|JSON.parse(l)}.reject{|r|r['kind']=='meta'}
    expected={'qualitybatch'=>5,'qualityverify'=>3,'quality'=>8}[mode]
    abort "BLOCKED: incomplete #{mode} #{arm}" unless rows.size==expected
    if arm=='fork'
      base=File.readlines("#{ROOT}/quality/#{mode}-base.jsonl").map{|l|JSON.parse(l)}.reject{|r|r['kind']=='meta'}
      rows.zip(base).each do |r,b|
        ok=r['different_float_bits']==0 && r['max_abs_diff']==0
        ok &&= r['hashes']==b['hashes'] if r['hashes']
        ok &&= r['hash']==b['hash'] if r['hash']
        ok &&= r['free_greedy_identical'] && r['teacher_forced_agreement']==64 if mode=='quality'
        ok &&= r['teacher_forced_agreement']==r['tokens'] if mode!='quality'
        unless ok
          File.write("#{ROOT}/quality/DIFF.json",JSON.pretty_generate({mode:mode,base:b,fork:r})+"\n")
          abort "BLOCKED: #{mode} quality differs"
        end
      end
    end
    puts "PASS #{mode} #{arm}"; STDOUT.flush
  end
end
