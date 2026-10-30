// Trusted node:test runner (grader-owned, read-only to the sandbox).
// argv: <nonce-fd> <result-fd> <glob>... ; tests run in this process (isolation none),
// so there is no child stdout/IPC stream for agent code to forge.
import { closeSync, globSync, readFileSync, writeSync } from 'node:fs';
import { relative, resolve } from 'node:path';
import { run } from 'node:test';

const stringify = JSON.stringify;
const write = writeSync;
const [nonceFd, chan, ...patterns] = process.argv.slice(2).map((v, i) => (i < 2 ? Number(v) : v));
const nonce = readFileSync(nonceFd, 'ascii').trim();
closeSync(nonceFd);
const emit = (record) => write(chan, nonce + ' ' + stringify(record) + '\n');

const cwd = process.cwd();
const files = [...new Set(patterns.flatMap((p) => globSync(p, { cwd })))].sort().map((f) => resolve(cwd, f));
let total = 0;
let ok = files.length > 0;
const stream = run({ files, isolation: 'none', concurrency: 1 });
for await (const event of stream) {
  if (event.type !== 'test:pass' && event.type !== 'test:fail') continue;
  const data = event.data;
  const name = (data.file ? relative(cwd, data.file) : '?') + '::' + data.name;
  const clean = event.type === 'test:pass' && !data.skip && !data.todo;
  total += 1;
  if (!clean) ok = false;
  emit({ k: clean ? 'pass' : 'fail', n: name });
}
emit({ k: 'end', total, ok });
process.exit(ok ? 0 : 1);
