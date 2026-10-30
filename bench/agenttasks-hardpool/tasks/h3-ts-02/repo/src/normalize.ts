/** Helpers for preparing form input before validation. */
export function trimText(value: unknown): unknown {
  return typeof value === 'string' ? value.trim() : value;
}

export function emptyToUndefined(value: unknown): unknown {
  return value === '' ? undefined : value;
}

export function parseInteger(value: unknown): unknown {
  if (typeof value !== 'string' || !/^-?\d+$/.test(value)) return value;
  const number = Number(value);
  return Number.isSafeInteger(number) ? number : value;
}

export function normalizeRecord(
  input: Record<string, unknown>,
  transforms: Record<string, (value: unknown) => unknown>,
): Record<string, unknown> {
  const output = { ...input };
  for (const [key, transform] of Object.entries(transforms)) {
    if (Object.hasOwn(input, key)) output[key] = transform(input[key]);
  }
  return output;
}
