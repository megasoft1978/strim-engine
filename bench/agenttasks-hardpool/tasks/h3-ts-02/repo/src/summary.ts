import type { Issue, Result } from './types.ts';

/** Group issues by display path, preserving their original order. */
export function groupIssues(issues: readonly Issue[]): Map<string, Issue[]> {
  const groups = new Map<string, Issue[]>();
  for (const issue of issues) {
    const group = groups.get(issue.path);
    if (group) group.push(issue);
    else groups.set(issue.path, [issue]);
  }
  return groups;
}

/** Produce a compact, accessible text summary for a result. */
export function summarize(result: Result): string {
  if (result.valid) return 'No issues';
  return result.issues.map(issue =>
    issue.path ? `${issue.path}: ${issue.message}` : issue.message).join('\n');
}

export function countFields(result: Result): number {
  return groupIssues(result.issues).size;
}
