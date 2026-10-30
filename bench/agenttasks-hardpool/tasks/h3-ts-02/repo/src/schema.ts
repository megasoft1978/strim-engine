import type { NamedRule, Rule, Schema } from './types.ts';

/** Attach an identifying code to a reusable rule. */
export function named(code: string, check: Rule): NamedRule {
  if (!code) throw new Error('rule code must not be empty');
  return { code, check };
}

/** Validate a scalar or an entire container. */
export function value(...rules: NamedRule[]): Schema {
  return { rules };
}

/** Child fields are visited in insertion order. */
export function object(fields: Record<string, Schema>, ...rules: NamedRule[]): Schema {
  return { rules, fields };
}

/** Each array element receives the same item schema. */
export function array(items: Schema, ...rules: NamedRule[]): Schema {
  return { rules, items };
}

/** Add rules while preserving the existing schema's children. */
export function withRules(schema: Schema, ...rules: NamedRule[]): Schema {
  return { ...schema, rules: [...schema.rules, ...rules] };
}
