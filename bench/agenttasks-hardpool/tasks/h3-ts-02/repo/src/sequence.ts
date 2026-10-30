/** Identifies requests issued by one form session. */
export class RequestSequence {
  private current = 0;

  begin(): number {
    return ++this.current;
  }

  isCurrent(request: number): boolean {
    return request <= this.current;
  }
}
