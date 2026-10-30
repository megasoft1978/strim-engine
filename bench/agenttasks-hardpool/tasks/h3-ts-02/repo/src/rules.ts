import { named } from './schema.ts';
import type { NamedRule } from './types.ts';

export function required(message = 'Required'): NamedRule {
  return named('required', value =>
    value === undefined || value === null || value === '' ? message : null);
}

export function minLength(minimum: number, message = `Use at least ${minimum} characters`): NamedRule {
  if (!Number.isInteger(minimum) || minimum < 0) throw new Error('invalid minimum');
  return named('minLength', value =>
    typeof value === 'string' && value.length < minimum ? message : null);
}

export function maxLength(maximum: number, message = `Use at most ${maximum} characters`): NamedRule {
  if (!Number.isInteger(maximum) || maximum < 0) throw new Error('invalid maximum');
  return named('maxLength', value =>
    typeof value === 'string' && value.length > maximum ? message : null);
}

export function pattern(expression: RegExp, message = 'Invalid format'): NamedRule {
  return named('pattern', value => {
    if (typeof value !== 'string' || value === '') return null;
    expression.lastIndex = 0;
    return expression.test(value) ? null : message;
  });
}

export function integer(message = 'Enter an integer'): NamedRule {
  return named('integer', value =>
    value === undefined || value === null || Number.isInteger(value) ? null : message);
}

export function minimum(minimumValue: number, message = `Must be at least ${minimumValue}`): NamedRule {
  return named('minimum', value =>
    typeof value === 'number' && value < minimumValue ? message : null);
}
