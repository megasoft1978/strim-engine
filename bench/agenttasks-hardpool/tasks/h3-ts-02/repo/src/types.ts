/** A path is kept as segments until an issue is ready for display. */
export type Segment = string | number;
export type Path = readonly Segment[];

export interface Issue {
  path: string;
  code: string;
  message: string;
}

export interface Context {
  readonly path: Path;
  readonly root: unknown;
}

export type Rule = (value: unknown, context: Context) =>
  string | null | Promise<string | null>;

export interface NamedRule {
  code: string;
  check: Rule;
}

export interface Schema {
  rules: readonly NamedRule[];
  fields?: Readonly<Record<string, Schema>>;
  items?: Schema;
}

export interface Result {
  valid: boolean;
  issues: Issue[];
}

export type Listener = (result: Result) => void;
