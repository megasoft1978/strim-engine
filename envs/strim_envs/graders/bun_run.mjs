// Trusted test runner for Bun projects (grader-owned, read-only to the sandbox).
// argv: <nonce-fd> <result-fd> <shim-path> <glob>... ; `bun:test` imports in test files are
// redirected to the grader's shim, so no report file or stdout stream is involved.
import { plugin } from 'bun';
import { closeSync, globSync, readFileSync, writeSync } from 'node:fs';
import { relative, resolve } from 'node:path';

const stringify = JSON.stringify;
const write = writeSync;
const [nonceFd, chan, shim, ...patterns] = process.argv.slice(2).map((v, i) => (i < 2 ? Number(v) : v));
const nonce = readFileSync(nonceFd, 'ascii').trim();
closeSync(nonceFd);
const emit = (record) => write(chan, nonce + ' ' + stringify(record) + '\n');

const cwd = process.cwd();
const tests = [];
const hooks = { beforeEach: [], afterEach: [], beforeAll: [], afterAll: [] };
const stack = [];
let current = '';
globalThis[Symbol.for('strim.hook')] = {
  add: (name, fn) => tests.push({ name: current + '::' + [...stack, name].join(' > '), fn }),
  push: (name) => stack.push(name),
  pop: () => stack.pop(),
  hook: (kind, fn) => hooks[kind].push(fn),
};
const specifier = /(['"])bun:test\1/g;
plugin({
  name: 'strim-bun-test',
  setup(build) {
    build.onLoad({ filter: /\.test\.[cm]?[jt]sx?$/ }, (args) => ({
      contents: readFileSync(args.path, 'utf8').replaceAll(specifier, JSON.stringify(shim)),
      loader: args.path.endsWith('x') ? (args.path.endsWith('.tsx') ? 'tsx' : 'jsx') : (args.path.endsWith('ts') ? 'ts' : 'js'),
    }));
  },
});
await import(shim);
const files = [...new Set(patterns.flatMap((p) => globSync(p, { cwd })))].sort().map((f) => resolve(cwd, f));
for (const file of files) {
  current = relative(cwd, file);
  await import(file);
}
let ok = files.length > 0;
for (const fn of hooks.beforeAll) await fn();
for (const t of tests) {
  let pass = true;
  try {
    for (const fn of hooks.beforeEach) await fn();
    await t.fn();
    for (const fn of hooks.afterEach) await fn();
  } catch {
    pass = false;
  }
  if (!pass) ok = false;
  emit({ k: pass ? 'pass' : 'fail', n: t.name });
}
for (const fn of hooks.afterAll) await fn();
emit({ k: 'end', total: tests.length, ok });
process.exit(ok ? 0 : 1);
