// One page-level metadata scheduler. No log socket or renderer is loaded here.
export class MetroDiscovery {
  enabled = false; active = new Set(); snapshot = { generation: 0, targets: [] };
  #timer; #abort; #flight; #pending = false; #last = -Infinity; #closed = false; #epoch = 0;
  constructor(onSnapshot, { fetcher = (...args) => fetch(...args), now = () => performance.now(), schedule = (fn, ms) => setTimeout(fn, ms), cancel = id => clearTimeout(id) } = {}) {
    this.onSnapshot = onSnapshot; this.fetcher = fetcher; this.now = now; this.schedule = schedule; this.cancel = cancel;
  }
  capability(value) {
    this.enabled = value === true;
    if (!this.enabled) { this.#epoch++; this.#abort?.abort(); this.cancel(this.#timer); this.snapshot = { generation: 0, targets: [] }; this.onSnapshot(this.snapshot); }
    else if (this.active.size) this.refresh();
  }
  setActive(id, active) {
    const had = this.active.has(id);
    if (active) this.active.add(id); else this.active.delete(id);
    if (!this.active.size) { this.cancel(this.#timer); this.#pending = false; this.#epoch++; this.#abort?.abort(); }
    else if (active && !had) this.refresh();
  }
  candidates(id) { return this.snapshot.targets.filter(t => t.candidate_device_ids?.includes(id)); }
  refresh(user = false) {
    if (this.#closed || !this.enabled || (!this.active.size && !user)) return Promise.resolve(this.snapshot);
    if (this.#flight) { this.#pending = true; return this.#flight; }
    this.cancel(this.#timer);
    const delay = user ? 0 : Math.max(0, 5000 - (this.now() - this.#last));
    if (delay) { this.#timer = this.schedule(() => this.refresh(), delay); return Promise.resolve(this.snapshot); }
    const epoch = this.#epoch; this.#last = this.now(); this.#pending = false;
    const abort = new AbortController(); this.#abort = abort;
    const deadline = this.schedule(() => abort.abort(), 6000);
    this.#flight = this.fetcher('/api/metro/targets', { signal: abort.signal, cache: 'no-store' }).then(async r => {
      if (!r.ok) throw Error('Metro discovery unavailable');
      const data = await r.json();
      if (!Number.isSafeInteger(data.generation) || !Array.isArray(data.targets) || data.targets.length > 64 || data.targets.some(t => typeof t.key !== 'string' || t.key.length > 256 || !Array.isArray(t.candidate_device_ids))) throw Error('Invalid Metro discovery');
      if (this.#closed || !this.enabled || epoch !== this.#epoch) return;
      this.snapshot = data; this.onSnapshot(data);
    }).catch(() => { /* failed scans preserve the last successful button snapshot */ }).finally(() => {
      this.cancel(deadline); this.#flight = null; this.#abort = null;
      if (!this.#closed && this.enabled && this.active.size) this.#timer = this.schedule(() => this.refresh(), this.#pending ? Math.max(0, 5000 - (this.now() - this.#last)) : 30000);
    });
    return this.#flight;
  }
  destroy() { this.#closed = true; this.#epoch++; this.#abort?.abort(); this.cancel(this.#timer); this.active.clear(); }
}

export function consoleIdentity(deviceId, target) {
  return JSON.stringify([deviceId, target.endpoint || '127.0.0.1:8081', target.app_id || ('target:' + target.target_id)]);
}
export function resolveConsole(binding, targets, deviceId) {
  const matches = targets.filter(t => t.candidate_device_ids?.includes(deviceId) && t.endpoint === binding.endpoint &&
    (binding.app_id ? t.app_id === binding.app_id : t.target_id === binding.target_id));
  // Never switch between same-app runtimes without an explicit picker binding.
  return matches.length === 1 ? matches[0] : matches.find(t => t.key === binding.key || t.target_id === binding.target_id) || null;
}
