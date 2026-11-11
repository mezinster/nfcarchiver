/** Hidden developer switches, persisted in localStorage. Every storage access
 *  is guarded: private windows and blocked site data make it throw, and a
 *  developer flag must then simply read as off. */
const UNLOCKED_KEY = 'nfar-dev-unlocked';
const MIFARE4K_KEY = 'nfar-dev-mifare4k';

function read(key: string): boolean {
  try {
    return localStorage.getItem(key) === '1';
  } catch {
    return false;
  }
}

function write(key: string, on: boolean): void {
  try {
    if (on) localStorage.setItem(key, '1');
    else localStorage.removeItem(key);
  } catch {
    /* storage unavailable: the flag stays off */
  }
}

export const isDevUnlocked = (): boolean => read(UNLOCKED_KEY);
export const unlockDev = (): void => write(UNLOCKED_KEY, true);
export const isMifare4kEnabled = (): boolean => read(MIFARE4K_KEY);

const listeners = new Set<(on: boolean) => void>();

export function setMifare4kEnabled(on: boolean): void {
  write(MIFARE4K_KEY, on);
  for (const cb of [...listeners]) cb(on);
}

/** Subscribe to switch changes; returns the unsubscribe function. */
export function onMifare4kChange(cb: (on: boolean) => void): () => void {
  listeners.add(cb);
  return () => { listeners.delete(cb); };
}
