import { getAt } from './path.ts';
import type { Path } from './types.ts';

/** Read-only helpers for tracking changes in a form draft. */
export class Draft {
  readonly initial: unknown;
  readonly current: unknown;

  constructor(initial: unknown, current: unknown) {
    this.initial = initial;
    this.current = current;
  }

  value(path: Path): unknown {
    return getAt(this.current, path);
  }

  changed(path: Path): boolean {
    return !Object.is(getAt(this.initial, path), this.value(path));
  }

  changedPaths(paths: readonly Path[]): Path[] {
    return paths.filter(path => this.changed(path));
  }
}
