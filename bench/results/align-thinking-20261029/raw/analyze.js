const fs = require('fs');
const root = '/tmp/align1/bench';
const arms = ['off-final', 'on-final'];
const load = p => fs.readFileSync(p, 'utf8').trim().split('\n').map(JSON.parse);
const wilson = (x,n) => {let z=1.95996398454, p=x/n, den=1+z*z/n, c=(p+z*z/(2*n))/den, h=z*Math.sqrt(p*(1-p)/n+z*z/(4*n*n))/den; return [c-h,c+h];};
const rows = Object.fromEntries(arms.map(a=>[a,load(`${root}/${a}/ledger.jsonl`)]));
const invalid = r => r.infra_error || (r.verify_note || '').includes('PermissionDenied');
const paired = rows['off-final'].map(o=>[o,rows['on-final'].find(n=>n.task_id===o.task_id)]).filter(([o,n])=>n && !invalid(o) && !invalid(n));
const output={};
for (const a of arms) {
 const rs=rows[a], valid=rs.filter(r=>!invalid(r)), state=fs.readdirSync(`${root}/${a}`).find(n=>n.startsWith('server-state-')), path=`${root}/${a}/${state}/jobs`;
 let total=0, seconds=0, missing=0, errors=0, compactions=0, malformed=0, parsed=0;
 for (const d of fs.readdirSync(path)) {
  const dir=`${path}/${d}`; if(!fs.statSync(dir).isDirectory()) continue;
  const result=JSON.parse(fs.readFileSync(`${dir}/result.json`)); if(result.usage){total+=result.usage.completion_tokens||0; seconds+=result.usage.seconds||0;}else missing++;
  const ep=`${dir}/events.jsonl`; if(!fs.existsSync(ep)) continue;
  for (const line of fs.readFileSync(ep,'utf8').split('\n')) {if(!line) continue;let e;try{e=JSON.parse(line);parsed++}catch{malformed++;continue}; if(e.type==='tool_result' && e.is_error===true) errors++; if(e.type==='tool_result' && e.name==='_compaction') compactions++;}
 }
 const pass=valid.filter(r=>r.success).length;
 output[a]={passes:pass,valid:valid.length,interval:wilson(pass,valid.length),unverified:rs.filter(invalid).map(r=>r.task_id),wall_mean:rs.reduce((s,r)=>s+r.wall_s,0)/rs.length,wall_total:rs.reduce((s,r)=>s+r.wall_s,0),generated_tokens:total,engine_seconds:seconds,usage_missing:missing,observed_tool_errors:errors,observed_compactions:compactions,parsed_event_lines:parsed,malformed_event_lines:malformed,timeout_wall_rows:rs.filter(r=>r.wall_s>=900).map(r=>r.task_id)};
}
output.pairs={n:paired.length,both_pass:paired.filter(([a,b])=>a.success&&b.success).length,only_off:paired.filter(([a,b])=>a.success&&!b.success).length,only_on:paired.filter(([a,b])=>!a.success&&b.success).length,both_fail:paired.filter(([a,b])=>!a.success&&!b.success).length,excluded:rows['off-final'].filter(a=>!paired.some(([b])=>b.task_id===a.task_id)).map(x=>x.task_id),off_mean:paired.reduce((s,[a])=>s+a.wall_s,0)/paired.length,on_mean:paired.reduce((s,[,b])=>s+b.wall_s,0)/paired.length};
console.log(JSON.stringify(output,null,2));
