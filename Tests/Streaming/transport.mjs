import fs from 'node:fs';
import path from 'node:path';
import tls from 'node:tls';
import crypto from 'node:crypto';

const root = process.argv[2], base = 'https://127.0.0.1:45151';
if (!root || process.platform !== 'darwin') throw Error('Run via the isolated macOS browser fixture');
const report = { passed: false, checks: [], nativeTLSTransport: true, realCapture: false, realInput: false, realNetworkDelay: false };
const owned = [], intervals = new Set(), delayed = new Set();
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const status = async () => (await (await fetch(base + '/fixture/status')).json()).sessions;
function check(name, value) { report.checks.push({ name, passed: value === true }); if (value !== true) throw Error('FAIL ' + name); }
async function wait(predicate, ms = 4500) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (await predicate()) return; await delay(30); }
  throw Error('Timed out waiting for fixture state');
}
function openStream(id) {
  const socket = tls.connect({ host: '127.0.0.1', port: 45151, servername: 'localhost', ca: fs.readFileSync(path.join(root, 'tls/root.pem')) });
  let buffer = Buffer.alloc(0), upgraded = false, readyResolve, readyReject;
  const c = { id, socket, packets: 0, latest: null, error: null, paused: false, ready: new Promise((resolve, reject) => { readyResolve = resolve; readyReject = reject; }) };
  owned.push(c);
  function send(value) {
    const data = Buffer.from(JSON.stringify(value)), mask = crypto.randomBytes(4);
    if (data.length >= 126) throw Error('Fixture client messages must remain small');
    const head = Buffer.from([0x81, 0x80 | data.length]);
    const encoded = Buffer.from(data); for (let n = 0; n < data.length; n++) encoded[n] ^= mask[n % 4];
    if (!socket.destroyed) socket.write(Buffer.concat([head, mask, encoded]));
  }
  c.send = send;
  socket.once('secureConnect', () => socket.write(`GET /ws/${id} HTTP/1.1\r\nHost: 127.0.0.1:45151\r\nOrigin: ${base}\r\nCookie: fixture=paired\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ${crypto.randomBytes(16).toString('base64')}\r\n\r\n`));
  socket.on('error', error => { c.error = error.message; readyReject(error); });
  socket.on('data', data => {
    try {
      buffer = Buffer.concat([buffer, data]);
      if (!upgraded) {
        const end = buffer.indexOf('\r\n\r\n'); if (end < 0) return;
        if (!buffer.subarray(0, end).toString().startsWith('HTTP/1.1 101')) throw Error('Fixture WSS upgrade refused');
        upgraded = true; buffer = buffer.subarray(end + 4);
      }
      while (buffer.length >= 2) {
        const opcode = buffer[0] & 15; let length = buffer[1] & 127, offset = 2;
        if (buffer[1] & 128) throw Error('Unexpected masked server frame');
        if (length === 126) { if (buffer.length < 4) return; length = buffer.readUInt16BE(2); offset = 4; }
        else if (length === 127) { if (buffer.length < 10) return; length = Number(buffer.readBigUInt64BE(2)); offset = 10; }
        if (!Number.isSafeInteger(length) || length > 16_777_216) throw Error('Unbounded fixture frame');
        if (buffer.length < offset + length) return;
        const payload = buffer.subarray(offset, offset + length); buffer = buffer.subarray(offset + length);
        if (opcode === 1) {
          const m = JSON.parse(payload.toString());
          if (m.type === 'input_capabilities') {
            if (m.video_flow !== 'paced-v1') throw Error('Missing pacing negotiation');
            send({ type: 'video_ready', flow: 'paced-v1' });
          }
        } else if (opcode === 2 && payload.length >= 25 && payload.readUInt32BE(0) === 0x53575631) {
          c.packets++; c.latest = { epoch: payload.readUInt32BE(8), id: payload.readUInt32BE(12) }; readyResolve();
        }
      }
    } catch (error) { c.error = error.message; readyReject(error); socket.destroy(); }
  });
  return c;
}
try {
  const paced = openStream('emulator-wire-paced');
  const interval = setInterval(() => {
    if (!paced.latest) return;
    const value = { type: 'video_feedback', epoch: paced.latest.epoch, frame_id: paced.latest.id, pending_frames: 0, decode_queue: 0, oldest_pending_ms: 0 };
    const timer = setTimeout(() => { delayed.delete(timer); paced.send(value); }, 400); delayed.add(timer);
  }, 250); intervals.add(interval);
  await Promise.race([paced.ready, delay(4000).then(() => { throw Error('Paced fixture did not start'); })]);
  await delay(900); const before = paced.packets; await delay(1000);
  const received = paced.packets - before, view = (await status()).find(s => s.id === paced.id);
  report.delayedFeedback = { delayMS: 400, packetsInOneSecond: received, unreceivedFrames: view?.unreceived_frames, unreceivedBytes: view?.unreceived_bytes };
  check('TLS stream progresses above45fps despite400ms delayed cumulative feedback', received >= 45 && received <= 65 && !paced.error);
  check('Real transport debt remains bounded under delayed telemetry', view.unreceived_frames <= 120 && view.unreceived_bytes <= 1_048_576 && view.feedbacks > 0);
  paced.send({ type: 'home' });
  await wait(async () => (await status()).find(s => s.id === paced.id)?.last_inputs.at(-1)?.type === 'home');
  check('Inert input routing completes independently of delayed video receipts', true);
  clearInterval(interval); intervals.delete(interval); for (const timer of delayed) clearTimeout(timer); delayed.clear();
  paced.socket.destroy(); await wait(async () => !(await status()).some(s => s.id === paced.id));

  const silent = openStream('emulator-wire-silent');
  await Promise.race([silent.ready, delay(4000).then(() => { throw Error('Silent fixture did not start'); })]);
  await delay(2300); const silentView = (await status()).find(s => s.id === silent.id);
  report.noFeedback = { frames: silentView?.frames, unreceivedFrames: silentView?.unreceived_frames, unreceivedBytes: silentView?.unreceived_bytes };
  check('Missing feedback stops at finite frame/byte budget, not one frame', silentView && silentView.frames > 1 && silentView.frames <= 120 && silentView.unreceived_frames <= 120 && silentView.unreceived_bytes <= 1_048_576);
  await wait(async () => !(await status()).some(s => s.id === silent.id), 2000);
  check('Missing cumulative receipt closes connection after finite timeout', true); silent.socket.destroy();

  const blocked = openStream('emulator-wire-blocked');
  await Promise.race([blocked.ready, delay(4000).then(() => { throw Error('Blocked fixture did not start'); })]);
  blocked.socket.pause(); blocked.paused = true; await delay(1800);
  const blockedView = (await status()).find(s => s.id === blocked.id);
  report.stoppedReading = { socketReadPaused: true, frames: blockedView?.frames, unreceivedFrames: blockedView?.unreceived_frames, unreceivedBytes: blockedView?.unreceived_bytes };
  check('Stopped-reading TLS endpoint cannot create unbounded video debt', blockedView && blockedView.frames > 1 && blockedView.unreceived_frames <= 120 && blockedView.unreceived_bytes <= 1_048_576);
  await wait(async () => !(await status()).some(s => s.id === blocked.id), 2500);
  check('Stopped-reading endpoint has finite native lifecycle', true); blocked.socket.destroy();
  check('All owned transport sessions removed', (await status()).every(s => !owned.some(c => c.id === s.id)));
  report.passed = true; console.log(report.checks.length + ' native TLS streaming/backpressure checks passed');
} catch (error) { report.error = String(error); console.error(error); process.exitCode = 1; }
finally {
  for (const id of intervals) clearInterval(id); for (const id of delayed) clearTimeout(id);
  for (const c of owned) c.socket.destroy();
  fs.writeFileSync(path.join(root, 'transport-review.json'), JSON.stringify(report, null, 2) + '\n');
}
