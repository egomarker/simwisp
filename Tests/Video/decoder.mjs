import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const report = { checks: [], passed: false, syntheticDecoder: true, realBrowser: false, realInput: false };
const timers = new Map(), rafs = new Map(), trace = [], warnings = [], frames = [];
let timerID = 0, now = 0;
Object.defineProperty(globalThis, 'performance', { configurable: true, value: { now: () => now } });
globalThis.setTimeout = (fn, ms) => { const id = ++timerID; timers.set(id, { fn, at: now + ms, repeat: 0 }); return id; };
globalThis.setInterval = (fn, ms) => { const id = ++timerID; timers.set(id, { fn, at: now + ms, repeat: ms }); return id; };
globalThis.clearTimeout = globalThis.clearInterval = id => timers.delete(id);
globalThis.requestAnimationFrame = fn => { const id = ++timerID; rafs.set(id, fn); return id; };
globalThis.cancelAnimationFrame = id => rafs.delete(id);
function advance(ms) {
  const end = now + ms;
  for (;;) {
    const entry = [...timers.entries()].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
    if (!entry) break;
    const [id, t] = entry; now = t.at;
    if (t.repeat) t.at += t.repeat; else timers.delete(id);
    t.fn();
  }
  now = end;
}
function render() { const callbacks = [...rafs.values()]; rafs.clear(); callbacks.forEach(fn => fn(now)); }
globalThis.location = { protocol: 'https:', host: 'fixture.local:4141' };
globalThis.isSecureContext = true;
class WS {
  static OPEN = 1; static CONNECTING = 0; static all = [];
  constructor(url) { this.url = url; this.readyState = 0; this.messages = []; WS.all.push(this); }
  send(s) { const m = JSON.parse(s); this.messages.push(m); trace.push(m.type); }
  close() { this.readyState = 3; this.onclose?.(); }
  open() { this.readyState = 1; this.onopen?.(); }
  receive(data) { this.onmessage?.({ data }); }
}
class Decoder {
  static all = []; static supported = true; static probe = null; static retain = 0; static probes = 0; static growQueue = false;
  static isConfigSupported(config) { this.probes++; return this.probe ?? Promise.resolve({ supported: this.supported, config }); }
  constructor(options) {
    this.options = options; this.state = 'unconfigured'; this.decodeQueueSize = 0;
    this.chunks = []; this.retainCount = Decoder.retain; this.growQueue = Decoder.growQueue; Decoder.all.push(this);
  }
  configure(c) { this.config = c; this.state = 'configured'; }
  decode(c) {
    if (this.state !== 'configured') throw Error('closed decode');
    this.chunks.push(c); if (this.growQueue) this.decodeQueueSize++;
    if (this.retainCount > 0 && this.chunks.length > this.retainCount) this.deliver(this.chunks[this.chunks.length - this.retainCount - 1].timestamp);
  }
  close() { this.state = 'closed'; }
  deliver(timestamp) {
    const f = { timestamp, closed: false, close() { if (this.closed) throw Error('double close'); this.closed = true; trace.push('close'); } };
    frames.push(f); this.options.output(f); return f;
  }
  error() { this.options.error(Error('synthetic decode failure')); }
}
globalThis.WebSocket = WS; globalThis.VideoDecoder = Decoder;
globalThis.EncodedVideoChunk = class { constructor(v) { Object.assign(this, v); } };
const originalWarn = console.warn; console.warn = (...args) => warnings.push(args.map(String).join(' '));
const { SimStream } = await import(pathToFileURL(path.resolve('Resources/Web/js/stream.js')).href);
function check(name, ok) { report.checks.push({ name, passed: ok === true }); if (ok !== true) throw Error('FAIL ' + name); }
const flush = async () => { for (let n = 0; n < 8; n++) await Promise.resolve(); };
function start(options = {}) {
  const statuses = [], sizes = []; let first = 0;
  const canvas = { width: 405, height: 901, style: {}, draws: [], getContext() { return { drawImage(f, ...args) {
    if (canvas.failDraw) throw Error('synthetic draw failure');
    check('Only open VideoFrame is drawn', !f.closed); canvas.lastDraw = args; canvas.draws.push(f.timestamp); trace.push('draw');
  } }; }, addEventListener() {}, getBoundingClientRect() { return { left: 0, top: 0, width: 405, height: 901 }; } };
  const stream = new SimStream('emulator-fixture', canvas, { ...options, onStatus: (s, m) => statuses.push([s, m]), onFirstFrame: () => first++, onOrientationChange: (w, h) => sizes.push([w, h]) });
  return { stream, canvas, ws: WS.all.at(-1), statuses, sizes, first: () => first };
}
const cfg = (epoch = 1) => JSON.stringify({ type: 'video_config', epoch, codec: 'avc1.42001E', description: Buffer.from([1, 66, 0, 30, 255, 225, 0]).toString('base64'), width: 405, height: 901, coded_width: 406, coded_height: 902 });
function packet({ epoch = 1, id = 1, time = 16667, key = true, magic = 0x53575631, size = 28 } = {}) {
  const b = new ArrayBuffer(size), v = new DataView(b); v.setUint32(0, magic); v.setUint8(4, key ? 1 : 0);
  v.setUint32(8, epoch); v.setUint32(12, id); v.setBigUint64(16, BigInt(time)); return b;
}
const requests = t => t.ws.messages.filter(m => m.type === 'video_keyframe');
const feedback = t => t.ws.messages.filter(m => m.type === 'video_feedback');
function destroy(t) { t.stream.destroy(); check('Destruction removes timers and retained render output', timers.size === 0 && rafs.size === 0); }
try {
  let t = start(); t.ws.open();
  check('Only WSS URL constructed', t.ws.url.startsWith('wss://'));
  check('Readiness negotiates independent pacing', t.ws.messages.at(-1).type === 'video_ready' && t.ws.messages.at(-1).flow === 'paced-v1');
  t.stream.updateSettings({ quality: 45, accessibility_enabled: true, accessibility_subscription: 9 });
  t.ws.receive(JSON.stringify({ type: 'input_capabilities', live_touch: true, video_flow: 'paced-v1' }));
  check('Delayed native binding replays current settings', t.ws.messages.at(-2).quality === 45 && t.ws.messages.at(-2).accessibility_subscription === 9);
  t.ws.receive(cfg()); t.ws.receive(packet()); await flush(); let d = Decoder.all.at(-1);
  check('First key submitted without any per-frame ACK', d.chunks.length === 1 && !t.ws.messages.some(m => m.type === 'frame_ack'));
  check('Decoder keeps AVCC and latency hint', d.config.description instanceof Uint8Array && d.config.optimizeForLatency === true);
  const f = d.deliver(16667);
  check('Output is retained only until animation frame', !f.closed && t.canvas.draws.length === 0 && rafs.size === 1);
  render(); check('Rendered frame is closed', f.closed);
  check('Odd visible dimensions exclude padding', t.canvas.width === 405 && t.canvas.height === 901 && t.canvas.lastDraw[2] === 405 && t.canvas.lastDraw[3] === 901);
  check('First-frame hook follows drawing', t.first() === 1);
  t.ws.receive(packet({ id: 2, time: 33334, key: false })); t.ws.receive(packet({ id: 3, time: 50001, key: false })); await flush();
  check('Dependent frames submitted independently', d.chunks.length === 3);
  const older = d.deliver(33334), latest = d.deliver(50001);
  check('Superseded decoded output closes immediately', older.closed && !latest.closed && rafs.size === 1);
  render(); check('Only newest decoded output drawn', latest.closed && t.canvas.draws.join(',') === '16667,50001');
  const duplicate = d.deliver(33334); check('Unmatched late output closes without drawing', duplicate.closed && t.canvas.draws.length === 2);
  advance(249); check('No per-packet or premature feedback', feedback(t).length === 0);
  advance(1); check('Cumulative feedback sent at250ms', feedback(t).length === 1 && feedback(t)[0].epoch === 1 && feedback(t)[0].frame_id === 3 && feedback(t)[0].pending_frames === 0);
  const initialTiming = feedback(t)[0].client_timing;
  check('Feedback includes cumulative output/render/rAF and latest-only drop counters', initialTiming.decoded_outputs === 4 && initialTiming.rendered_frames === 2 && initialTiming.raf_callbacks === 2 && initialTiming.dropped_frames === 1 && initialTiming.latest_frame_drops === 1);
  check('Feedback includes bounded event ages before first rate sample', initialTiming.output_age_ms === 250 && initialTiming.render_age_ms === 250 && initialTiming.raf_age_ms === 250);
  advance(1000);
  const sampledTiming = feedback(t).at(-1).client_timing;
  check('One-second feedback sample reports decoded/render/drop/rAF cadence', sampledTiming.sample_ms === 1000 && sampledTiming.decoded_output_fps === 4 && sampledTiming.rendered_fps === 2 && sampledTiming.dropped_fps === 1 && sampledTiming.latest_drop_fps === 1 && sampledTiming.raf_fps === 2);
  check('One-second feedback sample reports receive/output/draw client latency', sampledTiming.receive_to_output_ms === 0 && sampledTiming.output_to_render_ms === 0 && sampledTiming.receive_to_render_ms === 0);
  const chunks = d.chunks.length; t.ws.receive(packet({ epoch: 99, id: 200 })); await flush();
  check('Wrong-epoch packet never enters current decoder', d.chunks.length === chunks && requests(t).length === 0);
  t.stream.updateSettings({ stream_paused: true }); check('Pause closes decoder immediately', d.state === 'closed');
  t.ws.receive(packet({ id: 4, time: 66668 })); advance(250);
  check('Paused receipt can retire transport bytes without decode', feedback(t).at(-1).frame_id === 4 && feedback(t).at(-1).pending_frames === 0 && d.chunks.length === chunks);
  t.stream.updateSettings({ stream_paused: false }); t.ws.receive(cfg(2)); t.ws.receive(packet({ epoch: 2, id: 5 })); await flush();
  const replacement = Decoder.all.at(-1), beforeDraws = t.canvas.draws.length;
  const stale = d.deliver(16667); render(); check('Stale decoder cannot draw replacement timestamp', stale.closed && t.canvas.draws.length === beforeDraws);
  const held = replacement.deliver(16667); destroy(t); check('Destroy closes frame waiting for rendering', held.closed);
  const late = replacement.deliver(16667); check('Destroyed decoder output always closes', late.closed);

  // Multiple packets can arrive while asynchronous support probing is pending.
  let resolve; Decoder.probe = new Promise(r => resolve = r);
  t = start(); t.ws.open(); t.ws.receive(cfg()); t.ws.receive(packet());
  t.ws.receive(packet({ id: 2, time: 33334, key: false })); t.ws.receive(packet({ id: 3, time: 50001, key: false }));
  check('Initial probe can retain bounded key+delta sequence', requests(t).length === 0);
  resolve({ supported: true }); await flush(); d = Decoder.all.at(-1);
  check('Probe preserves initial key then delta decode order', d.chunks.map(c => c.type).join(',') === 'key,delta,delta');
  destroy(t); Decoder.probe = null;
  Decoder.probe = new Promise(r => resolve = r); t = start(); t.ws.open(); t.ws.receive(cfg()); t.ws.receive(packet());
  const decoderCount = Decoder.all.length; destroy(t); resolve({ supported: true }); await flush();
  check('Destroyed capability probe cannot create decoder', Decoder.all.length === decoderCount); Decoder.probe = null;

  // A duplicate IDR description while probing does not invalidate key+P inputs.
  Decoder.probe = new Promise(r => resolve = r); t = start(); t.ws.open();
  const probes = Decoder.probes;
  t.ws.receive(cfg()); t.ws.receive(packet()); t.ws.receive(cfg()); t.ws.receive(packet({ id: 2, time: 33334, key: false }));
  check('Repeated identical config starts only one support probe', Decoder.probes === probes + 1);
  resolve({ supported: true }); await flush(); d = Decoder.all.at(-1);
  check('Duplicate config preserves pending key and dependent delta', d.chunks.map(c => c.type).join(',') === 'key,delta'); destroy(t); Decoder.probe = null;

  Decoder.probe = new Promise(r => resolve = r); const oldResolve = resolve;
  t = start(); t.ws.open(); t.ws.receive(cfg()); t.ws.receive(packet());
  Decoder.probe = new Promise(r => resolve = r); t.ws.receive(cfg(2)); t.ws.receive(packet({ epoch: 2, id: 9 }));
  resolve({ supported: true }); await flush(); d = Decoder.all.at(-1); const countAfterReplacement = Decoder.all.length;
  oldResolve({ supported: true }); await flush();
  check('Late support probe cannot submit old-epoch packet or create decoder', Decoder.all.length === countAfterReplacement && d.chunks.length === 1);
  destroy(t); Decoder.probe = null;

  Decoder.growQueue = true; Decoder.probe = new Promise(r => resolve = r);
  t = start(); t.ws.open(); t.ws.receive(cfg());
  for (let i = 1; i <= 30; i++) t.ws.receive(packet({ id: i, time: i * 16667, key: i === 1 }));
  resolve({ supported: true }); await flush(); d = Decoder.all.at(-1);
  check('Support-probe drain enforces decoder queue limit mid-burst', d.chunks.length === 16 && d.state === 'closed' && requests(t).length === 1 && requests(t)[0].overloaded === true);
  destroy(t); Decoder.probe = null; Decoder.growQueue = false;

  t = start(); t.ws.open(); t.ws.receive(cfg()); await flush(); d = Decoder.all.at(-1);
  t.ws.receive(packet()); t.ws.receive(packet({ id: 2, time: 33334, key: false }));
  const newestFirst = d.deliver(33334), latePending = d.deliver(16667);
  check('Older pending output cannot replace a newer retained frame', latePending.closed && !newestFirst.closed);
  render(); check('Out-of-order output never regresses presentation timestamp', t.canvas.draws.join(',') === '33334' && newestFirst.closed); destroy(t);

  // Safari-like output buffering cannot stall independent input submission.
  Decoder.retain = 5; t = start(); t.ws.open(); t.ws.receive(cfg()); await flush(); d = Decoder.all.at(-1);
  for (let i = 1; i <= 35; i++) { t.ws.receive(packet({ id: i, time: i * 16667, key: i === 1 })); await flush(); render(); advance(16); }
  check('Retaining five outputs does not reconfigure decoder', d.state === 'configured' && d.chunks.length === 35 && requests(t).length === 0);
  check('Buffered decoder draws exactly thirty outputs', t.canvas.draws.length === 30);
  check('Receiver feedback is periodic, not per frame', feedback(t).length === 2 && !t.ws.messages.some(m => m.type === 'frame_ack'));
  destroy(t); Decoder.retain = 0;

  t = start(); t.ws.open(); t.ws.receive(cfg()); await flush(); d = Decoder.all.at(-1);
  for (let i = 1; i <= 49; i++) { t.ws.receive(packet({ id: i, time: i * 16667, key: i === 1 })); await flush(); }
  check('Forty-nine packets hit finite pending bound', d.chunks.length === 48 && d.state === 'closed' && requests(t).length === 1 && requests(t)[0].overloaded === true);
  for (let i = 50; i < 70; i++) { t.ws.receive(packet({ id: i, time: i * 16667, key: false })); }
  t.ws.receive(cfg()); await flush(); check('Old packets/IDRs cannot create recovery storm', requests(t).length === 1 && Decoder.all.at(-1) === d);
  t.ws.receive(cfg(2)); t.ws.receive(packet({ epoch: 2, id: 70 })); await flush();
  check('Fresh epoch restarts on keyframe', Decoder.all.at(-1).chunks.length === 1 && Decoder.all.at(-1).state === 'configured'); destroy(t);

  t = start(); t.ws.open(); t.ws.receive(cfg()); await flush(); d = Decoder.all.at(-1); d.decodeQueueSize = 16;
  t.ws.receive(packet()); await flush(); check('Sixteen-input queue triggers IDR recovery without submitting more', d.chunks.length === 0 && d.state === 'closed' && requests(t)[0].overloaded === true); destroy(t);
  t = start(); t.ws.open(); t.ws.receive(cfg()); await flush(); d = Decoder.all.at(-1);
  t.ws.receive(packet({ size: 5_000_000 })); await flush(); t.ws.receive(packet({ id: 2, time: 33334, key: false, size: 5_000_000 })); await flush();
  check('Pending byte budget bounds large initial probes/submissions', d.chunks.length === 1 && d.state === 'closed'); destroy(t);
  t = start(); t.ws.open(); t.ws.receive(cfg()); t.ws.receive(packet()); await flush(); d = Decoder.all.at(-1);
  t.ws.receive(packet()); check('Duplicate timestamp requests recovery', d.state === 'closed' && requests(t).length === 1); destroy(t);

  for (const options of [{ fps: 1 }, { data_saver: true }]) {
    t = start(options); t.ws.open(); t.ws.receive(cfg()); t.ws.receive(packet()); await flush(); d = Decoder.all.at(-1);
    for (let i = 0; i < 9; i++) { t.ws.receive(JSON.stringify({ type: 'frame_heartbeat' })); advance(250); }
    check('Elapsed output watchdog works at low FPS/Data saver despite heartbeats', d.state === 'closed' && requests(t).length === 1 && requests(t)[0].overloaded === true);
    destroy(t);
  }
  t = start({ data_saver: true }); t.ws.open(); t.ws.receive(cfg()); t.ws.receive(packet()); await flush(); d = Decoder.all.at(-1); d.deliver(16667); render();
  for (let i = 0; i < 40; i++) { t.ws.receive(JSON.stringify({ type: 'frame_heartbeat' })); advance(250); }
  check('Legitimate idle Data saver never requests recovery', d.state === 'configured' && requests(t).length === 0); destroy(t);

  t = start(); t.ws.open(); t.ws.receive(cfg()); t.ws.receive(packet()); await flush(); d = Decoder.all.at(-1); d.error();
  check('Decoder errors request exact current epoch', requests(t)[0].epoch === 1 && d.state === 'closed');
  const socketCount = WS.all.length; advance(3250); check('Unanswered keyframe recovery reconnects finitely', WS.all.length === socketCount + 1); destroy(t);
  t = start(); t.ws.open(); t.ws.receive(cfg()); t.ws.receive(packet()); await flush(); d = Decoder.all.at(-1); t.canvas.failDraw = true; const failed = d.deliver(16667); render();
  check('Drawing failure closes frame and recovers decoder', failed.closed && d.state === 'closed' && requests(t).length === 1); destroy(t);
  t = start(); t.ws.open(); t.ws.receive(packet({ magic: 123 })); check('Malformed header requests recovery', requests(t).length === 1); destroy(t);
  t = start(); t.ws.open(); t.ws.receive(cfg()); t.ws.receive(packet({ key: false })); await flush(); check('Missing initial key never submits dependent delta', Decoder.all.at(-1).state === 'closed'); destroy(t);
  t = start(); t.ws.open(); t.ws.receive(JSON.stringify({ ...JSON.parse(cfg()), description: '***' })); check('Malformed base64 invokes decoder recovery', requests(t).length === 1); destroy(t);
  t = start(); t.ws.open(); t.ws.receive(JSON.stringify({ type: 'input_capabilities', live_touch: true }));
  check('Outdated server protocol gives actionable unsupported status', t.statuses.at(-1)[0] === 'unsupported' && t.ws.readyState === 3 && timers.size === 0); destroy(t);

  Decoder.supported = false; t = start(); t.ws.open(); t.ws.receive(cfg()); await flush();
  check('Unsupported H264 closes socket and timers', t.statuses.at(-1)[0] === 'unsupported' && t.ws.readyState === 3 && timers.size === 0); destroy(t); Decoder.supported = true;
  const sockets = WS.all.length; globalThis.isSecureContext = false; t = start();
  check('Insecure context never opens socket', WS.all.length === sockets && t.statuses.at(-1)[0] === 'unsupported'); destroy(t); globalThis.isSecureContext = true;
  globalThis.VideoDecoder = undefined; t = start(); check('Missing WebCodecs actionable', t.statuses.at(-1)[0] === 'unsupported'); destroy(t); globalThis.VideoDecoder = Decoder;
  check('Every created decoder closed', Decoder.all.every(d => d.state === 'closed'));
  check('Every delivered VideoFrame closed exactly once', frames.every(f => f.closed));
  check('No streaming ACK emitted anywhere', WS.all.every(w => !w.messages.some(m => m.type === 'frame_ack')));
  report.passed = true; report.expectedRecoveryWarnings = warnings.length;
  console.log(report.checks.length + ' focused independent decoder/render/feedback checks passed');
} catch (e) { report.error = String(e); process.exitCode = 1; console.error(e); }
finally {
  console.warn = originalWarn;
  if (process.env.TEST_OUTPUT) { fs.mkdirSync(process.env.TEST_OUTPUT, { recursive: true }); fs.writeFileSync(path.join(process.env.TEST_OUTPUT, 'decoder-review.json'), JSON.stringify(report, null, 2) + '\n'); }
}
