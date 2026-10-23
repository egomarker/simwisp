let openMenu = null;
const icon = content => `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${content}</svg>`;
const fields = [
  ['talkback', 'TalkBack', icon('<circle cx="12" cy="12" r="9"/><circle cx="12" cy="7" r="1"/><path d="m7 10 5 1 5-1M12 11v4m0 0-3 3m3-3 3 3"/>')],
  ['text_size', '200% text size', '<span class="android-a11y-letter" aria-hidden="true">Aa</span>'],
  ['bold_font', 'Bold font', '<span class="android-a11y-letter android-a11y-bold" aria-hidden="true">B</span>'],
  ['high_contrast', 'High contrast', icon('<circle cx="12" cy="12" r="8.5"/><path d="M12 3.5a8.5 8.5 0 0 1 0 17Z" fill="currentColor" stroke="none"/>')],
];

// Construction/stream events never read device settings. Only open() does.
export class AndroidAccessibilityMenu {
  static nextID = 0;
  #trigger; #menu; #status; #settings; #content; #activity; #read; #write; #toggleInspector; #onError;
  #focusAfterBusy = null;
  #listeners = []; #disposed = false; #generation = 0; #loading = false; #writing = false; #values = {};
  constructor(trigger, { read, write, toggleInspector, onError = () => {} }) {
    this.#trigger = trigger; this.#read = read; this.#write = write;
    this.#toggleInspector = toggleInspector; this.#onError = onError;
    const menu = document.createElement('section'); this.#menu = menu;
    menu.className = 'android-accessibility-menu'; menu.hidden = true; menu.tabIndex = -1;
    menu.id = `android-accessibility-menu-${++AndroidAccessibilityMenu.nextID}`;
    menu.setAttribute('role', 'dialog'); menu.setAttribute('aria-label', 'Android accessibility');
    menu.innerHTML = `<header><h2>Accessibility</h2><span class="android-a11y-platform">Android</span></header><div class="android-a11y-settings" role="group" aria-label="Android accessibility settings"><div class="android-a11y-content">${fields.map(([key, label, symbol]) => `<button type="button" class="android-a11y-row" data-setting="${key}" role="switch" aria-checked="false" aria-label="${label}" disabled>${symbol}<span class="android-a11y-label">${label}</span><span class="android-a11y-switch" aria-hidden="true"></span></button>`).join('')}</div><div class="android-a11y-loading" role="status" aria-label="Loading accessibility settings" hidden><span class="spinner" aria-hidden="true"></span></div></div><div class="android-a11y-divider"></div><button type="button" class="android-a11y-row" data-action="show-inspector">${icon('<rect x="2.5" y="4.5" width="19" height="15" rx="2.5"/><path d="m7 9 3 3-3 3m6 0h4"/>')}<span class="android-a11y-label">Show TalkBack inspector</span>${icon('<path d="m9 6 6 6-6 6"/>')}</button><p class="android-a11y-request-status" role="status" aria-live="polite"></p>`;
    this.#settings = menu.querySelector('.android-a11y-settings');
    this.#content = menu.querySelector('.android-a11y-content');
    this.#activity = menu.querySelector('.android-a11y-loading');
    this.#status = menu.querySelector('.android-a11y-request-status');
    this.#status.id = menu.id + '-status'; menu.setAttribute('aria-describedby', this.#status.id);
    trigger.setAttribute('aria-controls', menu.id); trigger.setAttribute('aria-haspopup', 'dialog'); trigger.setAttribute('aria-expanded', 'false');
    document.body.append(menu);
    const listen = (node, type, handler, options) => { node.addEventListener(type, handler, options); this.#listeners.push(() => node.removeEventListener(type, handler, options)); };
    listen(trigger, 'click', e => this.open(menu.hidden, e.detail === 0));
    listen(menu, 'click', e => {
      const button = e.target.closest('button'); if (!button || button.disabled || !menu.contains(button)) return;
      if (button.dataset.setting) this.#toggle(button.dataset.setting);
      else if (button.dataset.action === 'show-inspector') {
        this.open(false, true);
        Promise.resolve().then(() => { if (!this.#disposed) return this.#toggleInspector(); }).catch(error => { if (!this.#disposed) this.#onError(error); });
      }
    });
    listen(menu, 'keydown', e => {
      if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(e.key)) return;
      const buttons = [...menu.querySelectorAll('button:not(:disabled)')]; if (!buttons.length) return;
      e.preventDefault(); const i = buttons.indexOf(document.activeElement), n = buttons.length;
      const next = e.key === 'Home' ? 0 : e.key === 'End' ? n - 1 : (i + (e.key === 'ArrowDown' ? 1 : n - 1)) % n;
      buttons[next].focus({ preventScroll: true });
    });
    listen(document, 'keydown', e => { if (e.key === 'Escape' && !menu.hidden) { e.preventDefault(); this.open(false, true); } });
    listen(document, 'pointerdown', e => { if (!menu.hidden && !menu.contains(e.target) && !trigger.contains(e.target)) this.open(false); });
    listen(document, 'focusin', e => { if (!menu.hidden && !menu.contains(e.target) && !trigger.contains(e.target)) this.open(false); });
    listen(document, 'visibilitychange', () => { if (document.hidden) this.open(false); });
    listen(window, 'pagehide', () => this.open(false));
    listen(window, 'resize', () => this.#position()); listen(window, 'scroll', () => this.#position(), true);
    if (window.visualViewport) { listen(window.visualViewport, 'resize', () => this.#position()); listen(window.visualViewport, 'scroll', () => this.#position()); }
    this.#render();
  }
  get inspectorButton() { return this.#menu.querySelector('[data-action="show-inspector"]'); }
  setInspectorOpen(value) {
    if (this.#disposed) return;
    this.inspectorButton.querySelector('.android-a11y-label').textContent = value ? 'Hide TalkBack inspector' : 'Show TalkBack inspector';
    this.#position();
  }
  #render() {
    const busy = this.#loading || this.#writing;
    this.#settings.setAttribute('aria-busy', String(busy));
    if (busy && !this.#content.inert && this.#content.contains(document.activeElement)) {
      this.#focusAfterBusy = document.activeElement; this.#menu.focus({ preventScroll: true });
    }
    this.#content.inert = busy; this.#activity.hidden = !busy;
    this.#activity.setAttribute('aria-label', this.#writing ? 'Updating accessibility settings' : 'Loading accessibility settings');
    for (const button of this.#menu.querySelectorAll('[data-setting]')) {
      const value = this.#values[button.dataset.setting], known = typeof value === 'boolean';
      button.disabled = busy || !known;
      button.setAttribute('aria-checked', String(known && value));
    }
    if (!busy && this.#focusAfterBusy) {
      const target = this.#focusAfterBusy; this.#focusAfterBusy = null;
      if (!this.#menu.hidden && document.activeElement === this.#menu) {
        (target.disabled ? this.#menu.querySelector('button:not(:disabled)') : target)?.focus({ preventScroll: true });
      }
    }
    this.#position();
  }
  #error(error) {
    this.#status.textContent = String(error?.message || 'Settings unavailable. Close and reopen the menu to retry.').slice(0, 240);
    this.#status.classList.add('error'); this.#position();
  }
  async #toggle(setting) {
    if (this.#disposed || this.#menu.hidden || this.#loading || this.#writing || typeof this.#values[setting] !== 'boolean') return;
    const generation = this.#generation, enabled = !this.#values[setting];
    this.#writing = true; this.#status.textContent = ''; this.#status.classList.remove('error'); this.#render();
    try {
      const response = await this.#write(setting, enabled);
      if (this.#disposed || generation !== this.#generation) return;
      if (response?.setting !== setting || response.enabled !== enabled) throw Error('Setting not confirmed. Reopen the menu to read its current state.');
      this.#values[setting] = enabled;
    } catch (error) {
      if (!this.#disposed && generation === this.#generation) { delete this.#values[setting]; this.#error(error); }
    } finally {
      this.#writing = false; if (!this.#disposed) this.#render();
    }
  }
  open(value, focus = false) {
    if (this.#disposed || value === !this.#menu.hidden) return;
    if (value && openMenu && openMenu !== this) openMenu.open(false);
    const generation = ++this.#generation;
    this.#menu.hidden = !value; this.#trigger.setAttribute('aria-expanded', String(value));
    if (!value) { this.#focusAfterBusy = null; if (openMenu === this) openMenu = null; if (focus && this.#trigger.isConnected) this.#trigger.focus({ preventScroll: true }); return; }
    openMenu = this; this.#values = {}; this.#loading = true;
    this.#status.textContent = ''; this.#status.classList.remove('error'); this.#render();
    if (focus) this.#menu.focus({ preventScroll: true });
    Promise.resolve().then(() => {
      if (this.#disposed || generation !== this.#generation || this.#menu.hidden) return null;
      return this.#read();
    }).then(values => {
      if (this.#disposed || generation !== this.#generation || this.#menu.hidden) return;
      if (!fields.every(([key]) => typeof values?.[key] === 'boolean')) throw Error('Settings unavailable. Close and reopen the menu to retry.');
      this.#values = Object.fromEntries(fields.map(([key]) => [key, values[key]])); this.#status.textContent = '';
    }).catch(error => { if (!this.#disposed && generation === this.#generation && !this.#menu.hidden) this.#error(error); }).finally(() => {
      if (this.#disposed || generation !== this.#generation || this.#menu.hidden) return;
      this.#loading = false; this.#render();
      if (document.activeElement === this.#menu) this.#menu.querySelector('button:not(:disabled)')?.focus({ preventScroll: true });
    });
  }
  #position() {
    const menu = this.#menu; if (this.#disposed || menu.hidden) return;
    const viewport = window.visualViewport, left = viewport?.offsetLeft || 0, top = viewport?.offsetTop || 0;
    const width = viewport?.width || innerWidth, t = this.#trigger.getBoundingClientRect(), w = Math.max(1, Math.min(320, width - 24));
    menu.style.width = w + 'px'; menu.style.left = Math.max(left + 12, Math.min(t.left, left + width - w - 12)) + 'px';
    menu.style.maxHeight = Math.max(0, t.top - top - 20) + 'px';
    menu.style.top = Math.max(top + 10, t.top - menu.getBoundingClientRect().height - 8) + 'px';
  }
  destroy() {
    if (this.#disposed) return; this.open(false); this.#disposed = true; this.#generation++;
    this.#listeners.splice(0).forEach(remove => remove()); this.#menu.remove();
  }
}
