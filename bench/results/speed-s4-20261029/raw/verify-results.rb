require 'json'
root='/Users/user/Desktop/Freelance/strim-engine/bench/results/speed-s4-20261029/raw'
def records(path)
  File.readlines(path).map{|line|JSON.parse(line)}
end
report={}
%w[cap fuse].each do |part|
  files=Dir["#{root}/#{part}/*/*.jsonl"]
  raise "#{part} incomplete: #{files.size} files" unless files.size==(part=='cap' ? 32 : 16)
  cells={}
  files.each do |path|
    rows=records(path).select{|r|r['rep'] && r['rep']>=0}
    rows.group_by{|r|[r['kind'],r['c']||r['n']||r['width']]}.each do |key,rs|
      raise "reps #{path} #{key}" unless rs.map{|r|r['rep']}.sort==[0,1,2]
      (cells[key]||=[]).concat(rs)
    end
  end
  report[part]=cells.map do |key,rs|
    raise "incomplete #{part} #{key}" unless rs.size==24
    hashes=rs.map{|r|r['hashes'] || r['hash']}.compact.uniq
    {kind:key[0],size:key[1],measured_rows:rs.size,distinct_output_hashes:hashes.size,
     all_hashes_identical:hashes.empty? ? nil : hashes.size==1}
  end
end
report['quality']={}
%w[base cap8 fuse].each do |arm|
  rows=records("#{root}/quality/#{arm}.jsonl").select{|r|r['kind']=='quality'}
  raise "quality #{arm} incomplete" unless rows.size==8
  report['quality'][arm]={prompts:rows.size,max_abs_diff:rows.map{|r|r['max_abs_diff']}.max,
    different_float_bits:rows.map{|r|r['different_float_bits']}.inject(:+),
    teacher_forced_agreement:rows.map{|r|r['teacher_forced_agreement']}.inject(:+),
    tokens:rows.map{|r|r['steps']}.inject(:+),greedy_prompts_identical:rows.count{|r|r['free_greedy_identical']},rows:rows}
end
raise 'cap output hashes differ' unless report['cap'].all?{|r|r[:all_hashes_identical]}
raise 'cap greedy output mismatch' unless report['quality']['cap8'][:greedy_prompts_identical]==8
File.write("#{root}/validation.json",JSON.pretty_generate(report)+"\n")
puts JSON.pretty_generate(report.reject{|k,v|k=='quality'})
report['quality'].each{|arm,r|puts "#{arm}: #{r.reject{|k,v|k==:rows}}"}
