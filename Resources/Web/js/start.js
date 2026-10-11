// A pairing URL carries its credential in the fragment, never in HTTP logs.
// The native server exchanges it for an HttpOnly, same-site cookie.
(async () => {
  const originalHash = location.hash;
  const fragment = new URLSearchParams(originalHash.slice(1));
  const token = fragment.get('pair');
  if (token) {
    history.replaceState(null, '', location.pathname + location.search);
    const response = await fetch('/api/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token }) });
    if (!response.ok) return showPairing(await pairingError(response));
  }
  const response = await fetch('/api/info');
  if (response.status === 401) return showPairing();
  if (!response.ok) return showPairing('The server is unavailable. Check Simwisp on the Mac.');
  await import('./app.js');
})().catch(error => showPairing(error.message));

async function pairingError(response) {
  if (response.status === 429) {
    const seconds = Number(response.headers.get('Retry-After'));
    const wait = Number.isFinite(seconds) && seconds > 0
      ? seconds < 60 ? `${Math.ceil(seconds)} seconds` : `${Math.ceil(seconds / 60)} minutes`
      : 'a little while';
    return `Too many pairing attempts. Try again in ${wait}.`;
  }
  if (response.status === 503) return 'TOTP is unavailable. Use a pairing link or check Simwisp on the Mac.';
  return 'Invalid pairing credential. Check the link or use a fresh authenticator code.';
}

async function showPairing(message = 'Use a link from the Mac, or an authenticator code if configured.') {
  const app = document.getElementById('app');
  app.replaceChildren();
  const section = document.createElement('section');
  section.className = 'pairing-screen';
  const heading = document.createElement('h1'); heading.textContent = 'Pair with Simwisp';
  const text = document.createElement('p'); text.textContent = message;
  const methods = document.createElement('div'); methods.className = 'pairing-methods'; methods.hidden = true;
  methods.setAttribute('role', 'group'); methods.setAttribute('aria-label', 'Pairing method');
  const form = document.createElement('form');
  const input = document.createElement('input'); input.required = true;
  const button = document.createElement('button'); button.type = 'submit'; button.textContent = 'Pair browser';
  const status = document.createElement('p'); status.setAttribute('role', 'status'); status.setAttribute('aria-live', 'polite');
  let mode = 'token', busy = false;
  const choices = [];
  function select(next) {
    mode = next; input.value = ''; status.textContent = '';
    input.type = mode === 'totp' ? 'text' : 'password';
    input.inputMode = mode === 'totp' ? 'numeric' : 'text';
    input.autocomplete = mode === 'totp' ? 'one-time-code' : 'off';
    input.placeholder = mode === 'totp' ? 'Six-digit authenticator code' : 'Paste pairing link or token';
    input.setAttribute('aria-label', mode === 'totp' ? 'Authenticator code' : 'Pairing link or token');
    if (mode === 'totp') { input.maxLength = 6; input.pattern = '[0-9]{6}'; }
    else { input.removeAttribute('maxlength'); input.removeAttribute('pattern'); }
    for (const choice of choices) choice.button.setAttribute('aria-pressed', String(choice.mode === mode));
    input.focus();
  }
  for (const [value, label] of [['token', 'Pairing link'], ['totp', 'Authenticator code']]) {
    const choice = document.createElement('button'); choice.type = 'button'; choice.textContent = label;
    choice.onclick = () => { if (!busy) select(value); };
    choices.push({ mode: value, button: choice }); methods.append(choice);
  }
  form.append(input, button);
  form.onsubmit = async event => {
    event.preventDefault(); if (busy) return;
    busy = true; button.disabled = true; input.disabled = true;
    for (const choice of choices) choice.button.disabled = true;
    try {
      const value = input.value.trim();
      const token = mode === 'token' && value.includes('#pair=')
        ? new URLSearchParams(new URL(value).hash.slice(1)).get('pair') : value;
      const payload = mode === 'totp' ? { totp: value } : { token };
      const result = await fetch('/api/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
      if (result.ok) { input.value = ''; location.reload(); return; }
      status.textContent = await pairingError(result);
      if (mode === 'totp') input.value = '';
    } catch { status.textContent = 'Cannot pair. Check the link and the connection to Simwisp.'; }
    finally {
      busy = false; button.disabled = false; input.disabled = false;
      for (const choice of choices) choice.button.disabled = false;
      input.focus();
    }
  };
  section.append(heading, text, methods, form, status); app.append(section); select('token');
  try {
    const options = await fetch('/api/pair/options');
    if (options.ok && (await options.json()).totp === true) methods.hidden = false;
  } catch { /* Link pairing still works if capability discovery is unavailable. */ }
}
