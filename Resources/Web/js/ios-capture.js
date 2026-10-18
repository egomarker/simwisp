// Separate namespace and closed two-choice policy: never changes Android Auto.
const PREFIX = 'simwisp.ios-capture.v1:', SCALE_PREFIX = 'simwisp.ios-scaling.v1:';
const SCALES = ['1', '0.5', '0.25'];
let openMenu = null, nextID = 0;
export class IOSCapture {
  #trigger; #menu; #choice = 'current'; #scaling = '1'; #key; #scaleKey; #change; #listeners = []; #disposed = false;
  constructor(trigger, name, udid, change) {
    this.#trigger = trigger; this.#change = change; this.#key = PREFIX + encodeURIComponent(udid);
    this.#scaleKey = SCALE_PREFIX + encodeURIComponent(udid);
    try { if (localStorage.getItem(this.#key) === 'native') this.#choice = 'native'; const scale = localStorage.getItem(this.#scaleKey); if (SCALES.includes(scale)) this.#scaling = scale; } catch {}
    const m = document.createElement('section'); this.#menu = m;
    m.className = 'backend-popover ios-capture-popover'; m.hidden = true; m.id = 'ios-capture-' + ++nextID;
    m.setAttribute('role', 'dialog'); m.setAttribute('aria-label', 'iOS backends');
    m.innerHTML = `<header class="backend-header"><div><h2>iOS backends</h2><p class="backend-device"></p></div><button class="backend-close" type="button" aria-label="Close iOS backends">×</button></header><div class="backend-availability"><span class="backend-effective" data-effective="capture" aria-live="polite">Starting…</span></div><div class="backend-warning" role="status" hidden></div><section class="backend-field"><div class="backend-options" role="radiogroup" aria-label="Capture backend"><button type="button" role="radio" data-kind="capture" data-choice="current">Mac window</button><button type="button" role="radio" data-kind="capture" data-choice="native">Native</button></div></section><section class="backend-field" data-scaling hidden><div class="backend-field-heading"><span class="backend-field-label">Scaling</span><span class="backend-effective" data-effective="scaling">Before H.264</span></div><div class="backend-options" role="radiogroup" aria-label="Scaling backend">${SCALES.map(scale => `<button type="button" role="radio" data-kind="scaling" data-choice="${scale}">x${scale}</button>`).join('')}</div></section><footer class="backend-footer">Only affects this simulator</footer>`;
    m.querySelector('.backend-device').textContent = name;
    document.body.append(m);
    trigger.setAttribute('aria-controls', m.id); trigger.setAttribute('aria-haspopup', 'dialog'); trigger.setAttribute('aria-expanded', 'false');
    const listen = (n, t, f, o) => { n.addEventListener(t, f, o); this.#listeners.push(() => n.removeEventListener(t, f, o)); };
    listen(trigger, 'click', () => this.open(m.hidden, true));
    listen(m.querySelector('.backend-close'), 'click', () => this.open(false, true));
    listen(m, 'click', e => {
      const b = e.target.closest('[data-choice]'); if (!b || !m.contains(b)) return;
      if (b.dataset.kind === 'scaling') {
        if (this.#choice !== 'native' || !SCALES.includes(b.dataset.choice) || this.#scaling === b.dataset.choice) return;
        this.#scaling = b.dataset.choice;
        try { localStorage.setItem(this.#scaleKey, this.#scaling); } catch {}
      } else {
        if (!['current', 'native'].includes(b.dataset.choice) || this.#choice === b.dataset.choice) return;
        this.#choice = b.dataset.choice;
        try { localStorage.setItem(this.#key, this.#choice); } catch {}
      }
      this.#render(); m.querySelector('[data-effective]').textContent = 'Starting…';
      m.querySelector('.backend-warning').hidden = true;
      this.#change(this.choices);
    });
    listen(m, 'keydown', e => {
      const b = e.target.closest('[data-choice]'); if (!b || !['ArrowLeft','ArrowRight','Home','End'].includes(e.key)) return;
      e.preventDefault(); const buttons = [...m.querySelectorAll('[data-kind="' + b.dataset.kind + '"]')], i = buttons.indexOf(b);
      const count = buttons.length, next = e.key === 'Home' ? 0 : e.key === 'End' ? count - 1 : (i + (e.key === 'ArrowRight' ? 1 : count - 1)) % count;
      buttons[next].click(); buttons[next].focus({ preventScroll: true });
    });
    listen(document, 'keydown', e => { if (e.key === 'Escape' && !m.hidden) { e.preventDefault(); this.open(false, true); } });
    for (const type of ['pointerdown','focusin']) listen(document, type, e => { if (!m.hidden && !m.contains(e.target) && !trigger.contains(e.target)) this.open(false); });
    listen(window, 'resize', () => this.#position()); listen(window, 'scroll', () => this.#position(), true); listen(window, 'pagehide', () => this.open(false));
    if (window.visualViewport) { listen(visualViewport, 'resize', () => this.#position()); listen(visualViewport, 'scroll', () => this.#position()); }
    this.#render();
  }
  get choices() { return { capture: this.#choice, input: 'current', nativeScaling: this.#choice === 'native' ? this.#scaling : '1' }; }
  #render() {
    const field = this.#menu.querySelector('[data-scaling]'); field.hidden = this.#choice !== 'native'; field.style.display = field.hidden ? 'none' : '';
    for (const b of this.#menu.querySelectorAll('[data-choice]')) {
      const scaling = b.dataset.kind === 'scaling', on = b.dataset.choice === (scaling ? this.#scaling : this.#choice);
      b.setAttribute('aria-checked', String(on)); b.tabIndex = on ? 0 : -1;
      if (scaling) b.title = 'Resize both dimensions by x' + b.dataset.choice + ' before H.264; touch maps to the full display';
    }
    this.#position();
  }
  receive(value) {
    if (this.#disposed || value?.type !== 'ios_capture' || value.capture !== this.#choice || (value.native_scale ?? '1') !== this.choices.nativeScaling || !['starting','native','current','unavailable'].includes(value.effective_capture)) return;
    this.#menu.querySelector('[data-effective]').textContent = value.effective_capture === 'native' ? 'Using Native → H.264' : value.effective_capture === 'current' ? 'Using Mac window' : value.effective_capture === 'unavailable' ? 'Unavailable' : 'Starting…';
    const warning = this.#menu.querySelector('.backend-warning'); warning.hidden = !value.reason; warning.textContent = typeof value.reason === 'string' ? value.reason.slice(0, 1000) : '';
    this.#trigger.title = 'iOS backends — ' + value.effective_capture; this.#position();
  }
  open(value, focus = false) {
    if (this.#disposed) return;
    if (value && openMenu && openMenu !== this) openMenu.open(false);
    this.#menu.hidden = !value; this.#trigger.setAttribute('aria-expanded', String(value));
    if (value) { openMenu = this; this.#position(); if (focus) this.#menu.querySelector('[aria-checked=true]').focus({ preventScroll: true }); }
    else { if (openMenu === this) openMenu = null; if (focus && this.#trigger.isConnected) this.#trigger.focus({ preventScroll: true }); }
  }
  #position() {
    if (this.#disposed || this.#menu.hidden) return;
    const m = this.#menu, v = window.visualViewport, left = v?.offsetLeft || 0, top = v?.offsetTop || 0, w = v?.width || innerWidth, h = v?.height || innerHeight, t = this.#trigger.getBoundingClientRect();
    m.style.width = Math.min(356, w - 24) + 'px'; m.style.left = Math.max(left + 12, Math.min(t.left, left + w - m.getBoundingClientRect().width - 12)) + 'px';
    const above = t.top - top - 20, below = top + h - t.bottom - 20, useAbove = above >= below;
    m.style.maxHeight = Math.max(100, useAbove ? above : below) + 'px';
    m.style.top = Math.max(top + 12, Math.min(useAbove ? t.top - m.getBoundingClientRect().height - 10 : t.bottom + 10, top + h - m.getBoundingClientRect().height - 12)) + 'px';
  }
  destroy() { if (this.#disposed) return; this.open(false); this.#disposed = true; this.#listeners.splice(0).forEach(f => f()); this.#menu.remove(); }
}
