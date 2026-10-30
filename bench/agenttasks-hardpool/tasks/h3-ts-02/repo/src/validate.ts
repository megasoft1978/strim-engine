import type { Result, Schema } from './types.ts';
import { walk } from './walk.ts';

/** Validate one immutable input and return its independent result. */
export async function validate(schema: Schema, input: unknown): Promise<Result> {
  const issues = await walk(schema, input, input);
  return { valid: issues.length === 0, issues };
}

/** Return just the messages for an exact field path. */
export function messagesAt(result: Result, path: string): string[] {
  return result.issues.filter(issue => issue.path === path).map(issue => issue.message);
}
