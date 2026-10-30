require 'json'
require 'digest'
# CPU-only safetensors comparison for a stopped quality gate; never invokes MLX.
def read_header(path)
  File.open(path,'rb') do |f|
    n=f.read(8).unpack1('Q<')
    raise 'invalid safetensors header length' if n>100_000_000
    [JSON.parse(f.read(n)),8+n]
  end
end
a,b=ARGV.fetch(0),ARGV.fetch(1)
ah,ao=read_header(a);bh,bo=read_header(b)
result={base:a,fork:b,header_identical:ah==bh,tensors:[]}
(ah.keys|bh.keys).sort.reject{|key|key=='__metadata__'}.each do |key|
  x,y=ah[key],bh[key]
  if !x || !y || x['dtype']!=y['dtype'] || x['shape']!=y['shape']
    result[:tensors] << {name:key,base_header:x,fork_header:y,identical:false};next
  end
  ab=File.binread(a,x['data_offsets'][1]-x['data_offsets'][0],ao+x['data_offsets'][0])
  bb=File.binread(b,y['data_offsets'][1]-y['data_offsets'][0],bo+y['data_offsets'][0])
  row={name:key,shape:x['shape'],dtype:x['dtype'],identical:ab==bb,base_sha256:Digest::SHA256.hexdigest(ab),fork_sha256:Digest::SHA256.hexdigest(bb)}
  unless row[:identical]
    raise "unsupported dtype #{x['dtype']}" unless %w[F32 I32].include?(x['dtype'])
    aa=ab.unpack('L<*');ba=bb.unpack('L<*');diff=[];count=0
    aa.zip(ba).each_with_index do |(u,v),index|
      next if u==v
      count+=1
      if diff.size<16
        fmt=x['dtype']=='F32' ? 'e' : 'l<'
        diff << {index:index,base_bits:format('%08x',u),fork_bits:format('%08x',v),base_value:[u].pack('L<').unpack1(fmt),fork_value:[v].pack('L<').unpack1(fmt)}
      end
    end
    row[:different_words]=count;row[:first_differences]=diff
  end
  result[:tensors] << row
end
result[:identical]=result[:header_identical]&&result[:tensors].all?{|r|r[:identical]}
puts JSON.pretty_generate(result)
