import type { Issue } from './types.ts';

/** Optional message overrides, keyed by rule code. */
export class MessageCatalog {
  private entries = new Map<string, string>();

  constructor(entries: Record<string, string> = {}) {
    for (const [code, text] of Object.entries(entries)) this.entries.set(code, text);
  }

  set(code: string, text: string): void {
    this.entries.set(code, text);
  }

  apply(issue: Issue): Issue {
    return { ...issue, message: this.entries.get(issue.code) ?? issue.message };
  }

  applyAll(issues: readonly Issue[]): Issue[] {
    return issues.map(issue => this.apply(issue));
  }
}
