import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

// Entire production stream + launch/panel/list functions. Transport, decoder,
// canvas and DOM are inert doubles; no real socket/device or live acceptance.
const app = fs.readFileSync('Resources/Web/js/app.js', 'utf8');
const stream = fs.readFileSync('Resources/Web/js/stream.js', 'utf8');
function section(first, next) {
  const a = app.indexOf(first), b = app.indexOf(next, a);
  assert(a >= 0 && b > a, first); return app.slice(a, b);
}
const production = [
  section('async function loadSims(', '// ── Add-simulator'),
  section('function renderAddList(', "addSimBtn.addEventListener('click', openAddPopover);"),
  section('function refreshDevicesAfterHeadlessFirstFrame(', 'function deviceActionMessage('),
  section('function renderDeviceList(', '// ── Sim panel management'),
  section('function addSimPanel(', '// Corner radius'),
  section('function updatePanelStatus(', 'function setPanelProgress('),
].join('\n');
const checks = [];
function check(name, value) { checks.push({ name, passed: !!value }); assert(value, name); }
const flush = async () => { for (let n = 0; n < 5; n++) await Promise.resolve(); };
class Element {
  constructor() {
    this.children = []; this.style = {}; this.dataset = {}; this.selectors = new Map(); this.tokens = new Set();
    this.classList = { add: (...s) => s.forEach(t => this.tokens.add(t)), remove: (...s) => s.forEach(t => this.tokens.delete(t)), contains: s => this.tokens.has(s) };
    this.innerHTML = ''; this.textContent = ''; this.width = 400; this.height = 800;
  }
  set className(s) { this.tokens = new Set(s.split(/\s+/)); }
  get className() { return [...this.tokens].join(' '); }
  append(...nodes) { this.children.push(...nodes); }
  appendChild(n) { this.append(n); return n; }
  querySelector(s) { if (!this.selectors.has(s)) this.selectors.set(s, new Element()); return this.selectors.get(s); }
  querySelectorAll() { return []; }
  setAttribute() {} addEventListener() {} removeEventListener() {} remove() {}
}
function fixture({ cancel = false, fail = false } = {}) {
  const sockets = [], decoders = [], timers = new Map(), rafs = new Map(), nodes = new Map(), events = [];
  let seq = 0, drawFailure = false, draws = 0;
  const node = id => { if (!nodes.has(id)) nodes.set(id, new Element()); return nodes.get(id); };
  class Socket {
    static OPEN = 1; static CONNECTING = 0;
    constructor(url) { this.url = url; this.readyState = 0; this.sent = []; sockets.push(this); }
    send(s) { this.sent.push(JSON.parse(s)); }
    close() { this.readyState = 3; }
    open() { this.readyState = 1; this.onopen?.(); }
    message(data) { this.onmessage?.({ data: typeof data === 'object' && !(data instanceof ArrayBuffer) ? JSON.stringify(data) : data }); }
  }
  class Decoder {
    static async isConfigSupported() { return { supported: true }; }
    constructor(callbacks) { this.output = callbacks.output; this.error = callbacks.error; this.state = 'unconfigured'; this.chunks = []; this.decodeQueueSize = 0; decoders.push(this); }
    configure() { this.state = 'configured'; }
    decode(chunk) { this.chunks.push(chunk); }
    close() { this.state = 'closed'; }
  }
  const ctx = {
    console: { warn: () => {} }, ArrayBuffer, DataView, Uint8Array, Map, Set, Promise, Error, Date,
    atob: s => Buffer.from(s, 'base64').toString('binary'), performance: { now: () => 1000 }, isSecureContext: true,
    location: { protocol: 'https:', host: 'inert.invalid' }, WebSocket: Socket, VideoDecoder: Decoder,
    EncodedVideoChunk: class { constructor(v) { Object.assign(this, v); } },
    setTimeout: (f, ms) => { timers.set(++seq, { f, ms }); return seq; },
    clearTimeout: id => timers.delete(id), setInterval: (f, ms) => { timers.set(++seq, { f, ms, interval: true }); return seq; }, clearInterval: id => timers.delete(id),
    requestAnimationFrame: f => { rafs.set(++seq, f); return seq; }, cancelAnimationFrame: id => rafs.delete(id),
    document: { hidden: false, createElement: () => { const el = new Element(); el.getContext = () => ({ drawImage() { if (drawFailure) throw Error('canvas draw failed'); draws++; } }); return el; } },
    window: { confirm: () => !cancel }, $: node, esc: s => String(s), simIcon: () => 'icon',
    simPanels: new Map(), allSims: [{ id: 'old', name: 'Old iPhone', platform: 'ios', width: 400, height: 800 }],
    _bootingIds: new Set(), _pendingBoots: new Map(), _bootError: '', _addDevices: [{ id: 'new', name: 'New iPhone', platform: 'ios' }],
    addSearch: { value: '' }, addList: node('add-list'), deviceList: node('device-list'), projFilter: { checked: false }, projFilterWrap: node('filter'),
    stoppingIds: new Set(), hasAdb: true, canStopDevices: true, canLaunchHeadless: true, headlessRunIcon: 'headless',
    simsLoadVersion: 0, deviceAction: null, focusedUdid: null, termOpen: false,
    updateKeyboardPlaceholder() {}, closeAddPopover() {}, closeMobileSidebar() {}, updateModeBadge() {}, renderPermsWidget() {}, terminalCapability() {},
    _readSimsCache: () => ctx.cache ?? null, _writeSimsCache() {}, reconcileDeviceAction: async () => {},
    fetchIOSWindows: async () => { events.push('window-query'); return { windowed: true }; },
    bootSim: async () => { events.push('boot'); if (fail) throw Error('boot refused'); }, bootAvd: async () => { throw Error('unexpected Android boot'); },
    fetchSims: async () => { events.push('inventory'); return [{ id: 'new', name: 'New iPhone', platform: 'ios', width: 400, height: 800, headless: true }]; },
    fetchInfo: async () => ({ has_adb: true, features: { device_stop: true, headless_launch: true } }),
    deviceActionMessage: () => {}, synchronizePanelMode: () => {}, synchronizePanelModes: () => {},
    createPill: () => new Element(), simPanelsEl: node('panels'), emptyState: node('empty'), kbdBar: node('kbd'),
    IOSCapture: class { constructor(_el, _name, _id, _change, { headless }) { this.choices = { capture: headless ? 'native' : 'quartz', input: headless ? 'native' : 'quartz' }; } destroy() {} receive() {} },
    rebuildDividers() {}, ResizeObserver: class { observe() {} disconnect() {} }, fpsSlider: { value: '60' }, qualSlider: { value: '20' }, dsBtn: node('ds'),
    updateStreamVisibility() {}, setFocusedPanel: id => { ctx.focusedUdid = id; }, saveSession() {}, closeDeviceConsoles() {},
    metroDiscovery: { capability() {}, setActive() {} }, isMobileViewport: () => false,
  };
  vm.createContext(ctx);
  vm.runInContext(stream.replace('export class SimStream', 'class SimStream') + '\nthis.SimStream=SimStream;\n' + production, ctx);
  const frame = timestamp => ({ timestamp, closed: false, close() { this.closed = true; } });
  const packet = (timestamp = 100, epoch = 1) => { const p = new ArrayBuffer(25), v = new DataView(p); v.setUint32(0, 0x53575631); v.setUint8(4, 1); v.setUint32(8, epoch); v.setUint32(12, timestamp); v.setBigUint64(16, BigInt(timestamp)); return p; };
  const config = epoch => ({ type: 'video_config', epoch, codec: 'avc1.42e01e', description: 'AQ==', width: 400, height: 800, coded_width: 400, coded_height: 800 });
  const f = {
    ctx, events, sockets, decoders, timers, rafs, node,
    run: () => ctx.handleAddBoot('new', 'New iPhone', 'ios', 400, 800, 'headless'),
    pending: () => ctx._bootingIds.has('new') && ctx._pendingBoots.get('new')?.awaitingFirstFrame === true,
    refreshes: () => events.filter(s => s === 'inventory').length,
    async prepare(epoch = 1) { const ws = sockets.at(-1); ws.open(); ws.message(config(epoch)); await flush(); return ws; },
    packet, frame, config, get draws() { return draws; }, set drawFailure(v) { drawFailure = v; },
    paint() { const callbacks = [...rafs.values()]; rafs.clear(); for (const fn of callbacks) fn(); },
    async video(timestamp = 100, epoch = 1) { sockets.at(-1).message(packet(timestamp, epoch)); decoders.at(-1).output(frame(timestamp)); f.paint(); await flush(); },
    cleanup() { for (const p of ctx.simPanels.values()) p.stream.destroy(); },
  };
  return f;
}
async function scenario(fn, options) { const f = fixture(options); try { await fn(f); } finally { f.cleanup(); } }
let failure = false;
try {
  await scenario(async f => {
    await f.run();
    check('Headless stays Booting after boot acknowledgement with zero actual frames', f.pending());
    if (process.argv.includes('--red')) return;
    check('Boot acknowledgement never manufactures a running device record', !f.ctx.allSims.some(s => s.id === 'new'));
    check('Sidebar retains Headless Booting row until video', /Headless · Booting…/.test(f.ctx.deviceList.innerHTML) && !/data-udid="new"/.test(f.ctx.deviceList.innerHTML));
    check('Launch buttons remain disabled while waiting for video', /add-boot-btn booting/.test(f.ctx.addList.innerHTML));
    check('Pending launch still forces session-only Native without a fake device record', f.ctx.simPanels.get('new').backends.choices.capture === 'native' && f.ctx.simPanels.get('new').headless);
    check('No pre-video inventory fetch or app boot-discovery poll', f.refreshes() === 0 && ![...f.timers.values()].some(t => t.interval && t.ms === 2000));
    await f.run(); check('Duplicate launch stays blocked before actual frames', f.events.filter(e => e === 'boot').length === 1);
    const ws = await f.prepare();
    check('WebSocket open and video configuration do not complete Booting', f.pending() && f.refreshes() === 0 && f.draws === 0);
    check('Connected headless panel is not labeled Ready before video', f.ctx.simPanels.get('new').statusEl.textContent === 'Booting…');
    for (const type of ['input_capabilities', 'frame_heartbeat', 'server_stats', 'ios_capture']) ws.message({ type, video_flow: 'paced-v1', headless: true });
    check('Capabilities, heartbeats, stats and backend metadata are not video readiness', f.pending() && f.refreshes() === 0);
    for (const t of [...f.timers.values()]) if (!t.interval && t.ms === 4000) t.f();
    check('No-frame timeout cannot promote the device or refresh', f.pending() && f.refreshes() === 0);
    ws.message(f.packet());
    check('Encoded packet receipt and decode submission alone cannot complete Booting', f.pending() && f.refreshes() === 0 && f.decoders.at(-1).chunks.length === 1);
    const unmatched = f.frame(999); f.decoders.at(-1).output(unmatched);
    check('Unmatched decoder output is discarded without promoting UI', unmatched.closed && f.pending() && f.rafs.size === 0);
    f.decoders.at(-1).output(f.frame(100));
    check('Decoded frame queued before canvas draw still leaves Booting', f.pending() && f.refreshes() === 0 && f.draws === 0);
    f.paint(); await flush();
    check('First successful current-stream video draw clears pending launch exactly then', !f.ctx._bootingIds.has('new') && !f.ctx._pendingBoots.has('new') && f.draws === 1);
    check('First actual draw triggers exactly one device refresh', f.refreshes() === 1);
    check('Normal sidebar device replaces Booting only after actual video', /data-udid="new"/.test(f.ctx.deviceList.innerHTML) && !/Booting…/.test(f.ctx.deviceList.innerHTML));
    await f.video(101); check('Later video frames do not repeat device refresh', f.refreshes() === 1 && f.draws === 2);
  });
  if (!process.argv.includes('--red')) {
    await scenario(async f => { await f.run(); f.ctx.allSims.push({ id: 'new', name: 'New iPhone', platform: 'ios', headless: true }); f.ctx.renderDeviceList(); check('Cached or unrelated fresh discovery cannot bypass pending video gate', f.pending() && !/data-udid="new"/.test(f.ctx.deviceList.innerHTML) && /Booting…/.test(f.ctx.deviceList.innerHTML)); check('Pending discovered device is not counted as ready', String(f.node('device-count').textContent) === '1'); });
    await scenario(async f => { await f.run(); await f.prepare(); f.drawFailure = true; await f.video(); check('Canvas draw failure never clears Booting or refreshes', f.pending() && f.refreshes() === 0 && f.draws === 0); f.drawFailure = false; await f.prepare(2); await f.video(102, 2); check('First later successful recovered frame completes launch once', !f.pending() && f.refreshes() === 1 && f.draws === 1); });
    await scenario(async f => { await f.run(); await f.prepare(); const decoder = f.decoders.at(-1); f.sockets.at(-1).message(f.packet()); f.ctx.removeSimPanel('new'); check('Closing pending view clears only its transient Booting state without refresh', !f.ctx._pendingBoots.has('new') && !f.ctx._bootingIds.has('new') && f.refreshes() === 0); const late = f.frame(100); decoder.output(late); f.paint(); check('Late decoder output after view close cannot finish or refresh launch', late.closed && f.refreshes() === 0 && f.draws === 0); check('View close sends no simulator shutdown or second boot', f.events.filter(e => e === 'boot').length === 1); });
    await scenario(async f => { f.ctx.allSims.push({ id: 'new', name: 'New iPhone', platform: 'ios', headless: false }); f.ctx.addSimPanel('new', 'Old view', 400, 800, 'ios'); await f.prepare(); const old = f.ctx.simPanels.get('new'), decoder = f.decoders.at(-1); f.sockets.at(-1).message(f.packet()); decoder.output(f.frame(100)); await f.run(); check('New Headless launch replaces stale same-UUID stream instead of rearming it', f.ctx.simPanels.get('new') !== old && f.sockets.length === 2 && f.pending()); const late = f.frame(100); decoder.output(late); f.paint(); check('Old stream cannot satisfy the new launch video gate', late.closed && f.pending() && f.refreshes() === 0 && f.draws === 0); await f.prepare(); await f.video(); check('Only replacement stream video completes the pending new launch', !f.pending() && f.refreshes() === 1); });
    await scenario(async f => { await f.run(); check('Consent No leaves no launch, pending row, stream or refresh', f.events.filter(e => e === 'boot').length === 0 && !f.ctx._bootingIds.has('new') && f.ctx._pendingBoots.size === 0 && f.sockets.length === 0 && f.refreshes() === 0); }, { cancel: true });
    await scenario(async f => { await f.run(); check('Failed boot leaves no pending video or fabricated running device', !f.ctx._bootingIds.has('new') && f.ctx._pendingBoots.size === 0 && !f.ctx.allSims.some(s => s.id === 'new') && f.sockets.length === 0 && f.refreshes() === 0); }, { fail: true });
  }
} catch (error) { failure = true; console.error(error.message); }
const passed = !failure && checks.length > 0 && checks.every(c => c.passed);
fs.writeFileSync(process.argv[2] + '/boot-frame-state.json', JSON.stringify({ passed, checks, wholeProductionStream: true, productionLaunchPanelAndSidebar: true, inertDOMTransportDecoderCanvas: true, realCodecOrDeviceAcceptance: false, noAppBuildOrRestart: true }, null, 2) + '\n');
console.log(`Boot/frame UI regression checks: ${checks.length}, passed: ${passed}`);
process.exit(passed ? 0 : 1);
