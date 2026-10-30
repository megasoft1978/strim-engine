import type { Context, Issue, Path, Schema } from './types.ts';
import { childPath, formatPath } from './path.ts';

/** Walk in schema order so results are stable regardless of rule latency. */
export async function walk(schema: Schema, value: unknown, root: unknown, path: Path = []): Promise<Issue[]> {
  const context: Context = { root, path };
  const messages = await Promise.all(schema.rules.map(async rule => {
    const message = await rule.check(value, context);
    return message === null ? null : { path: formatPath(path), code: rule.code, message };
  }));
  const issues: Issue[] = messages.filter((message): message is Issue => message !== null);

  if (schema.fields && value !== null && typeof value === 'object' && !Array.isArray(value)) {
    const record = value as Record<string, unknown>;
    const children = await Promise.all(Object.entries(schema.fields).map(([key, child]) =>
      walk(child, record[key], root, childPath(path, key))));
    for (const child of children) issues.push(...child);
  }
  if (schema.items && Array.isArray(value)) {
    const itemSchema = schema.items;
    const children = await Promise.all(value.map((item, index) =>
      walk(itemSchema, item, root, childPath(path, index))));
    for (const child of children) issues.push(...child);
  }
  return issues;
}
