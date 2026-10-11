// No timers, requests or subscription of its own. The owning simulator stream
// is the only transport; closed/paused panes ignore already-in-flight events.
let stylesReady;
export function loadAccessibilityStyles() {
  if (!stylesReady) stylesReady = new Promise((resolve, reject) => {
    const link = document.createElement('link');
    link.rel = 'stylesheet'; link.href = '/css/accessibility.css';
    link.addEventListener('load', resolve, { once: true });
    link.addEventListener('error', () => { link.remove(); stylesReady = null; reject(new Error('Inspector stylesheet unavailable')); }, { once: true });
    document.head.append(link);
  });
  return stylesReady;
}

export class AccessibilityPane {
  #open = false;
  #expanded = false;
  #active = false;
  #subscription = 0;
  #node = null;
  #onToggle;
  #button;
  #status; #speech; #note; #details; #more; #body;
  #panel; #handle; #sizeObserver; #sizeKey; #drag = null;
  #preferred = { compact: null, expanded: null };
  constructor(panel, button, onToggle) {
    this.#button = button; this.#onToggle = onToggle; this.#panel = panel;
    this.#sizeKey = 'simwispAccessibilitySize.v1.' + panel.dataset.udid;
    try {
      const saved = JSON.parse(localStorage.getItem(this.#sizeKey));
      for (const mode of ['compact', 'expanded']) {
        if (Number.isFinite(saved?.[mode]) && saved[mode] > 0 && saved[mode] <= 5000) this.#preferred[mode] = saved[mode];
      }
    } catch {} // Storage may be unavailable; resizing still works for this page.
    this.el = document.createElement('section');
    this.el.className = 'accessibility-pane';
    this.el.id = 'accessibility-' + panel.dataset.udid;
    button.setAttribute('aria-controls', this.el.id);
    this.el.hidden = true;
    this.el.setAttribute('aria-label', 'TalkBack accessibility inspector');
    // Static markup only. All device-origin content is assigned using textContent.
    this.el.innerHTML = `<div class="a11y-resize-handle" role="separator" tabindex="0" aria-orientation="horizontal" aria-label="Resize TalkBack pane" title="Drag to resize; double-click or Enter to reset. Arrow keys resize."></div><div class="a11y-heading"><span class="a11y-title">TalkBack</span><span class="a11y-status" role="status">Waiting</span><button type="button" class="a11y-close" aria-label="Close accessibility pane">×</button></div>
      <div class="a11y-body"><div class="a11y-eyebrow">TALKBACK SAYS</div><p class="a11y-speech" aria-live="polite" aria-atomic="true">Waiting for a TalkBack speech event…</p><p class="a11y-note"></p><div class="a11y-details" hidden></div></div>
      <div class="a11y-footer"><button type="button" class="a11y-more" aria-expanded="false">More…</button><span class="a11y-observed">Last observed focus</span></div>`;
    panel.append(this.el);
    this.#status = this.el.querySelector('.a11y-status');
    this.#speech = this.el.querySelector('.a11y-speech');
    this.#note = this.el.querySelector('.a11y-note');
    this.#details = this.el.querySelector('.a11y-details');
    this.#more = this.el.querySelector('.a11y-more');
    this.#details.id = this.el.id + '-details';
    this.#more.setAttribute('aria-controls', this.#details.id);
    this.#body = this.el.querySelector('.a11y-body');
    this.#handle = this.el.querySelector('.a11y-resize-handle');
    this.#handle.setAttribute('aria-controls', this.el.id);
    // Observe only stable outer geometry while open, never speech contents.
    this.#sizeObserver = new ResizeObserver(() => { if (this.#open) this.#layout(); });
    this.#setupResize();
    this.#more.addEventListener('click', () => {
      this.#finishResize(true);
      this.#expanded = !this.#expanded;
      this.el.classList.toggle('expanded', this.#expanded);
      this.#details.hidden = !this.#expanded;
      this.#more.textContent = this.#expanded ? 'Less' : 'More…';
      this.#more.setAttribute('aria-expanded', String(this.#expanded));
      this.#body.scrollTop = 0;
      this.#layout();
    });
    this.el.querySelector('.a11y-close').addEventListener('click', () => { this.setOpen(false); button.focus(); });
    button.addEventListener('click', () => this.setOpen(!this.#open));
  }
  #bounds() {
    const style = getComputedStyle(this.el);
    const line = parseFloat(getComputedStyle(this.#speech).lineHeight);
    const chrome = parseFloat(style.getPropertyValue('--a11y-chrome-height'));
    const outer = this.#panel.clientHeight;
    const controls = this.#panel.querySelector('.controls-pill')?.getBoundingClientRect().height ?? 0;
    // Keep simulator space and toolbar/footer reachable even after a large drag.
    const max = Math.max(0, Math.min(outer * .75, outer - controls - 48));
    return { min: Math.min(max, chrome + line), max, compact: chrome + 3 * line, outer };
  }
  #layout() {
    if (!this.#open) return;
    const { min, max, compact, outer } = this.#bounds();
    const clamp = h => Math.max(min, Math.min(max, h));
    const compactHeight = clamp(this.#preferred.compact ?? compact);
    const wanted = this.#expanded
      ? this.#preferred.expanded ?? Math.max(outer * .48, compactHeight + 48)
      : compactHeight;
    const height = Math.round(clamp(wanted));
    if (this.el.style.height !== height + 'px') this.el.style.height = height + 'px';
    this.#handle.setAttribute('aria-valuemin', String(Math.round(min)));
    this.#handle.setAttribute('aria-valuemax', String(Math.round(max)));
    this.#handle.setAttribute('aria-valuenow', String(height));
    this.#handle.setAttribute('aria-valuetext', height + ' pixels');
  }
  #saveSize() {
    try {
      if (Object.values(this.#preferred).every(h => h === null)) localStorage.removeItem(this.#sizeKey);
      else localStorage.setItem(this.#sizeKey, JSON.stringify(this.#preferred));
    } catch {}
  }
  #resizeTo(height) {
    const { min, max } = this.#bounds();
    this.#preferred[this.#expanded ? 'expanded' : 'compact'] = Math.max(min, Math.min(max, height));
    this.#layout();
  }
  #finishResize(save) {
    const drag = this.#drag;
    if (!drag) return;
    this.#drag = null;
    if (!save) { this.#preferred[drag.mode] = drag.previous; this.#layout(); }
    if (this.#handle.hasPointerCapture(drag.id)) this.#handle.releasePointerCapture(drag.id);
    if (save) this.#saveSize();
  }
  #resetSize() {
    this.#finishResize(false);
    this.#preferred[this.#expanded ? 'expanded' : 'compact'] = null;
    this.#saveSize(); this.#layout();
  }
  #setupResize() {
    const handle = this.#handle;
    handle.addEventListener('pointerdown', e => {
      if (!this.#open || this.#drag || e.button !== 0 || e.isPrimary === false) return;
      e.preventDefault(); e.stopPropagation(); handle.focus({ preventScroll: true });
      handle.setPointerCapture(e.pointerId);
      const mode = this.#expanded ? 'expanded' : 'compact';
      this.#drag = { id: e.pointerId, y: e.clientY, height: this.el.getBoundingClientRect().height, mode, previous: this.#preferred[mode] };
    });
    handle.addEventListener('pointermove', e => {
      if (this.#drag?.id !== e.pointerId) return;
      e.preventDefault(); e.stopPropagation();
      this.#resizeTo(this.#drag.height + this.#drag.y - e.clientY);
    });
    handle.addEventListener('pointerup', e => {
      if (this.#drag?.id !== e.pointerId) return;
      e.preventDefault(); e.stopPropagation();
      this.#resizeTo(this.#drag.height + this.#drag.y - e.clientY);
      this.#finishResize(true);
    });
    for (const name of ['pointercancel', 'lostpointercapture']) handle.addEventListener(name, e => {
      if (this.#drag?.id === e.pointerId) this.#finishResize(false);
    });
    handle.addEventListener('dblclick', e => { e.preventDefault(); e.stopPropagation(); this.#resetSize(); });
    handle.addEventListener('keydown', e => {
      if (!this.#open) return;
      const { min, max } = this.#bounds();
      const height = this.el.getBoundingClientRect().height;
      const step = e.shiftKey ? 40 : 16;
      const target = ['ArrowUp', 'ArrowDown', 'Home', 'End'].includes(e.key)
        ? ({ ArrowUp: height + step, ArrowDown: height - step, Home: min, End: max })[e.key] : undefined;
      if (e.key === 'Enter' || e.key === 'Escape' || target !== undefined) {
        e.preventDefault(); e.stopPropagation();
        if (e.key === 'Enter') this.#resetSize();
        else if (e.key === 'Escape') this.#finishResize(false);
        else { this.#finishResize(true); this.#resizeTo(target); this.#saveSize(); }
      }
    });
  }
  get isOpen() { return this.#open; }
  get subscription() { return this.#subscription; }
  setOpen(open) {
    this.#finishResize(true);
    this.#subscription++;
    this.#open = Boolean(open); this.#active = false; this.#node = null;
    this.el.hidden = !this.#open; this.#button.classList.toggle('active', this.#open);
    this.#button.setAttribute('aria-pressed', String(this.#open));
    this.#button.setAttribute('aria-expanded', String(this.#open));
    this.#speech.textContent = 'Waiting for a TalkBack speech event…';
    this.#status.textContent = this.#open ? 'Waiting' : 'Off';
    this.#note.textContent = ''; this.#details.replaceChildren();
    if (!this.#open) {
      this.#expanded = false; this.el.classList.remove('expanded');
      this.#details.hidden = true; this.#more.textContent = 'More…'; this.#more.setAttribute('aria-expanded', 'false');
    }
    if (this.#open) {
      this.#layout(); this.#sizeObserver.observe(this.#panel);
      const controls = this.#panel.querySelector('.controls-pill');
      if (controls) this.#sizeObserver.observe(controls);
    } else this.#sizeObserver.disconnect();
    this.#onToggle(this.#open);
  }
  setActive(active) {
    if (this.#active !== Boolean(active)) this.#subscription++;
    this.#active = Boolean(active);
    if (!this.#active && this.#open) { this.#status.textContent = 'Paused'; this.#note.textContent = 'Monitoring stops until this Android stream is active.'; }
  }
  receive(message) {
    if (!this.#open || !this.#active || message.subscription !== this.#subscription) return;
    if (message.type === 'accessibility_status') {
      this.#status.textContent = ({ starting: 'Starting', listening: 'Listening', off: 'Paused', error: 'Unavailable' })[message.state] || 'Waiting';
      this.#note.textContent = String(message.message || '').slice(0, 500);
      return;
    }
    const node = message.node;
    if (message.type !== 'accessibility_event' || !node || typeof node !== 'object') return;
    const previousSpeech = this.#node?.speech;
    this.#node = node;
    this.#status.textContent = 'Live';
    const password = node.password === true;
    this.#speech.textContent = password ? '[Password content hidden]' : (typeof node.speech === 'string' && node.speech ? node.speech : 'No speech command captured for this focus event.');
    this.#note.textContent = node.speech_source === 'composed' ? 'Composed TTS fallback — exact action=SPEAK not observed.' : '';
    const time = typeof node.observed_at === 'string' ? new Date(node.observed_at) : null;
    this.el.querySelector('.a11y-observed').textContent = time && Number.isFinite(time.getTime()) ? `Last observed focus · ${time.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}` : 'Last observed focus';
    this.#renderDetails(node);
    if (!this.#expanded && node.speech !== previousSpeech) this.#body.scrollTop = 0;
  }
  #renderDetails(node) {
    const dl = document.createElement('dl');
    const field = (label, value) => {
      if (value === null || value === undefined || value === '') return;
      const group = document.createElement('div'), dt = document.createElement('dt'), dd = document.createElement('dd');
      dt.textContent = label; dd.textContent = String(value).slice(0, 4096); group.append(dt, dd); dl.append(group);
    };
    for (const [label, key] of [['Accessibility label','label'],['Role','role'],['Tooltip','tooltip'],['Node text','text'],['State description','state_description'],['Package','package'],['Class','class'],['Resource ID','resource_id'],['Unique ID','unique_id']]) field(label, node[key]);
    const b = node.bounds;
    if (b && [b.left,b.top,b.right,b.bottom,b.width,b.height].every(Number.isFinite)) {
      field('Screen bounds', `[${b.left},${b.top}][${b.right},${b.bottom}]`); field('Width / height', `${b.width} × ${b.height} px`);
    }
    if (node.properties && typeof node.properties === 'object') field('Properties', Object.entries(node.properties).slice(0, 12).map(([k,v]) => `${k}=${v}`).join(', '));
    if (Array.isArray(node.actions)) field('Actions', node.actions.slice(0,32).join(', '));
    this.#details.replaceChildren(dl);
  }
}
