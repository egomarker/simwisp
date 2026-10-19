const TIMEOUT = 8000;

async function _fetch(path, options = {}, timeout = TIMEOUT) {
  const abort = new AbortController();
  const t = setTimeout(() => abort.abort(), timeout);
  try {
    const r = await fetch(path, { signal: abort.signal, ...options });
    const data = await r.json();
    if (!r.ok) throw new Error(data.error || `Request failed (${r.status})`);
    return data;
  } finally {
    clearTimeout(t);
  }
}

export async function fetchInfo() {
  return _fetch('/api/info').catch(() => ({}));
}

export async function fetchSims() {
  return _fetch('/api/sims');
}

export async function fetchAvailableDevices() {
  return _fetch('/api/devices').catch(() => []);
}

export async function bootSim(udid, mode = 'windowed') {
  return _fetch(`/api/boot/${encodeURIComponent(udid)}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ mode }),
  }, 70_000);
}

export async function bootAvd(avd, mode = 'windowed') {
  return _fetch('/api/boot-avd', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ avd, mode }),
  }, 70_000);
}

export async function stopSim(id) {
  // Shutdown + capture teardown may take longer than a discovery request.
  return _fetch(`/api/stop/${encodeURIComponent(id)}`, { method: 'POST' }, 60_000);
}

export async function fetchStopStatus(id) {
  return _fetch(`/api/stop-status/${encodeURIComponent(id)}`);
}

export async function requestPermission(permission) {
  return _fetch('/api/request-permissions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ permission }),
  });
}
