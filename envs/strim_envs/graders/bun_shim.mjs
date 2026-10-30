// Trusted stand-in for `bun:test` (grader-owned). Tests register into a registry that only
// the grader's runner holds; the shim exports no state. Matchers cover the subset the
// tasks use; an unknown matcher throws, which fails the test (fail closed).
const hook = globalThis[Symbol.for('strim.hook')];
delete globalThis[Symbol.for('strim.hook')];
const is = Object.is;
const keys = Object.keys;
const isArray = Array.isArray;
const hasOwn = Object.prototype.hasOwnProperty;
const defined = (o) => keys(o).filter((k) => o[k] !== undefined);

function equal(a, b) {
  if (is(a, b)) return true;
  if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null) return false;
  if (isArray(a) !== isArray(b)) return false;
  if (a instanceof Date || b instanceof Date) return a instanceof Date && b instanceof Date && a.getTime() === b.getTime();
  const ka = defined(a);
  const kb = defined(b);
  if (ka.length !== kb.length) return false;
  return ka.every((k) => hasOwn.call(b, k) && equal(a[k], b[k]));
}

function matchers(actual, negate) {
  const check = (pass, what) => { if (pass === negate) throw new Error('expect ' + (negate ? 'not ' : '') + what); };
  return {
    toBe: (x) => check(is(actual, x), 'toBe'),
    toEqual: (x) => check(equal(actual, x), 'toEqual'),
    toStrictEqual: (x) => check(equal(actual, x), 'toStrictEqual'),
    toContain: (x) => check(actual != null && typeof actual.includes === 'function' && actual.includes(x), 'toContain'),
    toHaveLength: (n) => check(actual != null && actual.length === n, 'toHaveLength'),
    toBeTruthy: () => check(!!actual, 'toBeTruthy'),
    toBeFalsy: () => check(!actual, 'toBeFalsy'),
    toBeNull: () => check(actual === null, 'toBeNull'),
    toBeUndefined: () => check(actual === undefined, 'toBeUndefined'),
    toBeDefined: () => check(actual !== undefined, 'toBeDefined'),
    toMatch: (re) => check(typeof re === 'string' ? String(actual).includes(re) : re.test(String(actual)), 'toMatch'),
    toBeGreaterThan: (n) => check(actual > n, 'toBeGreaterThan'),
    toBeLessThan: (n) => check(actual < n, 'toBeLessThan'),
    toThrow: () => {
      let threw = false;
      try { actual(); } catch { threw = true; }
      check(threw, 'toThrow');
    },
  };
}

export function expect(actual) {
  return { ...matchers(actual, false), not: matchers(actual, true) };
}
export const test = (name, fn) => hook.add(name, fn);
export const it = test;
export const describe = (name, fn) => { hook.push(name); try { fn(); } finally { hook.pop(); } };
export const beforeEach = (fn) => hook.hook('beforeEach', fn);
export const afterEach = (fn) => hook.hook('afterEach', fn);
export const beforeAll = (fn) => hook.hook('beforeAll', fn);
export const afterAll = (fn) => hook.hook('afterAll', fn);
