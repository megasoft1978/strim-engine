import type { Listener, Result, Schema } from './types.ts';
import { validate } from './validate.ts';

/** Holds the most recent result for a form and notifies its subscribers. */
export class FormSession {
  private listeners = new Set<Listener>();
  private latest: Result | null = null;

  private readonly schema: Schema;

  constructor(schema: Schema) { this.schema = schema; }

  get current(): Result | null {
    return this.latest;
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  async check(input: unknown): Promise<Result> {
    const result = await validate(this.schema, input);
    this.latest = result;
    for (const listener of this.listeners) listener(result);
    return result;
  }
}
