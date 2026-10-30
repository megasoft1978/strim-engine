import test from 'node:test';
import assert from 'node:assert/strict';
import { array, object, value, named, required, minLength, validate, FormSession, messagesAt, summarize, normalizeRecord, trimText, parseInteger } from '../src/index.ts';

const schema = object({
  teams: array(object({
    name: value(required()),
    members: array(object({ email: value(required(), minLength(5)) }))
  })),
  title: value(required())
});

test('reports the fields a user needs to correct', async () => {
  const result = await validate(schema, { title: '', teams: [
    { name: 'One', members: [{ email: 'abc' }, { email: '' }] },
    { name: '', members: [{ email: 'valid@example.org' }] }
  ] });
  assert.deepEqual(result.issues.map(x => [x.path, x.code]), [
    ['teams[0].members[0].email', 'minLength'],
    ['teams[0].members[1].email', 'required'],
    ['teams[0].members[1].email', 'minLength'],
    ['teams[1].name', 'required'], ['title', 'required']
  ]);
  assert.deepEqual(messagesAt(result, 'teams[0].members[1].email'), ['Required', 'Use at least 5 characters']);
});

test('keeps numeric-looking field names distinct from list positions', async () => {
  const s = object({ '0': value(required()), rows: array(value(required())) });
  const result = await validate(s, { '0': '', rows: [''] });
  assert.deepEqual(result.issues.map(x => x.path), ['0', 'rows[0]']);
});

test('root arrays and nested arrays identify each element', async () => {
  const result = await validate(array(array(value(required()))), [[''], ['', 'ok']]);
  assert.deepEqual(result.issues.map(x => x.path), ['[0][0]', '[1][0]']);
});

test('later successful checks remain current when earlier checks finish last', async () => {
  const gates = new Map();
  const s = value(named('remote', x => new Promise(resolve => gates.set(x, resolve))));
  const session = new FormSession(s);
  const seen = [];
  session.subscribe(result => seen.push(result));
  const old = session.check('old');
  const recent = session.check('recent');
  gates.get('recent')(null);
  const recentResult = await recent;
  gates.get('old')('Taken');
  const oldResult = await old;
  assert.equal(oldResult.valid, false);
  assert.equal(session.current, recentResult);
  assert.deepEqual(seen, [recentResult]);
});

test('a newer pending check suppresses an older completion', async () => {
  const gates = new Map();
  const session = new FormSession(value(named('remote', x => new Promise(resolve => gates.set(x, resolve)))));
  const seen = []; session.subscribe(x => seen.push(x));
  const first = session.check('first');
  const second = session.check('second');
  gates.get('first')('Unavailable');
  await first;
  assert.equal(session.current, null);
  assert.equal(seen.length, 0);
  gates.get('second')(null);
  const result = await second;
  assert.equal(session.current, result);
  assert.deepEqual(seen, [result]);
});

test('rule and child order is deterministic despite async completion order', async () => {
  const s = object({ a: value(named('slow', async () => { await new Promise(r => setTimeout(r, 5)); return 'A'; })), b: value(named('fast', async () => 'B')) });
  const result = await validate(s, { a: 1, b: 2 });
  assert.deepEqual(result.issues.map(x => x.message), ['A', 'B']);
  assert.equal(summarize(result), 'a: A\nb: B');
});

test('normalization helpers leave input untouched', () => {
  const input = { name: ' Ada ', age: '42' };
  assert.deepEqual(normalizeRecord(input, { name: trimText, age: parseInteger }), { name: 'Ada', age: 42 });
  assert.equal(input.name, ' Ada ');
});

test('subscribers can unsubscribe and results remain independent', async () => {
  const session = new FormSession(value(required()));
  let calls = 0; const unsubscribe = session.subscribe(() => calls++);
  const first = await session.check(''); unsubscribe();
  const second = await session.check('ok');
  assert.equal(first.valid, false); assert.equal(second.valid, true); assert.equal(calls, 1);
});
