// A pairing URL carries its credential in the fragment, never in HTTP logs.
// The native server exchanges it for an HttpOnly, same-site cookie.
(async () => {
  const originalHash = location.hash;
  const fragment = new URLSearchParams(originalHash.slice(1));
  const token = fragment.get('pair');
  if (token) {
    history.replaceState(null, '', location.pathname + location.search);
    const response = await fetch('/api/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token }) });
    if (!response.ok) return showPairing('That pairing link is invalid. Copy a new link from the Mac menu-bar panel.');
  }
  const response = await fetch('/api/info');
  if (response.status === 401) return showPairing();
  if (!response.ok) return showPairing('The server is unavailable. Check Simwisp on the Mac.');
  await import('./app.js');
})().catch(error => showPairing(error.message));

function showPairing(message = 'Open Simwisp on your Mac and use Copy link to pair this browser.') {
  const app = document.getElementById('app');
  app.replaceChildren();
  const section = document.createElement('section');
  section.className = 'pairing-screen';
  const heading = document.createElement('h1'); heading.textContent = 'Pair with Simwisp';
  const text = document.createElement('p'); text.textContent = message;
  const form = document.createElement('form');
  const input = document.createElement('input'); input.type = 'password'; input.placeholder = 'Pairing code from the Mac link'; input.autocomplete = 'off'; input.setAttribute('aria-label', 'Pairing code');
  const button = document.createElement('button'); button.type = 'submit'; button.textContent = 'Pair browser';
  const status = document.createElement('p'); status.setAttribute('role', 'status');
  form.append(input, button);
  form.onsubmit = async event => {
    event.preventDefault(); button.disabled = true;
    try {
      const value = input.value.trim(); const code = value.includes('#pair=') ? new URL(value).hash.slice(6) : value;
      const result = await fetch('/api/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: code }) });
      if (result.ok) location.reload(); else status.textContent = 'Invalid pairing code.';
    } catch { status.textContent = 'Cannot reach Simwisp.'; }
    button.disabled = false;
  };
  section.append(heading, text, form, status); app.append(section); input.focus();
}
