/**
 * Dependency-free in-memory event log: a capped ring buffer plus pub/sub, used
 * by the Log tab. Web-platform globals only, so it runs under node --test.
 */

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export interface LogEntry {
  seq: number;      // monotonic counter (stable ordering)
  t: number;        // Date.now() epoch ms
  level: LogLevel;
  cat: string;      // category, e.g. 'restore', 'scan', 'device'
  msg: string;
  data?: unknown;   // small structured context (never file contents or passwords)
}

export interface LoggerOptions { capacity?: number; mirrorToConsole?: boolean; }

export const LEVELS: Record<LogLevel, number> = { debug: 0, info: 1, warn: 2, error: 3 };

/** Stable one-line rendering: `hh:mm:ss.mmm LEVEL [cat] msg {data}` (UTC time). */
export function formatLogLine(e: LogEntry): string {
  const time = new Date(e.t).toISOString().slice(11, 23);
  const data = e.data === undefined ? '' : ` ${JSON.stringify(e.data)}`;
  return `${time} ${e.level.toUpperCase().padEnd(5)} [${e.cat}] ${e.msg}${data}`;
}

export class Logger {
  private readonly capacity: number;
  private mirror: boolean;
  private readonly buf: LogEntry[] = [];
  private readonly subs = new Set<(e: LogEntry) => void>();
  private seq = 0;

  constructor(opts?: LoggerOptions) {
    this.capacity = opts?.capacity ?? 1000;
    this.mirror = opts?.mirrorToConsole ?? false;
  }

  private emit(level: LogLevel, cat: string, msg: string, data?: unknown): void {
    const e: LogEntry = { seq: this.seq++, t: Date.now(), level, cat, msg, ...(data !== undefined ? { data } : {}) };
    this.buf.push(e);
    if (this.buf.length > this.capacity) this.buf.shift();
    if (this.mirror) { try { console[level](formatLogLine(e)); } catch { /* ignore console failures */ } }
    for (const cb of this.subs) { try { cb(e); } catch { /* a broken subscriber must not break logging */ } }
  }

  debug(cat: string, msg: string, data?: unknown): void { this.emit('debug', cat, msg, data); }
  info(cat: string, msg: string, data?: unknown): void { this.emit('info', cat, msg, data); }
  warn(cat: string, msg: string, data?: unknown): void { this.emit('warn', cat, msg, data); }
  error(cat: string, msg: string, data?: unknown): void { this.emit('error', cat, msg, data); }

  subscribe(cb: (e: LogEntry) => void): () => void {
    this.subs.add(cb);
    return () => { this.subs.delete(cb); };
  }
  snapshot(): LogEntry[] { return [...this.buf]; }
  clear(): void { this.buf.length = 0; }
  setMirrorToConsole(on: boolean): void { this.mirror = on; }
}

export const log = new Logger();
