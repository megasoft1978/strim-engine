import type { Path, Segment } from './types.ts';

/** Append a child without mutating a parent shared by sibling walks. */
export function childPath(parent: Path, segment: Segment): Path {
  return [...parent, String(segment)];
}

/** Dot notation for fields and bracket notation for numeric indices. */
export function formatPath(path: Path): string {
  let result = '';
  for (const segment of path) {
    if (typeof segment === 'number') {
      result += `[${segment}]`;
    } else if (result) {
      result += `.${segment}`;
    } else {
      result = segment;
    }
  }
  return result;
}

/** Look up a value without throwing when an intermediate value is absent. */
export function getAt(root: unknown, path: Path): unknown {
  let value = root;
  for (const part of path) {
    if (value === null || typeof value !== 'object') return undefined;
    value = (value as Record<string | number, unknown>)[part];
  }
  return value;
}
