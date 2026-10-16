const MODES = { capture: ['auto', 'scrcpy', 'current', 'jpeg', 'raw'], input: ['auto', 'scrcpy', 'current'], scaling: ['1', '0.5', '0.25'] };
const PREFIX = 'simwisp.android-backends.v1:';
let openMenu = null;
const icon = content => `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${content}</svg>`;
export const backendIcon = icon('<path d="M4 7h4m4 0h8M4 17h8m4 0h4"/><circle cx="10" cy="7" r="2"/><circle cx="14" cy="17" r="2"/>');
export function backendChoice(value, physical = false) {
  if (physical) return { capture: 'jpeg', scaling: MODES.scaling.includes(value?.scaling) ? value.scaling : '1', input: 'scrcpy' };
  return { capture: MODES.capture.includes(value?.capture) ? value.capture : 'auto', input: MODES.input.includes(value?.input) ? value.input : 'auto' };
}
// Browser-local, stable AVD identity: neither credentials nor reusable ADB serials.
export class AndroidBackends {
  #trigger; #menu; #choice; #key; #change; #physical; #modes; #listeners = []; #disposed = false;
  #state = { effective_capture: 'starting', effective_input: 'starting', available: false, reason: null };
  constructor(trigger, name, avd, change, { physical = false } = {}) {
    this.#physical = physical; this.#modes = physical ? { capture: ['jpeg'], scaling: MODES.scaling, input: ['scrcpy'] } : { capture: MODES.capture, input: MODES.input };
    this.#trigger = trigger; this.#change = change;
    this.#key = PREFIX + encodeURIComponent(String(avd || name).slice(0, 256));
    try { this.#choice = backendChoice(JSON.parse(localStorage.getItem(this.#key)), physical); } catch { this.#choice = backendChoice(null, physical); }
    const menu = document.createElement('section'); this.#menu = menu;
    menu.className = 'backend-popover'; menu.hidden = true; menu.setAttribute('role', 'dialog'); menu.setAttribute('aria-label', 'Android backends');
    menu.id = `android-backends-${++AndroidBackends.nextID}`;
    trigger.setAttribute('aria-controls', menu.id); trigger.setAttribute('aria-haspopup', 'dialog'); trigger.setAttribute('aria-expanded', 'false');
    const field = (kind, title, symbol, labels) => `<section class="backend-field"><div class="backend-field-heading"><span class="backend-field-label">${symbol}${title}</span><span class="backend-effective" data-effective="${kind}" aria-live="polite"></span></div><div class="backend-options${kind === 'capture' ? ' backend-capture-options' : ''}" role="radiogroup" aria-label="${title} backend">${this.#modes[kind].map(mode => `<button type="button" role="radio" aria-checked="false" tabindex="-1" data-kind="${kind}" data-choice="${mode}">${labels[MODES[kind].indexOf(mode)]}</button>`).join('')}</div></section>`;
    menu.innerHTML = `<header class="backend-header"><div><h2>Android backends</h2><p class="backend-device"></p></div><button class="backend-close" type="button" aria-label="Close Android backends">${icon('<path d="m7 7 10 10M17 7 7 17"/>')}</button></header><div class="backend-availability"><span class="availability-dot"></span><span class="backend-availability-text"></span><span class="availability-caption">On this Mac</span></div><div class="backend-warning" role="status" hidden></div>${field('capture', 'Capture', icon('<rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8m-4-4v4"/>'), ['Auto', 'scrcpy', 'Mac window', 'JPEG', 'Raw'])}${physical ? field('scaling', 'Scaling', icon('<rect x="4" y="4" width="16" height="16" rx="2"/><path d="M10 4v6H4m16 4h-6v6"/>'), ['x1', 'x0.5', 'x0.25']) : ''}${field('input', 'Input', icon('<path d="m6 3 12 10-6 1-3 6-3-17Z"/>'), ['Auto', 'scrcpy', 'Current'])}<p class="backend-explainer">Auto prefers scrcpy and falls back to the current method. JPEG and experimental Raw are manual-only. Raw uses the authenticated emulator-host RGBA API → Mac H.264, without JPEG.</p><footer class="backend-footer">${icon('<rect x="6" y="2" width="12" height="20" rx="3"/><path d="M10 18h4"/>')}<span>Only affects this emulator</span></footer>`;
    if (physical) {
      menu.querySelector('.backend-explainer').textContent = 'Physical Android devices use JPEG70 → Mac H.264 and scrcpy control-only input. Requires Android14+ and an already authorized USB or Wi-Fi ADB connection. Scaling resizes on Android before JPEG encoding and transmission; touch still uses the full display. Rotate the phone itself.';
      menu.querySelector('.backend-footer span').textContent = 'Only affects this device';
    }
    menu.querySelector('.backend-device').textContent = name;
    document.body.append(menu);
    const listen = (node, type, handler, options) => { node.addEventListener(type, handler, options); this.#listeners.push(() => node.removeEventListener(type, handler, options)); };
    listen(trigger, 'click', () => this.open(menu.hidden, true));
    listen(menu.querySelector('.backend-close'), 'click', () => this.open(false, true));
    listen(menu, 'click', e => { const b = e.target.closest('[data-choice]'); if (!b || !menu.contains(b)) return; this.#select(b.dataset.kind, b.dataset.choice); });
    listen(menu, 'keydown', e => {
      const b = e.target.closest('[data-choice]'); if (!b || !['ArrowLeft','ArrowRight','Home','End'].includes(e.key)) return;
      e.preventDefault(); const buttons = [...menu.querySelectorAll(`[data-kind="${b.dataset.kind}"]`)]; const i = buttons.indexOf(b);
      const count = buttons.length, next = e.key === 'Home' ? 0 : e.key === 'End' ? count - 1 : (i + (e.key === 'ArrowRight' ? 1 : count - 1)) % count;
      buttons[next].click(); buttons[next].focus({ preventScroll: true });
    });
    listen(document, 'keydown', e => { if (e.key === 'Escape' && !menu.hidden) { e.preventDefault(); this.open(false, true); } });
    listen(document, 'pointerdown', e => { if (!menu.hidden && !menu.contains(e.target) && !trigger.contains(e.target)) this.open(false); });
    listen(document, 'focusin', e => { if (!menu.hidden && !menu.contains(e.target) && !trigger.contains(e.target)) this.open(false); });
    listen(window, 'resize', () => this.#position()); listen(window, 'scroll', () => this.#position(), true);
    listen(window, 'pagehide', () => this.open(false));
    if (window.visualViewport) { listen(visualViewport, 'resize', () => this.#position()); listen(visualViewport, 'scroll', () => this.#position()); }
    this.#render();
  }
  static nextID = 0;
  get choices() { return { ...this.#choice }; }
  #select(kind, mode) {
    if (this.#disposed || !this.#modes[kind]?.includes(mode) || this.#choice[kind] === mode) return;
    this.#choice[kind] = mode;
    try { localStorage.setItem(this.#key, JSON.stringify(this.#choice)); } catch { /* Private browsing/full storage: still switch this session. */ }
    this.#state = { effective_capture: 'starting', effective_input: 'starting', available: false, reason: null };
    this.#render(); this.#change(this.choices);
  }
  receive(value) {
    if (this.#disposed || value?.type !== 'android_backends') return;
    // Stale configuration messages must not undo a just-selected preference.
    if (value.capture !== this.#choice.capture || value.input !== this.#choice.input) return;
    if (this.#physical && (value.jpeg_scale ?? '1') !== this.#choice.scaling) return;
    const allowed = ['starting','current','scrcpy','unavailable'];
    if (![...allowed,'jpeg','raw'].includes(value.effective_capture) || !allowed.includes(value.effective_input)) return;
    this.#state = { raw_available: typeof value.raw_available === 'boolean' ? value.raw_available : null, jpeg_available: typeof value.jpeg_available === 'boolean' ? value.jpeg_available : null, effective_capture: value.effective_capture, effective_input: value.effective_input, available: typeof value.available === 'boolean' ? value.available : null, reason: typeof value.reason === 'string' ? value.reason.slice(0, 1000) : null };
    this.#render();
  }
  #render() {
    const m = this.#menu, s = this.#state, starting = [s.effective_capture,s.effective_input].includes('starting');
    const jpeg = this.#choice.capture === 'jpeg', raw = this.#choice.capture === 'raw', available = raw ? s.raw_available : jpeg ? s.jpeg_available : s.available;
    m.classList.toggle('unavailable', available === false && !starting);
    m.querySelector('.backend-availability-text').textContent = raw ? available === true ? 'Emulator Raw available (experimental)' : available === false ? 'Emulator Raw unavailable' : 'Checking emulator Raw…' : jpeg ? available === true ? 'Emulator JPEG available' : available === false ? 'Emulator JPEG unavailable' : 'Checking emulator JPEG…' : starting ? 'Checking scrcpy…' : s.available === null ? 'Checking installation…' : s.available ? 'scrcpy available' : 'scrcpy unavailable';
    if (this.#physical && jpeg) m.querySelector('.backend-availability-text').textContent = available === true ? 'Android JPEG available' : available === false ? 'Android JPEG unavailable' : 'Checking Android JPEG…';
    for (const kind of Object.keys(this.#modes)) {
      if (kind === 'scaling') {
        m.querySelector('[data-effective="scaling"]').textContent = 'Before JPEG';
        for (const b of m.querySelectorAll('[data-kind="scaling"]')) {
          const selected = b.dataset.choice === this.#choice.scaling;
          b.setAttribute('aria-checked', String(selected)); b.tabIndex = selected ? 0 : -1;
          b.title = 'Resize both dimensions on Android by x' + b.dataset.choice + ' before JPEG encoding and transmission; input uses full display coordinates';
        }
        continue;
      }
      const value = s[`effective_${kind}`], badge = m.querySelector(`[data-effective="${kind}"]`);
      badge.textContent = value === 'raw' ? 'Using raw RGBA → H.264' : value === 'jpeg' ? 'Using JPEG70 → H.264' : value === 'scrcpy' ? 'Using scrcpy' : value === 'current' ? kind === 'capture' ? 'Using Mac window' : 'Using current' : value === 'unavailable' ? 'Unavailable' : 'Starting…';
      badge.className = 'backend-effective' + (value === 'current' || value === 'starting' ? ' current' : value === 'unavailable' ? ' error' : '');
      for (const b of m.querySelectorAll(`[data-kind="${kind}"]`)) {
        const selected = b.dataset.choice === this.#choice[kind]; b.setAttribute('aria-checked', String(selected)); b.tabIndex = selected ? 0 : -1;
        b.title = this.#physical ? kind === 'capture' ? 'Android JPEG quality70 → Mac H.264; Android14+ required' : 'Persistent scrcpy input only; no Android video encoder or shaping changes' : b.dataset.choice === 'raw' ? 'Experimental emulator-only authenticated RGBA stream; no JPEG. Local raw traffic may be large; CPU savings are not guaranteed' : b.dataset.choice === 'jpeg' ? 'Manual-only Android emulator JPEG quality70, decoded and encoded with Mac VideoToolbox; Android14+ required' : b.dataset.choice === 'current' ? kind === 'capture' ? 'ScreenCaptureKit window capture' : 'Mac mouse events + existing ADB commands' : b.dataset.choice === 'auto' ? 'Prefer compatible scrcpy; otherwise use the current method' : 'Always use scrcpy; report errors instead of falling back';
      }
    }
    const warning = m.querySelector('.backend-warning'); warning.hidden = !s.reason; warning.textContent = s.reason || '';
    this.#trigger.title = `Android backends — capture: ${s.effective_capture}, input: ${s.effective_input}`;
    this.#position();
  }
  open(value, focus = false) {
    if (this.#disposed) return;
    if (value && openMenu && openMenu !== this) openMenu.open(false);
    this.#menu.hidden = !value; this.#trigger.setAttribute('aria-expanded', String(value));
    if (value) { openMenu = this; this.#position(); if (focus) this.#menu.querySelector('[data-kind="capture"][aria-checked="true"]').focus({ preventScroll: true }); }
    else { if (openMenu === this) openMenu = null; if (focus && this.#trigger.isConnected) this.#trigger.focus({ preventScroll: true }); }
  }
  #position() {
    const m = this.#menu; if (m.hidden || this.#disposed) return;
    const viewport = window.visualViewport, left = viewport?.offsetLeft || 0, top = viewport?.offsetTop || 0;
    const width = viewport?.width || innerWidth, height = viewport?.height || innerHeight, t = this.#trigger.getBoundingClientRect(), w = Math.min(356, width - 24);
    m.style.width = w + 'px'; m.style.left = Math.max(left + 12, Math.min(t.left, left + width - w - 12)) + 'px';
    const above = t.top - top - 20, below = top + height - t.bottom - 20;
    const useAbove = above >= Math.min(m.scrollHeight, 330) || above >= below;
    m.style.maxHeight = Math.max(100, useAbove ? above : below) + 'px';
    const h = m.getBoundingClientRect().height;
    m.style.top = Math.max(top + 12, Math.min(useAbove ? t.top - h - 10 : t.bottom + 10, top + height - h - 12)) + 'px';
  }
  destroy() {
    if (this.#disposed) return; this.open(false); this.#disposed = true;
    this.#listeners.splice(0).forEach(remove => remove()); this.#menu.remove();
  }
}
