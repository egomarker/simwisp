import { fetchInfo, fetchSims, fetchAvailableDevices, bootSim, bootAvd, requestPermission } from './api.js';
import { SimStream } from './stream.js';
import { initTheme } from './theme.js';

initTheme();

// ── DOM refs ─────────────────────────────────────────────────────────────────
const $ = id => document.getElementById(id);
const app            = $('app');
const deviceList     = $('device-list');
const mobileMenuBtn  = $('mobile-menu-btn');
const sidebarBackdrop = $('sidebar-backdrop');
const addSimBtn      = $('add-sim-btn');
const addPopover     = $('add-popover');
const addSearch      = $('add-search');
const addList        = $('add-list');
const addCloseBtn    = $('add-close-btn');
const modeBadge      = $('mode-badge');
const emptyState     = $('empty-state');
const simPanelsEl    = $('sim-panels');
const content        = $('content');
const kbdBar         = $('kbd-bar');
const kbdInput       = $('kbd-input');
const fpsSlider      = $('fps-slider');
const fpsVal         = $('fps-val');
const qualSlider     = $('qual-slider');
const qualVal        = $('qual-val');
const dsBtn          = $('ds-btn');
const projFilter     = $('proj-filter');
const projFilterWrap = $('proj-filter-wrap');
const permsWidget    = $('perms-widget');
const permsBtn       = $('perms-btn');
const permsBody      = $('perms-body');
const permsList      = $('perms-list');

// ── State ────────────────────────────────────────────────────────────────────
let allSims = [];
let hasAdb = false;
const _pendingBoots = new Map(); // id → {name, platform}  (booting but not yet in sims)

// udid → { stream, panelEl, frameEl, canvasEl, overlayEl, pillEl, dotEl, ro, appearMode }
const simPanels = new Map();
let focusedUdid = null;

// Terminal tabs: [{id, label, terminal, el}]
let termTabs = [];
let activeTermTabId = null;
let termOpen = false;
let termPinned = false;

// ── Mobile viewport / software keyboard ──────────────────────────────────────
function updateViewportVars() {
  const vv = window.visualViewport;
  const viewportHeight = vv?.height ?? window.innerHeight;
  const viewportTop = vv?.offsetTop ?? 0;
  const keyboardInset = vv
    ? Math.max(0, window.innerHeight - vv.height - vv.offsetTop)
    : 0;

  document.documentElement.style.setProperty('--visual-vh', `${viewportHeight}px`);
  document.documentElement.style.setProperty('--visual-top', `${viewportTop}px`);
  document.documentElement.style.setProperty('--keyboard-inset', `${keyboardInset}px`);
  app.classList.toggle('keyboard-open', keyboardInset > 60);

  requestAnimationFrame(() => {
    termTabs.find(t => t.id === activeTermTabId)?.terminal.fit();
    if (keyboardInset <= 60) simPanels.forEach(p => sizeFrame(p));
  });
}

updateViewportVars();
window.visualViewport?.addEventListener('resize', updateViewportVars);
window.visualViewport?.addEventListener('scroll', updateViewportVars);
window.addEventListener('resize', updateViewportVars);

// ── Sidebar (drawer on narrow screens, collapsible on desktop) ────────────────
const SIDEBAR_PREF_KEY = 'simmerDesktopSidebarOpen';
let desktopSidebarOpen = true;
try { desktopSidebarOpen = localStorage.getItem(SIDEBAR_PREF_KEY) !== 'false'; } catch {}

function isMobileViewport() {
  return window.matchMedia('(max-width: 700px), (max-height: 480px) and (max-width: 900px)').matches;
}

function syncSidebarLayout() {
  const mobile = isMobileViewport();
  // Preserve mobile drawer state while resizing; never keep its backdrop on desktop.
  if (mobile) {
    app.classList.remove('sidebar-collapsed');
  } else {
    app.classList.remove('sidebar-open');
    app.classList.toggle('sidebar-collapsed', !desktopSidebarOpen);
  }
  const open = mobile ? app.classList.contains('sidebar-open') : desktopSidebarOpen;
  $('sidebar').inert = !open;
  $('sidebar').setAttribute('aria-hidden', String(!open));
  mobileMenuBtn.setAttribute('aria-expanded', String(open));
  mobileMenuBtn.setAttribute('aria-label', open ? 'Hide simulator list' : 'Show simulator list');
  mobileMenuBtn.title = open ? 'Hide simulator list' : 'Show simulator list';
}

function setSidebarOpen(open) {
  if (isMobileViewport()) {
    app.classList.toggle('sidebar-open', open);
  } else {
    desktopSidebarOpen = open;
    try { localStorage.setItem(SIDEBAR_PREF_KEY, String(open)); } catch {}
  }
  syncSidebarLayout();
}

function closeMobileSidebar() {
  if (isMobileViewport()) setSidebarOpen(false);
}

mobileMenuBtn.addEventListener('click', () => {
  const currentlyOpen = isMobileViewport()
    ? app.classList.contains('sidebar-open')
    : desktopSidebarOpen;
  setSidebarOpen(!currentlyOpen);
});
sidebarBackdrop.addEventListener('click', closeMobileSidebar);
window.addEventListener('keydown', e => {
  if (e.key === 'Escape') {
    if (!addPopover.classList.contains('hidden')) { closeAddPopover(); return; }
    if (isMobileViewport() && app.classList.contains('sidebar-open')) {
      closeMobileSidebar();
      mobileMenuBtn.focus();
    }
  }
  if (e.key === 'Tab' && isMobileViewport() && app.classList.contains('sidebar-open')) {
    const container = addPopover.classList.contains('hidden') ? $('sidebar') : addPopover;
    const focusable = [...container.querySelectorAll('button, input, [tabindex="0"]')]
      .filter(el => !el.disabled && el.getClientRects().length);
    const first = focusable[0], last = focusable.at(-1);
    if (!first) return;
    if (e.shiftKey && (document.activeElement === first || !container.contains(document.activeElement))) {
      e.preventDefault(); last.focus();
    } else if (!e.shiftKey && (document.activeElement === last || !container.contains(document.activeElement))) {
      e.preventDefault(); first.focus();
    }
  }
});
window.addEventListener('resize', syncSidebarLayout);
syncSidebarLayout();
// ── Utility ──────────────────────────────────────────────────────────────────
function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function simIcon(name) {
  const n = name.toLowerCase();
  const shape = n.includes('ipad')
    ? '<rect x="4" y="3" width="16" height="18" rx="3"/><path d="M10 18h4"/>'
    : n.includes('watch')
      ? '<rect x="6" y="6" width="12" height="12" rx="4"/><path d="M9 2v4m6-4v4M9 18v4m6-4v4"/>'
      : n.includes('tv')
        ? '<rect x="2" y="4" width="20" height="14" rx="2"/><path d="M8 22h8m-4-4v4"/>'
        : n.includes('vision')
          ? '<rect x="2" y="7" width="20" height="11" rx="5"/><path d="M8 11h1m6 0h1"/>'
          : '<rect x="6" y="2" width="12" height="20" rx="3"/><path d="M10 5h4m-3 14h2"/>';
  return '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + shape + '</svg>';
}

function updateModeBadge(info) {
  if (!info.mode) return;
  const fast = info.mode.startsWith('fast');
  modeBadge.textContent = fast ? (info.mode.includes('fast2') ? 'fast2' : 'fast') : 'compat';
  modeBadge.title = `Capture mode: ${info.mode}`;
  modeBadge.className = 'mode-badge ' + (fast ? 'fast' : 'compat');
}

// ── Permissions widget ────────────────────────────────────────────────────────
function renderPermsWidget(info) {
  const p = info.permissions || {};
  const isFast = (info.mode || '').startsWith('fast');

  const missing = [];
  if (!p.screen_recording) missing.push({
    key: 'screen_recording',
    label: 'Screen Recording',
    detail: 'System Settings → Privacy & Security → Screen Recording',
  });
  if (!p.accessibility) missing.push({
    key: 'accessibility',
    label: 'Accessibility',
    detail: 'System Settings → Privacy & Security → Accessibility',
  });

  if (missing.length === 0) {
    permsWidget.classList.add('hidden');
    return;
  }

  permsWidget.classList.remove('hidden');

  const binPath = info.binary_path || '';
  permsList.innerHTML = missing.map(m => `
    <div class="perms-item">
      <div class="perms-item-top">
        <span class="perms-item-label">${esc(m.label)}</span>
        <button class="perms-grant-btn" data-perm="${esc(m.key)}">Open Settings</button>
      </div>
      <div class="perms-item-detail">${esc(m.detail)}</div>
      ${binPath ? `<div class="perms-item-path">
        <span class="perms-path-value">${esc(binPath)}</span>
        <button class="perms-copy-btn" data-path="${esc(binPath)}" title="Copy path">Copy</button>
      </div>` : ''}
    </div>
  `).join('');

  permsList.querySelectorAll('.perms-grant-btn').forEach(btn => {
    btn.onclick = async () => {
      await requestPermission(btn.dataset.perm);
      const updated = await fetchInfo();
      renderPermsWidget(updated);
      updateModeBadge(updated);
    };
  });

  permsList.querySelectorAll('.perms-copy-btn').forEach(btn => {
    btn.onclick = () => {
      navigator.clipboard.writeText(btn.dataset.path);
      btn.textContent = 'Copied';
      setTimeout(() => { btn.textContent = 'Copy'; }, 1500);
    };
  });

  permsBtn.onclick = () => {
    const open = permsBody.classList.toggle('open');
    permsBtn.classList.toggle('open', open);
  };
}

// ── Sims cache (stale-while-revalidate) ───────────────────────────────────────
const _SIMS_CACHE = 'simwispSimsCache';

function _readSimsCache() {
  try { return JSON.parse(localStorage.getItem(_SIMS_CACHE)); } catch { return null; }
}
function _writeSimsCache(sims, info) {
  try {
    localStorage.setItem(_SIMS_CACHE, JSON.stringify({
      sims, hasAdb: info.has_adb !== false,
      mode: info.mode, bundleId: info.bundle_id ?? null,
    }));
  } catch {}
}

// ── Device list ──────────────────────────────────────────────────────────────
async function loadSims() {
  // Show cached data immediately so the sidebar isn't blank while we wait
  const cached = _readSimsCache();
  if (cached?.sims) {
    allSims = cached.sims;
    hasAdb = cached.hasAdb ?? false;
    if (cached.mode) updateModeBadge(cached);
    if (cached.bundleId) {
      projFilterWrap.classList.add('visible');
      projFilterWrap.querySelector('span').textContent =
        cached.bundleId.split('.').pop() + ' only';
    }
    renderDeviceList();
  } else {
    deviceList.innerHTML = '<div class="device-list-empty">Scanning…</div>';
  }

  try {
    const [sims, info] = await Promise.all([fetchSims(), fetchInfo()]);
    allSims = sims;
    hasAdb = info.has_adb !== false;
    _writeSimsCache(sims, info);
    updateModeBadge(info);
    renderPermsWidget(info);
    terminalCapability(info.features?.terminal);

    if (info.bundle_id) {
      projFilterWrap.classList.add('visible');
      projFilterWrap.querySelector('span').textContent =
        info.bundle_id.split('.').pop() + ' only';
    } else {
      projFilterWrap.classList.remove('visible');
    }

    renderDeviceList();
  } catch {
    if (!cached?.sims) {
      deviceList.innerHTML = '<div class="device-list-empty">Could not reach server</div>';
    }
  }
}

// ── Add-simulator popover ─────────────────────────────────────────────────────
let _addDevices = [];
let _bootingIds = new Set();

let addReturnFocus = null;
function openAddPopover() {
  addReturnFocus = document.activeElement;
  setSidebarOpen(true);
  addPopover.classList.remove('hidden');
  addPopover.setAttribute('aria-hidden', 'false');
  [...$('sidebar').children].forEach(el => { el.inert = el !== addPopover; });
  addSearch.value = '';
  addList.innerHTML = '<div class="add-list-empty">Loading…</div>';
  addSearch.focus();

  fetchAvailableDevices().then(devices => {
    const bootedIds = new Set(allSims.map(s => s.id));
    _addDevices = devices.filter(d => !bootedIds.has(d.id));
    renderAddList('');
  }).catch(() => {
    addList.innerHTML = '<div class="add-list-empty">Could not load devices</div>';
  });
}

function closeAddPopover() {
  addPopover.classList.add('hidden');
  addPopover.setAttribute('aria-hidden', 'true');
  [...$('sidebar').children].forEach(el => { el.inert = false; });
  if (addReturnFocus?.isConnected) addReturnFocus.focus();
}

function renderAddList(query) {
  const q = query.toLowerCase().trim();
  const filtered = q ? _addDevices.filter(d => d.name.toLowerCase().includes(q)) : _addDevices;

  if (!filtered.length) {
    addList.innerHTML = `<div class="add-list-empty">${q ? 'No matches' : 'No simulators available'}</div>`;
    return;
  }

  const groups = {};
  for (const d of filtered) {
    const g = d.platform === 'android' ? 'Android' : 'iOS';
    (groups[g] = groups[g] || []).push(d);
  }

  addList.innerHTML = Object.entries(groups).map(([label, devs]) => `
    <div class="add-group">
      <div class="add-group-label">${label}</div>
      ${devs.map(d => {
        const booting = _bootingIds.has(d.id);
        return `<div class="add-device-item" data-id="${esc(d.id)}" data-name="${esc(d.name)}"
                     data-platform="${esc(d.platform)}"
                     data-w="${d.width || 0}" data-h="${d.height || 0}">
          <span class="add-device-icon">${simIcon(d.name)}</span>
          <span class="add-device-info">
            <span class="add-device-name">${esc(d.name)}</span>
            ${d.runtime ? `<span class="add-device-sub">${esc(d.runtime)}</span>` : ''}
          </span>
          <button class="add-boot-btn${booting ? ' booting' : ''}" title="${booting ? 'Booting…' : 'Boot'}">
            ${booting ? '<span class="add-spinner"></span>' : '▶'}
          </button>
        </div>`;
      }).join('')}
    </div>`).join('');

  addList.querySelectorAll('.add-boot-btn:not(.booting)').forEach(btn => {
    const item = btn.closest('.add-device-item');
    btn.addEventListener('click', () => handleAddBoot(
      item.dataset.id, item.dataset.name, item.dataset.platform,
      parseInt(item.dataset.w), parseInt(item.dataset.h)
    ));
  });
}

async function handleAddBoot(id, name, platform, w, h) {
  if (_bootingIds.has(id)) return;
  _bootingIds.add(id);
  renderAddList(addSearch.value);

  const prevAndroidIds = new Set(allSims.filter(s => s.id.startsWith('emulator-')).map(s => s.id));

  try {
    if (platform === 'android') await bootAvd(id);
    else await bootSim(id);
  } catch { /* poll handles it */ }

  closeAddPopover();
  closeMobileSidebar();

  // Show a booting row in the sidebar while we wait
  if (platform === 'android') {
    _pendingBoots.set(id, { name, platform });
    renderDeviceList();
  }

  // Android emulators can take 2-3 minutes to fully boot
  const timeout = platform === 'android' ? 180_000 : 90_000;

  const poll = setInterval(async () => {
    const sims = await fetchSims().catch(() => null);
    if (!sims) return;
    let booted = null;
    if (platform === 'android') {
      booted = sims.find(s => s.id.startsWith('emulator-') && !prevAndroidIds.has(s.id));
    } else {
      booted = sims.find(s => s.id === id);
    }
    if (booted) {
      clearInterval(poll);
      _bootingIds.delete(id);
      _pendingBoots.delete(id);
      allSims = sims;
      renderDeviceList();
      addSimPanel(booted.id, booted.name, booted.width, booted.height, booted.platform);
    }
  }, 2000);

  setTimeout(() => {
    clearInterval(poll);
    _bootingIds.delete(id);
    _pendingBoots.delete(id);
    renderDeviceList();
  }, timeout);
}

addSimBtn.addEventListener('click', openAddPopover);
$('empty-add').addEventListener('click', openAddPopover);
addCloseBtn.addEventListener('click', closeAddPopover);
addSearch.addEventListener('input', () => renderAddList(addSearch.value));
addPopover.addEventListener('keydown', e => {
  if (e.key === 'Escape') { e.stopPropagation(); closeAddPopover(); }
});

function renderDeviceList() {
  updateKeyboardPlaceholder();
  $('device-count').textContent = allSims.length;
  const filterOn = projFilter.checked;
  const sims = filterOn ? allSims.filter(s => s.project_app) : allSims;
  const adbHint = !hasAdb
    ? '<div class="device-list-hint">🤖 <span>No <code>adb</code> — install Android Studio for Android</span></div>'
    : '';

  // Booting-but-not-yet-running rows
  const bootingRows = [..._pendingBoots.values()].map(b => `
    <div class="device-item device-item-booting">
      <span class="device-icon">${simIcon(b.name)}</span>
      <span class="device-info">
        <span class="device-name">${esc(b.name)}</span>
        <span class="device-dims">Booting…</span>
      </span>
      <span class="add-spinner" style="flex-shrink:0;margin-right:2px"></span>
    </div>`).join('');

  if (!sims.length) {
    deviceList.innerHTML = bootingRows + `<div class="device-list-empty">${
      filterOn ? 'No project simulators' : 'No simulators running'
    }</div>${adbHint}`;
    return;
  }
  deviceList.innerHTML = bootingRows + sims.map(s => `
    <button type="button" class="device-item${simPanels.has(s.id) ? ' active' : ''}"
        aria-pressed="${simPanels.has(s.id)}" title="${esc(s.name)}"
        data-udid="${esc(s.id)}" data-name="${esc(s.name)}"
        data-platform="${esc(s.platform)}"
        data-w="${s.width}" data-h="${s.height}">
      <span class="device-icon">${simIcon(s.name)}</span>
      <span class="device-info">
        <span class="device-name">${esc(s.name)}</span>
        <span class="device-dims">${s.platform === 'android' ? 'Android' : 'iOS'} · ${s.width && s.height ? `${s.width} × ${s.height}` : 'Emulator'}</span>
      </span>
      ${s.project_app ? '<span class="device-badge" title="Project app installed">★</span>' : ''}
      ${simPanels.has(s.id) ? '<span class="device-open-indicator" aria-hidden="true"></span>' : ''}
    </button>`).join('') + adbHint;

  deviceList.querySelectorAll('button.device-item').forEach(el => {
    el.addEventListener('click', () =>
      toggleDevice(
        el.dataset.udid,
        el.dataset.name,
        parseInt(el.dataset.w),
        parseInt(el.dataset.h),
        el.dataset.platform
      ));
  });
}

// ── Sim panel management ──────────────────────────────────────────────────────
function toggleDevice(udid, name, w, h, platform) {
  if (simPanels.has(udid)) {
    removeSimPanel(udid);
  } else {
    if (isMobileViewport()) {
      for (const openUdid of [...simPanels.keys()]) removeSimPanel(openUdid, { silent: true });
    }
    addSimPanel(udid, name, w, h, platform);
  }
  closeMobileSidebar();
}

function addSimPanel(udid, name, w, h, platform) {
  if (simPanels.has(udid)) { setFocusedPanel(udid); return; }

  // ── Build DOM ──
  const panelEl = document.createElement('div');
  panelEl.className = 'sim-panel';
  panelEl.dataset.udid = udid;

  panelEl.setAttribute('role', 'group');
  panelEl.setAttribute('aria-label', name);
  panelEl.addEventListener('pointerdown', () => setFocusedPanel(udid));
  panelEl.addEventListener('focusin', () => setFocusedPanel(udid));

  const stageEl = document.createElement('div');
  stageEl.className = 'sim-stage';
  const frameEl = document.createElement('div');
  frameEl.className = 'device-frame';

  const canvasEl = document.createElement('canvas');
  canvasEl.width  = Math.min(w, h);
  canvasEl.height = Math.max(w, h);
  canvasEl.setAttribute('aria-label', name + ' live screen');

  const overlayEl = document.createElement('div');
  overlayEl.className = 'connect-overlay';
  overlayEl.setAttribute('role', 'status');
  overlayEl.innerHTML = '<div class="spinner"></div><span>Connecting…</span>';

  frameEl.append(canvasEl, overlayEl);

  const pillEl = createPill(udid, name, platform);
  stageEl.appendChild(frameEl);
  panelEl.append(stageEl, pillEl);

  simPanelsEl.appendChild(panelEl);
  emptyState.classList.add('hidden');

  // ── Panel object ──
  const dotEl = pillEl.querySelector('.status-dot');
  const statsEl = pillEl.querySelector('.stream-stats');
  const panel = {
    stream: null, panelEl, stageEl, frameEl, canvasEl, name,
    overlayEl, pillEl, dotEl, statsEl,
    statusEl: pillEl.querySelector('.panel-status'),
    platform,
    accessibility: null,
    ro: null, appearMode: 'dark', twoFingerMode: false,
  };
  simPanels.set(udid, panel);
  if (platform === 'android') {
    const button = pillEl.querySelector('[data-action="accessibility"]');
    // Optional assets and pane are created only on an explicit first open.
    const firstOpen = async () => {
      if (button.disabled) return;
      button.disabled = true;
      try {
        const { AccessibilityPane, loadAccessibilityStyles } = await import('./accessibility.js');
        await loadAccessibilityStyles();
        if (simPanels.get(udid) !== panel) return;
        panel.accessibility = new AccessibilityPane(panelEl, button, () => updateStreamVisibility());
        button.removeEventListener('click', firstOpen);
        panel.accessibility.setOpen(true);
      } catch (error) {
        button.title = 'Accessibility inspector failed to load — retry or reload';
        console.warn('Simwisp accessibility:', error);
      } finally { button.disabled = false; }
    };
    button.addEventListener('click', firstOpen);
  }

  rebuildDividers();

  // ── ResizeObserver ──
  panel.ro = new ResizeObserver(() => sizeFrame(panel));
  panel.ro.observe(stageEl);

  // ── Stream ──
  panel.stream = new SimStream(udid, canvasEl, {
    fps:     parseInt(fpsSlider.value),
    quality: parseInt(qualSlider.value),
    data_saver: dsBtn.classList.contains('active'),
    onStatus:            s => updatePanelStatus(udid, s),
    onFirstFrame:        () => overlayEl.classList.add('hidden'),
    onOrientationChange: () => sizeFrame(panel),
    onRotateStart:       () => setPanelProgress(udid, 'Rotating…'),
    onRotateEnd:         ok => clearPanelProgress(udid, ok ? null : 'Rotate failed'),
    onStats:             stats => updatePanelStats(udid, stats),
    onAccessibility:     message => panel.accessibility?.receive(message),
  });
  //panel.stream.updateSettings({ data_saver: dsBtn.classList.contains('active') });
  updateStreamVisibility();

  setFocusedPanel(udid);
  renderDeviceList();
  saveSession();
}

function removeSimPanel(udid, { silent = false } = {}) {
  const panel = simPanels.get(udid);
  if (!panel) return;

  panel.accessibility?.setOpen(false);
  panel.stream?.destroy();
  panel.ro?.disconnect();
  panel.panelEl.remove();
  simPanels.delete(udid);

  rebuildDividers();

  if (focusedUdid === udid) {
    focusedUdid = simPanels.size ? [...simPanels.keys()][0] : null;
    if (focusedUdid) setFocusedPanel(focusedUdid);
  }

  if (!simPanels.size) {
    emptyState.classList.remove('hidden');
    kbdBar.classList.remove('visible');
  }
  updateKeyboardPlaceholder();
  if (!silent) {
    renderDeviceList();
    saveSession();
  }
}

// Corner radius in logical points for each device class.
// Matches UIScreen.cornerRadius on the actual device at 1× logical resolution.
// iOS device corner radius in logical points.
function deviceCornerRadius(w, h) {
  const short = Math.min(w, h);

  if (short >= 744) return 18;  // iPad
  if (short <= 320) return 4;   // iPhone SE 1st gen
  if (short <= 375) return 39;  // Older iPhones
  return 47;                    // Modern iPhones
}

function sizeFrame(panel) {
  const { stageEl, frameEl, canvasEl, platform } = panel;
  if (!canvasEl.width || !canvasEl.height) return;
  const style = getComputedStyle(stageEl);
  const availW = Math.max(1, stageEl.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight));
  const availH = Math.max(1, stageEl.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom));

  const scale = Math.min(
    availW / canvasEl.width,
    availH / canvasEl.height
  );

  frameEl.style.width =
    Math.round(canvasEl.width * scale) + 'px';

  frameEl.style.height =
    Math.round(canvasEl.height * scale) + 'px';

  const radius = platform === 'android'
    ? 12
    : Math.round(
        deviceCornerRadius(canvasEl.width, canvasEl.height) * scale
      );

  frameEl.style.borderRadius = radius + 'px';
}

// ── Dividers between panels ───────────────────────────────────────────────────
function rebuildDividers() {
  simPanelsEl.querySelectorAll('.sim-divider').forEach(d => d.remove());
  const panels = [...simPanelsEl.querySelectorAll('.sim-panel')];

  // Reset to equal flex shares whenever panels change
  panels.forEach(p => { p.style.flex = ''; });

  for (let i = 0; i < panels.length - 1; i++) {
    const divider = document.createElement('div');
    divider.className = 'sim-divider';
    divider.tabIndex = 0;
    divider.setAttribute('role', 'separator');
    divider.setAttribute('aria-orientation', 'vertical');
    divider.setAttribute('aria-label', 'Resize adjacent simulators');
    divider.setAttribute('aria-valuemin', '0');
    divider.setAttribute('aria-valuemax', '100');
    panels[i].insertAdjacentElement('afterend', divider);
    initDividerDrag(divider, panels[i], panels[i + 1]);
  }

  simPanels.forEach(p => sizeFrame(p));
}

function initDividerDrag(divider, leftEl, rightEl) {
  let startX, leftW, rightW;
  const totalWidth = leftEl.clientWidth + rightEl.clientWidth;
  divider.setAttribute('aria-valuenow', String(totalWidth ? Math.round(leftEl.clientWidth / totalWidth * 100) : 50));
  function beginResize() {
    // Pixel-weighted flex shares preserve other panels in 3+ device layouts.
    const widths = [...simPanelsEl.querySelectorAll('.sim-panel')]
      .map(el => [el, el.getBoundingClientRect().width]);
    widths.forEach(([el, width]) => { el.style.flex = `${width} 1 0px`; });
    leftW = leftEl.getBoundingClientRect().width;
    rightW = rightEl.getBoundingClientRect().width;
  }
  function resizeBy(delta) {
    const total = leftW + rightW;
    const min = Math.min(260, total / 2);
    const next = Math.max(min, Math.min(total - min, leftW + delta));
    leftEl.style.flex = `${next} 1 0px`;
    rightEl.style.flex = `${total - next} 1 0px`;
    divider.setAttribute('aria-valuenow', String(Math.round(next / total * 100)));
  }
  divider.addEventListener('pointerdown', e => {
    e.preventDefault();
    divider.setPointerCapture(e.pointerId);
    startX = e.clientX;
    beginResize();
    divider.addEventListener('pointermove', onMove);
  });
  function onMove(e) { resizeBy(e.clientX - startX); }
  function onEnd() { divider.removeEventListener('pointermove', onMove); }
  divider.addEventListener('pointerup', onEnd);
  divider.addEventListener('pointercancel', onEnd);
  divider.addEventListener('lostpointercapture', onEnd);
  divider.addEventListener('keydown', e => {
    if (!['ArrowLeft', 'ArrowRight'].includes(e.key)) return;
    e.preventDefault();
    beginResize();
    resizeBy(e.key === 'ArrowLeft' ? -24 : 24);
  });
}

// ── Focus ─────────────────────────────────────────────────────────────────────
function setFocusedPanel(udid) {
  focusedUdid = udid;
  simPanels.forEach((p, id) =>
    p.panelEl.classList.toggle('focused', id === udid));
  updateKeyboardPlaceholder();
}

function updateKeyboardPlaceholder() {
  const name = simPanels.get(focusedUdid)?.name;
  kbdInput.placeholder = name ? `Send text to ${name}…` : 'Type to send…';
}

// ── Per-panel status ──────────────────────────────────────────────────────────
function updatePanelStatus(udid, status) {
  const panel = simPanels.get(udid);
  if (!panel) return;
  const { dotEl, overlayEl } = panel;
  const active = !document.hidden && !(isMobileViewport() && termOpen) && ['connected', 'streaming'].includes(status);
  panel.accessibility?.setActive(active);
  if (panel.accessibility?.isOpen) panel.stream?.updateSettings({ accessibility_enabled: active, accessibility_subscription: panel.accessibility.subscription });
  panel.statusEl.textContent = ({ streaming: 'Live', connected: 'Ready', reconnecting: 'Reconnecting', 'no-frames': 'No frames' })[status] || 'Connecting';
  dotEl.className = 'status-dot';
  if (status === 'streaming' || status === 'connected') {
    dotEl.classList.add('connected');
  } else if (status === 'reconnecting') {
    dotEl.classList.add('reconnecting');
    overlayEl.innerHTML = '<span>Reconnecting…</span>';
    overlayEl.classList.remove('hidden');
  } else if (status === 'no-frames') {
    overlayEl.classList.remove('hidden');
    overlayEl.innerHTML =
      `<span>No frames received.<br>Enable Screen Recording for Simwisp on the Mac and keep the device window open.</span>`;
  } else {
    overlayEl.innerHTML = '<div class="spinner"></div><span>Connecting…</span>';
    overlayEl.classList.remove('hidden');
  }
}

function setPanelProgress(udid, message) {
  const panel = simPanels.get(udid);
  if (!panel) return;
  panel.overlayEl.innerHTML = `<div class="spinner"></div><span>${esc(message)}</span>`;
  panel.overlayEl.classList.remove('hidden');
}

function clearPanelProgress(udid, errorMessage = null) {
  const panel = simPanels.get(udid);
  if (!panel) return;
  if (errorMessage) {
    panel.overlayEl.innerHTML = `<span>${esc(errorMessage)}</span>`;
    panel.overlayEl.classList.remove('hidden');
    setTimeout(() => panel.overlayEl.classList.add('hidden'), 1800);
  } else {
    panel.overlayEl.classList.add('hidden');
  }
}

function fmtRate(bytesPerSecond) {
  if (bytesPerSecond >= 1024 * 1024) return `${(bytesPerSecond / 1024 / 1024).toFixed(1)} MB/s`;
  if (bytesPerSecond >= 1024) return `${Math.round(bytesPerSecond / 1024)} KB/s`;
  return `${Math.round(bytesPerSecond)} B/s`;
}

function fmtRateCompact(bytesPerSecond) {
  if (bytesPerSecond >= 1024 * 1024) return `${(bytesPerSecond / 1024 / 1024).toFixed(1)}M`;
  if (bytesPerSecond >= 1024) return `${Math.round(bytesPerSecond / 1024)}K`;
  return `${Math.round(bytesPerSecond)}B`;
}

function updatePanelStats(udid, stats) {
  const panel = simPanels.get(udid);
  if (!panel?.statsEl) return;
  const quality = stats.serverQuality ?? parseInt(qualSlider.value);
  const serverFps = stats.serverFps ?? parseInt(fpsSlider.value);
  panel.statsEl.textContent = isMobileViewport()
    ? `${stats.fps}fps ${fmtRateCompact(stats.bps)}`
    : `${stats.fps} fps · ${fmtRate(stats.bps)} · q${quality}`;
  panel.statsEl.title = `Rendered ${stats.fps} fps. Server target ${serverFps} fps, quality ${quality}. Avg frame ${Math.round(stats.avgFrame / 1024 || 0)} KB. Dropped ${stats.dropped}.`;
}

function updateStreamVisibility() {
  const paused = document.hidden || (isMobileViewport() && termOpen);
  simPanels.forEach(p => {
    p.accessibility?.setActive(!paused);
    p.stream?.updateSettings({ stream_paused: paused, accessibility_enabled: !paused && p.accessibility?.isOpen === true, accessibility_subscription: p.accessibility?.subscription ?? 0 });
  });
}

// ── Controls pill (per panel) ─────────────────────────────────────────────────
function createPill(udid, name, platform) {
  const pill = document.createElement('div');
  pill.className = 'controls-pill';
  pill.innerHTML = `
    <div class="panel-telemetry"><span class="status-dot"></span><span class="panel-status">Connecting</span>
      <span class="stream-stats" title="Stream stats">— fps · — KB/s</span>
    </div>
    <div class="panel-actions" role="group" aria-label="Simulator controls">
    <button class="pill-btn" data-action="rotate" title="Rotate">
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
        <path d="M3.5 10a6.5 6.5 0 1 0 6.5-6.5H7"/><path d="M7 1.5v4H3"/>
      </svg>
    </button>
    <button class="pill-btn" data-action="home" title="Home">
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
        <path d="M3 9.5L10 3l7 6.5"/><path d="M5 8.5v8h3.5v-4h3v4H15v-8"/>
      </svg>
    </button>
    ${platform === 'ios' ? `
    <button class="pill-btn" data-action="shake" title="Shake (Control–Command–Z)">
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <g transform="rotate(-12 10 10)"><rect x="6.5" y="3" width="7" height="14" rx="1.8"/><path d="M9 14h2"/></g>
        <path d="m3.5 5.5-1.5 2.5 1.5 2.5L2 13m14.5-6L18 9.5 16.5 12l1.5 2.5"/>
      </svg>
    </button>
    <button class="pill-btn" data-action="app-switcher" title="App switcher (Shift–Command–H–H)">
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <path d="M13 6V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h2"/>
        <rect x="7" y="6" width="10" height="11" rx="2"/><path d="M10 14h4"/>
      </svg>
    </button>` : ''}
    <button class="pill-btn" data-action="appear" title="Switch simulator to light appearance">
      <svg width="18" height="18" viewBox="0 0 20 20" fill="currentColor">
        <path d="M10 3.5a6.5 6.5 0 0 0 0 13A7.5 7.5 0 0 1 10 3.5z"/>
      </svg>
    </button>
    <div class="pill-sep"></div>
    ${udid.startsWith('emulator-')
      ? '<button class="pill-btn" data-action="two-finger" title="TalkBack scroll (ADB swipe)" aria-pressed="false">2F</button>'
      : ''}
    ${platform === 'android' ? '<button class="pill-btn a11y-toggle" data-action="accessibility" title="TalkBack accessibility inspector" aria-pressed="false" aria-expanded="false"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="7" r="1"/><path d="m7 10 5 1 5-1M12 11v4m0 0-3 3m3-3 3 3"/></svg><span>A11y</span></button>' : ''}
    <button class="pill-btn" data-action="kbd" title="Keyboard">
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
        <rect x="1" y="5" width="18" height="11" rx="2"/>
        <path d="M5 9h1M9 9h1M13 9h1M5 13h10"/>
      </svg>
    </button>
    <button class="pill-btn" data-action="close" title="Close ${esc(name)}">
      <svg width="16" height="16" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true"><path d="m5 5 10 10M15 5 5 15"/></svg>
    </button>
    </div>`;
  pill.querySelector('.panel-telemetry').title = name;
  pill.querySelector('.panel-actions').setAttribute('aria-label', name + ' controls');
  pill.querySelectorAll('button').forEach(button => button.setAttribute('aria-label', button.title));

  pill.addEventListener('click', e => {
    const btn = e.target.closest('[data-action]');
    if (!btn) return;
    const action = btn.dataset.action;
    const panel  = simPanels.get(udid);

    setFocusedPanel(udid);

    switch (action) {
      case 'close': removeSimPanel(udid); break;
      case 'rotate': panel?.stream?.send({ type: 'rotate' }); break;
      case 'home':   panel?.stream?.send({ type: 'home' });   break;
      case 'shake':
        if (panel?.platform === 'ios') panel.stream?.send({ type: 'shake' });
        break;
      case 'app-switcher':
        if (panel?.platform === 'ios') panel.stream?.send({ type: 'app_switcher' });
        break;
      case 'appear': {
        if (!panel) break;
        panel.appearMode = panel.appearMode === 'dark' ? 'light' : 'dark';
        const light = panel.appearMode === 'light';
        btn.innerHTML = light
          ? `<svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><circle cx="10" cy="10" r="3.5"/><path d="M10 2.5v1.5M10 16v1.5M2.5 10H4M16 10h1.5M4.7 4.7l1 1M14.3 14.3l1 1M15.3 4.7l-1 1M5.7 14.3l-1 1"/></svg>`
          : `<svg width="18" height="18" viewBox="0 0 20 20" fill="currentColor"><path d="M10 3.5a6.5 6.5 0 0 0 0 13A7.5 7.5 0 0 1 10 3.5z"/></svg>`;
        btn.title = light ? 'Switch simulator to dark appearance' : 'Switch simulator to light appearance';
        btn.setAttribute('aria-label', btn.title);
        panel.stream?.send({ type: 'appearance', mode: panel.appearMode });
        break;
      }
      case 'two-finger': {
        if (!panel) break;
        panel.twoFingerMode = !panel.twoFingerMode;
        panel.stream?.setTwoFinger(panel.twoFingerMode);
        btn.classList.toggle('active', panel.twoFingerMode);
        btn.setAttribute('aria-pressed', String(panel.twoFingerMode));
        btn.title = panel.twoFingerMode
          ? 'TalkBack scroll (ADB swipe): ON'
          : 'TalkBack scroll (ADB swipe)';
        break;
      }
      case 'kbd': {
        const open = kbdBar.classList.toggle('visible');
        btn.classList.toggle('active', open);
        if (open) kbdInput.focus();
        break;
      }
    }
  });

  // clicking anywhere on the panel body (outside controls) focuses it
  return pill;
}

// ── Settings sliders ─────────────────────────────────────────────────────────
fpsSlider.addEventListener('input', () => {
  fpsVal.textContent = fpsSlider.value;
  simPanels.forEach(p => p.stream?.updateSettings({ fps: parseInt(fpsSlider.value) }));
  saveSession();
});
qualSlider.addEventListener('input', () => {
  qualVal.textContent = qualSlider.value;
  simPanels.forEach(p => p.stream?.updateSettings({ quality: parseInt(qualSlider.value) }));
  saveSession();
});
dsBtn.addEventListener('click', () => {
  const on = dsBtn.classList.toggle('active');
  dsBtn.setAttribute('aria-pressed', String(on));
  simPanels.forEach(p => p.stream?.updateSettings({ data_saver: on }));
  saveSession();
});
document.addEventListener('visibilitychange', updateStreamVisibility);
window.addEventListener('resize', updateStreamVisibility);
projFilter.addEventListener('change', renderDeviceList);
$('btn-refresh').addEventListener('click', loadSims);

// ── Keyboard bar (sends to focused panel) ─────────────────────────────────────
function sendKbdText() {
  const t = kbdInput.value; if (!t) return;
  simPanels.get(focusedUdid)?.stream?.send({ type: 'text', text: t });
  kbdInput.value = ''; kbdInput.focus();
}
kbdInput.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); sendKbdText(); } });
$('kbd-send').addEventListener('click', sendKbdText);
$('kbd-bs').addEventListener('click',  () => simPanels.get(focusedUdid)?.stream?.send({ type: 'key', key: 'backspace' }));
$('kbd-ret').addEventListener('click', () => simPanels.get(focusedUdid)?.stream?.send({ type: 'key', key: 'return' }));

// ── Terminal workspace (loaded on explicit open, never during streaming) ──
const terminalButton = $('btn-terminal');
const termPanelEl = $('terminal-panel');
const termPanesEl = $('term-panes');
const termTabsBar = $('term-tabs-bar');
const termStatusDot = $('term-status-dot');
const termResizeHandle = $('term-resize-handle');
let terminalEnabled = false;
let terminalLoading = null;
let SimTerminal = null;
let terminalResizeObserver = null;
let termSerial = 0;
const TERM_TABS_KEY = 'simwispTerminalTabs';
let termFontSize = 13;
try { termFontSize = Math.min(24, Math.max(9, parseInt(localStorage.getItem('termFontSize')) || 13)); } catch {}
$('font-size-val').textContent = termFontSize;

function terminalCapability(enabled) {
  terminalEnabled = !!enabled;
  terminalButton.disabled = !terminalEnabled;
  terminalButton.title = terminalEnabled ? 'Open a Mac terminal' : 'Enable Mac terminal access in Simwisp’s menu';
  if (!terminalEnabled && termTabs.length) {
    termTabs.forEach(tab => { tab.terminal.destroy(); tab.el.remove(); });
    termTabs = []; activeTermTabId = null; closeTerminal(); persistTerminalTabs();
  }
}
function persistTerminalTabs() {
  try { sessionStorage.setItem(TERM_TABS_KEY, JSON.stringify(termTabs.map(tab => ({ sessionId: tab.terminal.sessionId, label: tab.label })))); } catch {}
}
function activeTerminal() { return termTabs.find(tab => tab.id === activeTermTabId); }
function updateTerminalStatus() {
  const status = activeTerminal()?.status || 'connecting';
  termStatusDot.className = 'status-dot';
  if (status === 'connected') termStatusDot.classList.add('connected');
  else if (status === 'reconnecting') termStatusDot.classList.add('reconnecting');
  termStatusDot.title = status; termStatusDot.setAttribute('aria-label', 'Terminal ' + status);
}
function renderTermTabs() {
  termTabsBar.innerHTML = termTabs.map(tab => `<div class="term-tab${tab.id === activeTermTabId ? ' active' : ''}" data-id="${tab.id}" role="tab" tabindex="0" aria-selected="${tab.id === activeTermTabId}"><span class="term-tab-label">${esc(tab.label)}</span><button class="term-tab-close" aria-label="Close ${esc(tab.label)}">✕</button></div>`).join('');
  termTabsBar.querySelectorAll('.term-tab').forEach(el => {
    el.addEventListener('click', event => { if (!event.target.closest('.term-tab-close')) activateTermTab(el.dataset.id); });
    el.addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); activateTermTab(el.dataset.id); } });
    el.querySelector('.term-tab-close').addEventListener('click', () => closeTermTab(el.dataset.id));
  });
  $('btn-add-term').disabled = termTabs.length >= 8;
}
function addTermTab(saved = {}) {
  if (termTabs.length >= 8) return;
  const id = 'term-' + (++termSerial);
  const el = document.createElement('div'); el.className = 'term-pane'; el.id = id; termPanesEl.append(el);
  const tab = { id, label: saved.label || 'Terminal ' + termSerial, terminal: null, el, status: 'connecting' };
  termTabs.push(tab);
  tab.terminal = new SimTerminal(el, {
    sessionId: saved.sessionId || null,
    onStatus: status => { tab.status = status; if (activeTermTabId === id) updateTerminalStatus(); },
    onSession: () => persistTerminalTabs(),
  });
  tab.terminal.setFontSize(termFontSize);
  activateTermTab(id); persistTerminalTabs();
}
function activateTermTab(id) {
  activeTermTabId = id;
  termTabs.forEach(tab => { tab.el.classList.toggle('active', tab.id === id); tab.el.inert = tab.id !== id; });
  renderTermTabs(); updateTerminalStatus();
  if (termOpen) { activeTerminal()?.terminal.fit(); activeTerminal()?.terminal.focus(); }
}
function closeTermTab(id) {
  const index = termTabs.findIndex(tab => tab.id === id); if (index < 0) return;
  const [tab] = termTabs.splice(index, 1); tab.terminal.destroy(); tab.el.remove();
  if (!termTabs.length) { activeTermTabId = null; termPinned = false; content.classList.remove('pinned-right'); closeTerminal(); }
  else if (activeTermTabId === id) activateTermTab(termTabs[Math.max(0, index - 1)].id);
  renderTermTabs(); persistTerminalTabs(); saveSession();
}
async function openTerminal() {
  if (!terminalEnabled) return;
  if (!SimTerminal) {
    if (!terminalLoading) terminalLoading = import('./terminal.js').then(async module => {
      await module.loadTerminalAssets(); SimTerminal = module.SimTerminal;
      terminalResizeObserver = new ResizeObserver(() => { if (termOpen) activeTerminal()?.terminal.fit(); });
      terminalResizeObserver.observe(termPanesEl);
    }).catch(error => { terminalLoading = null; console.warn('Simwisp terminal:', error.message); terminalButton.title = 'Terminal could not load; click to retry'; throw error; });
    try { await terminalLoading; } catch { return; }
  }
  if (!terminalEnabled) return;
  termOpen = true; termPanelEl.hidden = false; termPanelEl.inert = false; termPanelEl.classList.remove('closed');
  content.classList.add('terminal-open'); content.classList.toggle('pinned-right', termPinned);
  terminalButton.classList.add('active'); terminalButton.setAttribute('aria-expanded', 'true');
  if (!termTabs.length) {
    let saved = [];
    try { saved = JSON.parse(sessionStorage.getItem(TERM_TABS_KEY)) || []; } catch {}
    if (saved.length) saved.slice(0, 8).forEach(addTermTab); else addTermTab();
  }
  activeTerminal()?.terminal.reconnect();
  updateViewportVars(); updateStreamVisibility(); closeMobileSidebar();
  activeTerminal()?.terminal.fit(); activeTerminal()?.terminal.focus(); saveSession();
}
function closeTerminal() {
  termOpen = false; termPanelEl.classList.add('closed'); termPanelEl.hidden = true; termPanelEl.inert = true;
  content.classList.remove('terminal-open'); content.classList.remove('pinned-right');
  terminalButton.classList.remove('active'); terminalButton.setAttribute('aria-expanded', 'false');
  updateViewportVars(); updateStreamVisibility(); saveSession();
}
terminalButton.addEventListener('click', () => { if (termOpen) closeTerminal(); else openTerminal(); });
$('btn-close-term').addEventListener('click', closeTerminal);
$('btn-add-term').addEventListener('click', () => addTermTab());
$('btn-pin-term').addEventListener('click', () => {
  termPinned = !termPinned; content.classList.toggle('pinned-right', termPinned);
  $('btn-pin-term').classList.toggle('active', termPinned); $('btn-pin-term').setAttribute('aria-pressed', String(termPinned));
  termPanelEl.style.height = ''; termPanelEl.style.width = ''; updateViewportVars(); saveSession();
});
function changeTerminalFont(delta) {
  termFontSize = Math.min(24, Math.max(9, termFontSize + delta)); $('font-size-val').textContent = termFontSize;
  termTabs.forEach(tab => tab.terminal.setFontSize(termFontSize));
  try { localStorage.setItem('termFontSize', termFontSize); } catch {}
}
$('btn-font-dec').addEventListener('click', () => changeTerminalFont(-1));
$('btn-font-inc').addEventListener('click', () => changeTerminalFont(1));
let termDrag = null;
termResizeHandle.addEventListener('pointerdown', event => {
  event.preventDefault(); termResizeHandle.setPointerCapture(event.pointerId);
  termDrag = { x: event.clientX, y: event.clientY, width: termPanelEl.offsetWidth, height: termPanelEl.offsetHeight };
});
termResizeHandle.addEventListener('pointermove', event => {
  if (!termDrag) return;
  if (termPinned) termPanelEl.style.width = Math.max(240, Math.min(content.clientWidth - 220, termDrag.width + termDrag.x - event.clientX)) + 'px';
  else termPanelEl.style.height = Math.max(120, Math.min(content.clientHeight - 140, termDrag.height + termDrag.y - event.clientY)) + 'px';
  updateViewportVars();
});
['pointerup', 'pointercancel', 'lostpointercapture'].forEach(name => termResizeHandle.addEventListener(name, () => { termDrag = null; }));
window.addEventListener('pagehide', () => { simPanels.forEach(p => { p.accessibility?.setOpen(false); p.stream?.destroy(); }); persistTerminalTabs(); termTabs.forEach(tab => tab.terminal.destroy({ terminate: false })); });
window.addEventListener('pageshow', e => { if (e.persisted) location.reload(); });

// ── Session persistence ───────────────────────────────────────────────────────
const _SESSION_KEY = 'simwispSession';

function saveSession() {
  try {
    localStorage.setItem(_SESSION_KEY, JSON.stringify({
      openUdids:   [...simPanels.keys()],
      termOpen, termPinned,
      fps:         parseInt(fpsSlider.value),
      quality:     parseInt(qualSlider.value),
      dataSaver:   dsBtn.classList.contains('active'),
    }));
  } catch { /* storage full or private mode */ }
}

function restoreSession() {
  try { return JSON.parse(localStorage.getItem(_SESSION_KEY)); } catch { return null; }
}

// ── Startup ───────────────────────────────────────────────────────────────────
const urlUdid = new URLSearchParams(location.search).get('view');
loadSims().then(() => {
  if (urlUdid) {
    const sim = allSims.find(s => s.id === urlUdid);
    if (sim) addSimPanel(sim.id, sim.name, sim.width, sim.height, sim.platform);
    return;
  }

  const s = restoreSession();
  if (!s) return;

  // Restore sliders before opening panels so streams pick up the right values
  if (s.fps)     { fpsSlider.value  = s.fps;     fpsVal.textContent  = s.fps; }
  if (s.quality) { qualSlider.value = s.quality;  qualVal.textContent = s.quality; }
  if (s.dataSaver) {
    dsBtn.classList.add('active');
    dsBtn.setAttribute('aria-pressed', 'true');
  }

  // Restore open simulator panels (only those still running). Phones only get one.
  const restoreUdids = isMobileViewport() ? (s.openUdids || []).slice(0, 1) : (s.openUdids || []);
  for (const udid of restoreUdids) {
    const sim = allSims.find(sim => sim.id === udid);
    if (sim) addSimPanel(sim.id, sim.name, sim.width, sim.height, sim.platform);
  }
  termPinned = !!s.termPinned;
  $('btn-pin-term').classList.toggle('active', termPinned);
  if (s.termOpen && terminalEnabled) openTerminal();
});
