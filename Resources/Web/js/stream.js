const CONNECT_TIMEOUT = 5000;
const RECONNECT_DELAY = 2000;
const NO_FRAME_WARN   = 4000;
const WATCHDOG_POLL   = 3000;
const WATCHDOG_STALE  = 16000;
const DRAG_THRESHOLD  = 0.015;
// Protect against hung decoders while allowing implementations to buffer output.
const MAX_PENDING_FRAMES = 48;
const MAX_DECODE_QUEUE = 16;
const MAX_PENDING_BYTES = 8_388_608;
const FEEDBACK_INTERVAL = 250;
const OUTPUT_STALE = 2000;
const RECOVERY_TIMEOUT = 3000;

export class SimStream {
  #liveTouch = false;
  #twoFinger = false;
  #udid; #canvas; #ctx;
  #ws = null; #connectTimer = null; #reconnectTimer = null; #watchdog = null;
  #lastMessageAt = 0; #firstFrame = false; #captureUnavailable = false;
  #decoder = null; #decoderToken = 0; #videoConfig = null; #configuration = null;
  #pendingFrames = new Map(); #pendingBytes = 0; #needsKeyframe = true; #noFrameTimer = null; #destroyed = false;
  #feedbackTimer = null; #receivedEpoch = null; #receivedID = null;
  #awaitingRecovery = false; #recoveryEpoch = null; #recoveryAt = 0;
  #latestFrame = null; #renderRAF = 0; #lastRenderedTimestamp = -1;
  #portraitW; #portraitH; #isLandscape = false;
  // Emulator scrcpy's unscaled native budget must survive scaled/headless reconnects.
  #scrcpyBaseSize = null; #effectiveCapture = null;
  #onStatus; #onFirstFrame; #onOrientationChange; #onRotateStart; #onRotateEnd;
  #onStats; #onAccessibility; #onStopped; #onBackends; #cancelPointer = () => {}; #statsTimer = null;
  #stats = { frames: 0, bytes: 0, dropped: 0, lastFrames: 0, lastBytes: 0, lastAt: 0, fps: 0, bps: 0, avgFrame: 0 };
  #serverStats = { fps: null, sentFps: null, quality: null };

  constructor(
    udid,
    canvas,
    {
      fps = 60,
      quality = 20,
      data_saver = false,
      backends, onBackends,
      onStatus,
      onFirstFrame,
      onOrientationChange,
      onRotateStart,
      onRotateEnd,
      onStats,
      onAccessibility,
      onStopped,
    } = {}
  ) {
    this.#udid = udid;
    this.#canvas = canvas;
    this.#ctx = canvas.getContext('2d', { alpha: false });
    this.#portraitW = canvas.width;
    this.#portraitH = canvas.height;
    this.#onStatus = onStatus ?? (() => {});
    this.#onFirstFrame = onFirstFrame ?? (() => {});
    this.#onOrientationChange = onOrientationChange ?? (() => {});
    this.#onRotateStart = onRotateStart ?? (() => {});
    this.#onRotateEnd = onRotateEnd ?? (() => {});
    this.#onStats = onStats ?? (() => {});
    this.#onAccessibility = onAccessibility ?? (() => {});
    this.#onStopped = onStopped ?? (() => {});
    this.#onBackends = onBackends ?? (() => {});

    this.settings = { fps, quality, data_saver, dev_w: canvas.width, dev_h: canvas.height };
    if (backends) Object.assign(this.settings, { capture_backend: backends.capture, input_backend: backends.input, jpeg_scale: backends.scaling, native_scale: backends.nativeScaling });

    this.#setupPointer();
    this.#connect();
  }

  send(msg) {
    if (msg?.type === 'rotate') this.#onRotateStart();
    if (this.#ws?.readyState === WebSocket.OPEN) {
      this.#ws.send(JSON.stringify(msg));
    }
  }

  updateSettings(patch) {
    Object.assign(this.settings, patch);
    if (patch.stream_paused === true) this.#resetDecoder();
    this.send({ type: 'settings', ...patch });
  }

  switchBackends(choices) {
    this.#cancelPointer();
    Object.assign(this.settings, { capture_backend: choices.capture, input_backend: choices.input, jpeg_scale: choices.scaling, native_scale: choices.nativeScaling });
    // Reconnect only this device. Native retirement releases input and joins the
    // old server before the replacement starts; old socket callbacks are ignored.
    this.#connect();
  }

  setTwoFinger(enabled) {
    this.#twoFinger = Boolean(enabled);
  }
  destroy() {
    this.#cancelPointer(); this.#destroyed = true; this.#resetDecoder();
    clearTimeout(this.#noFrameTimer);
    clearTimeout(this.#connectTimer);
    clearTimeout(this.#reconnectTimer);
    clearInterval(this.#watchdog);
    clearInterval(this.#statsTimer); clearInterval(this.#feedbackTimer);
    if (this.#ws) { this.#ws.onclose = null; this.#ws.close(); this.#ws = null; }
  }

  #setOrientation(landscape) {
    if (landscape === this.#isLandscape) return;
    this.#isLandscape = landscape;
    this.#canvas.width  = landscape ? this.#portraitH : this.#portraitW;
    this.#canvas.height = landscape ? this.#portraitW : this.#portraitH;
    this.send({ type: 'settings', dev_w: this.#canvas.width, dev_h: this.#canvas.height });
    this.#onOrientationChange(this.#canvas.width, this.#canvas.height);
  }

  #resetDecoder() {
    this.#decoderToken++;
    if (this.#decoder && this.#decoder.state !== 'closed') this.#decoder.close();
    this.#decoder = null; this.#configuration = null; this.#videoConfig = null;
    this.#stats.dropped += this.#pendingFrames.size;
    this.#pendingFrames.clear(); this.#pendingBytes = 0; this.#needsKeyframe = true;
    if (this.#renderRAF) cancelAnimationFrame(this.#renderRAF);
    this.#renderRAF = 0;
    if (this.#latestFrame) { this.#latestFrame.frame.close(); this.#stats.dropped++; }
    this.#latestFrame = null; this.#lastRenderedTimestamp = -1;
  }

  #unsupported(message) {
    this.#resetDecoder();
    clearTimeout(this.#noFrameTimer); clearTimeout(this.#connectTimer);
    clearTimeout(this.#reconnectTimer); clearInterval(this.#watchdog); clearInterval(this.#statsTimer); clearInterval(this.#feedbackTimer);
    if (this.#ws) { this.#ws.onclose = null; this.#ws.close(); this.#ws = null; }
    this.#onStatus('unsupported', message);
  }

  #recover(error, token = this.#decoderToken, overloaded = false) {
    if (token !== this.#decoderToken || this.#destroyed || this.#awaitingRecovery) return;
    console.warn('H.264 decoder recovery:', error?.message ?? error);
    const epoch = this.#videoConfig?.epoch;
    if (!this.#pendingFrames.size && !this.#latestFrame) this.#stats.dropped++;
    this.#resetDecoder();
    this.#awaitingRecovery = true; this.#recoveryEpoch = epoch ?? null; this.#recoveryAt = performance.now();
    // Do not drop a random P frame and continue its dependent reference chain.
    // Ignore old-epoch packets/configs until the server supplies a fresh IDR.
    this.send({ type: 'video_keyframe', ...(epoch === undefined ? {} : { epoch }), overloaded });
  }

  #feedback(ws) {
    if (this.#ws !== ws || ws.readyState !== WebSocket.OPEN || this.#destroyed) return;
    const now = performance.now();
    if (this.#awaitingRecovery && now - this.#recoveryAt > RECOVERY_TIMEOUT) { this.#connect(); return; }
    const oldest = this.#pendingFrames.values().next().value;
    const age = oldest ? Math.max(0, now - oldest.receivedAt) : 0;
    if (this.settings.stream_paused !== true && !this.#awaitingRecovery && age > OUTPUT_STALE) {
      this.#recover('H.264 decoder output stalled', this.#decoderToken, true);
    }
    if (this.#receivedEpoch === null || this.#receivedID === null) return;
    this.send({ type: 'video_feedback', epoch: this.#receivedEpoch, frame_id: this.#receivedID,
      pending_frames: this.#pendingFrames.size, decode_queue: Math.min(MAX_DECODE_QUEUE, this.#decoder?.decodeQueueSize ?? 0),
      oldest_pending_ms: Math.min(60_000, this.#pendingFrames.size ? age : 0) });
  }

  #configureVideo(msg, ws) {
    if (this.settings.stream_paused === true) return;
    if (!Number.isInteger(msg.epoch) || msg.epoch < 0 || msg.epoch > 0xffffffff ||
        !/^avc1\.[0-9a-f]{6}$/i.test(msg.codec) || typeof msg.description !== 'string' || msg.description.length > 8192 ||
        ![msg.width, msg.height, msg.coded_width, msg.coded_height].every(n => Number.isInteger(n) && n > 0 && n <= 8192) ||
        msg.width > msg.coded_width || msg.height > msg.coded_height) {
      this.#recover('Invalid H.264 configuration'); return;
    }
    if (this.#awaitingRecovery && msg.epoch === this.#recoveryEpoch) return;
    if (this.#videoConfig?.epoch === msg.epoch && this.#videoConfig.description === msg.description &&
        this.#videoConfig.codec === msg.codec && this.#videoConfig.width === msg.width && this.#videoConfig.height === msg.height &&
        this.#videoConfig.coded_width === msg.coded_width && this.#videoConfig.coded_height === msg.coded_height && this.#configuration) return;
    this.#resetDecoder();
    const token = this.#decoderToken;
    this.#videoConfig = msg; this.#awaitingRecovery = false; this.#recoveryEpoch = null;
    let description;
    try { description = Uint8Array.from(atob(msg.description), c => c.charCodeAt(0)); }
    catch (error) { this.#recover(error, token); return; }
    const config = { codec: msg.codec, description,
      codedWidth: msg.coded_width, codedHeight: msg.coded_height, optimizeForLatency: true, hardwareAcceleration: 'no-preference' };
    this.#configuration = VideoDecoder.isConfigSupported(config).then(support => {
      if (this.#destroyed || this.#ws !== ws || token !== this.#decoderToken) return false;
      if (!support.supported) { this.#unsupported('This browser cannot decode H.264 with WebCodecs. Use a current Chrome, Edge or Safari over trusted HTTPS.'); return false; }
      this.#decoder = new VideoDecoder({ output: frame => this.#present(frame, token, ws), error: error => this.#recover(error, token) });
      this.#decoder.configure(config);
      // Keep probe-time payloads only in the bounded Map, not captured by an
      // uncancellable promise callback for every packet. Reset frees them.
      for (const pending of this.#pendingFrames.values()) this.#submit(pending, token, ws);
      return true;
    }).catch(error => { this.#recover(error, token); return false; });
  }

  #decodePacket(buffer, ws) {
    if (buffer.byteLength < 25 || buffer.byteLength > 16_000_024) { this.#recover('Invalid H.264 packet size'); return; }
    const view = new DataView(buffer);
    if (view.getUint32(0) !== 0x53575631 || view.getUint8(4) > 1 || view.getUint8(5) || view.getUint16(6)) {
      this.#recover('Invalid H.264 packet header'); return;
    }
    const epoch = view.getUint32(8), id = view.getUint32(12), timestamp = Number(view.getBigUint64(16));
    const keyframe = view.getUint8(4) === 1;
    if (!Number.isSafeInteger(timestamp)) { this.#recover('Invalid video timestamp'); return; }
    // Receipt telemetry also retires old packets already queued before pause or
    // recovery. It never authorizes drawing them or tunes a replacement epoch.
    this.#receivedEpoch = epoch; this.#receivedID = id; this.#stats.bytes += buffer.byteLength;
    if (this.settings.stream_paused === true || this.#awaitingRecovery) return;
    if (epoch !== this.#videoConfig?.epoch || !this.#configuration) {
      this.#stats.dropped++;
      if (!this.#videoConfig) this.#recover('Missing H.264 configuration');
      return;
    }
    if (this.#needsKeyframe && !keyframe) { this.#recover('Missing initial H.264 keyframe'); return; }
    if (this.#pendingFrames.size >= MAX_PENDING_FRAMES ||
        (this.#pendingFrames.size && this.#pendingBytes + buffer.byteLength > MAX_PENDING_BYTES)) {
      this.#recover('H.264 decoder backlog is overloaded', this.#decoderToken, true); return;
    }
    if (this.#pendingFrames.has(timestamp)) { this.#recover('Duplicate H.264 timestamp'); return; }
    const token = this.#decoderToken;
    const pending = { epoch, id, timestamp, keyframe, data: new Uint8Array(buffer, 24), bytes: buffer.byteLength, receivedAt: performance.now() };
    this.#pendingFrames.set(timestamp, pending);
    this.#pendingBytes += buffer.byteLength;
    // The first queued chunk must be a key, not every packet. A single support
    // probe drains retained packets in wire order; configured decoders submit
    // directly, without adding a promise and packet closure for every frame.
    this.#needsKeyframe = false;
    if (this.#decoder?.state === 'configured') this.#submit(pending, token, ws);
  }

  #submit(pending, token, ws) {
    if (token !== this.#decoderToken || this.#ws !== ws || this.#destroyed || !pending.data) return;
    const data = pending.data; pending.data = null;
    try {
      if (this.#decoder.decodeQueueSize >= MAX_DECODE_QUEUE) {
        this.#recover('H.264 decoder queue is overloaded', token, true); return;
      }
      this.#decoder.decode(new EncodedVideoChunk({ type: pending.keyframe ? 'key' : 'delta', timestamp: pending.timestamp, data }));
    } catch (error) { this.#recover(error, token); }
  }

  #present(frame, token, ws) {
    const pending = this.#pendingFrames.get(frame.timestamp);
    let retained = false;
    try {
      if (this.#destroyed || token !== this.#decoderToken || this.#ws !== ws || !pending) return;
      this.#pendingFrames.delete(frame.timestamp); this.#pendingBytes -= pending.bytes;
      if (frame.timestamp <= this.#lastRenderedTimestamp || (this.#latestFrame && frame.timestamp <= this.#latestFrame.frame.timestamp)) {
        this.#stats.dropped++; return;
      }
      if (this.#latestFrame) { this.#latestFrame.frame.close(); this.#stats.dropped++; }
      this.#latestFrame = { frame, token, ws }; retained = true;
      // Decode reference frames, but render only the newest available output.
      // At most one VideoFrame survives until the next animation frame.
      if (!this.#renderRAF) this.#renderRAF = requestAnimationFrame(() => this.#drawLatest());
    } finally { if (!retained) frame.close(); }
  }

  #drawLatest() {
    this.#renderRAF = 0;
    const latest = this.#latestFrame; this.#latestFrame = null;
    if (!latest) return;
    const { frame, token, ws } = latest;
    let error = null;
    try {
      if (this.#destroyed || token !== this.#decoderToken || this.#ws !== ws || !this.#videoConfig) return;
      const { width, height } = this.#videoConfig;
      const landscape = width > height, pw = Math.min(width, height), ph = Math.max(width, height);
      if (pw !== this.#portraitW || ph !== this.#portraitH) {
        this.#portraitW = pw; this.#portraitH = ph; this.#isLandscape = landscape;
        this.#canvas.width = width; this.#canvas.height = height;
        this.send({ type: 'settings', dev_w: width, dev_h: height });
        this.#onOrientationChange(width, height);
      } else { this.#setOrientation(landscape); }
      // Once another backend supplies real unscaled pixels, resume its existing
      // reconnect geometry; do not carry a scrcpy-only budget into later modes.
      if (this.#scrcpyBaseSize && this.#effectiveCapture !== 'scrcpy') this.#scrcpyBaseSize = null;
      // Odd capture sizes have even 4:2:0 padding; never show that padding.
      this.#ctx.drawImage(frame, 0, 0, width, height, 0, 0, this.#canvas.width, this.#canvas.height);
      this.#lastRenderedTimestamp = frame.timestamp; this.#stats.frames++;
      if (!this.#firstFrame || this.#captureUnavailable) {
        const first = !this.#firstFrame;
        this.#firstFrame = true; this.#captureUnavailable = false;
        clearTimeout(this.#noFrameTimer); this.#onStatus('streaming');
        if (first) this.#onFirstFrame();
      }
    } catch (failure) { error = failure; }
    finally { frame.close(); }
    if (error) this.#recover(error, token);
  }

  #sessionReady() {
    // Production discovery may finish after the HTTP upgrade. Initial client
    // messages can precede native handlers; capabilities confirm binding.
    this.send({ type: 'settings', ...this.settings, stream_paused: this.settings.stream_paused === true,
      accessibility_enabled: this.settings.accessibility_enabled === true, accessibility_subscription: this.settings.accessibility_subscription ?? 0 });
    this.send({ type: 'video_ready', flow: 'paced-v1' });
  }

  #connect() {
    if (this.#destroyed) return;
    clearTimeout(this.#connectTimer); clearTimeout(this.#reconnectTimer); clearTimeout(this.#noFrameTimer);
    clearInterval(this.#feedbackTimer); this.#feedbackTimer = null;
    this.#awaitingRecovery = false; this.#recoveryEpoch = null; this.#receivedEpoch = null; this.#receivedID = null;
    this.#lastMessageAt = Date.now(); this.#resetDecoder();
    if (this.#ws) { this.#ws.onclose = null; this.#ws.close(); }
    if (!globalThis.isSecureContext || typeof VideoDecoder === 'undefined' || typeof EncodedVideoChunk === 'undefined') {
      this.#unsupported('H.264 requires WebCodecs in a secure context. Trust the public Simwisp local CA and open the HTTPS link in a current Chrome, Edge or Safari.'); return;
    }
    this.#firstFrame = false; this.#captureUnavailable = false; this.#liveTouch = false;
    this.#onStatus('connecting');
    const sourceSize = this.#scrcpyBaseSize ?? { width: this.#portraitW, height: this.#portraitH };
    const ws = new WebSocket(
      `${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/ws/${encodeURIComponent(this.#udid)}?fps=${this.settings.fps}&quality=${this.settings.quality}&w=${sourceSize.width}&h=${sourceSize.height}&data_saver=${this.settings.data_saver ? 1 : 0}${this.settings.capture_backend ? '&capture_backend=' + encodeURIComponent(this.settings.capture_backend) + '&input_backend=' + encodeURIComponent(this.settings.input_backend) : ''}${this.settings.jpeg_scale ? '&jpeg_scale=' + encodeURIComponent(this.settings.jpeg_scale) : ''}${this.settings.capture_backend === 'native' && this.settings.native_scale ? '&native_scale=' + encodeURIComponent(this.settings.native_scale) : ''}`
    );
    this.#ws = ws; ws.binaryType = 'arraybuffer';
    this.#connectTimer = setTimeout(() => {
      if (this.#ws !== ws || this.#destroyed) return;
      if (ws.readyState === WebSocket.CONNECTING) {
        ws.onclose = null; ws.close();
        this.#reconnectTimer = setTimeout(() => this.#connect(), 1000);
      }
    }, CONNECT_TIMEOUT);
    ws.onopen = () => {
      if (this.#ws !== ws || this.#destroyed) return;
      clearTimeout(this.#connectTimer); this.#onStatus('connected');
      clearInterval(this.#feedbackTimer);
      this.#feedbackTimer = setInterval(() => this.#feedback(ws), FEEDBACK_INTERVAL);
      this.#sessionReady();
      this.#noFrameTimer = setTimeout(() => { if (!this.#firstFrame) this.#onStatus('no-frames'); }, NO_FRAME_WARN);
    };
    ws.onclose = () => {
      if (this.#ws !== ws || this.#destroyed) return;
      clearTimeout(this.#connectTimer); clearTimeout(this.#noFrameTimer);
      clearInterval(this.#feedbackTimer); this.#feedbackTimer = null; this.#resetDecoder();
      this.#onStatus('reconnecting');
      this.#reconnectTimer = setTimeout(() => this.#connect(), RECONNECT_DELAY);
    };
    ws.onerror = () => ws.close();
    ws.onmessage = e => {
      if (this.#ws !== ws || this.#destroyed) return;
      this.#lastMessageAt = Date.now();
      if (typeof e.data !== 'string') {
        if (e.data instanceof ArrayBuffer) this.#decodePacket(e.data, ws);
        return;
      }
      try {
        const msg = JSON.parse(e.data);
        if (msg.type === 'device_stopping') {
          this.destroy(); this.#onStopped();
        } else if (msg.type === 'ios_capture') {
          this.#onBackends(msg);
        } else if (msg.type === 'android_backends') {
          this.#effectiveCapture = msg.effective_capture;
          if (msg.physical === false && ['auto', 'scrcpy'].includes(msg.capture) &&
              msg.capture === (this.settings.capture_backend ?? 'auto') && msg.input === (this.settings.input_backend ?? 'auto') &&
              (msg.jpeg_scale ?? '1') === (this.settings.jpeg_scale ?? '1') &&
              [msg.scrcpy_base_width, msg.scrcpy_base_height].every(n => Number.isInteger(n) && n >= 8 && n <= 8192)) {
            this.#scrcpyBaseSize = { width: msg.scrcpy_base_width, height: msg.scrcpy_base_height };
          }
          this.#onBackends(msg);
        } else if (msg.type === 'video_config') {
          this.#configureVideo(msg, ws);
        } else if (msg.type === 'accessibility_status' || msg.type === 'accessibility_event') {
          if (this.settings.accessibility_enabled === true && this.settings.stream_paused !== true) this.#onAccessibility(msg);
        } else if (msg.type === 'input_capabilities') {
          if (msg.video_flow !== 'paced-v1') { this.#unsupported('Streaming protocol updated; update the app and reload this page.'); return; }
          this.#liveTouch = msg.live_touch === true;
          this.#sessionReady();
        } else if (msg.type === 'capture_error' || msg.type === 'input_error') {
          console.warn('Simwisp:', msg.message);
          if (msg.type === 'capture_error') { this.#captureUnavailable = true; this.#resetDecoder(); this.#onStatus('no-frames'); }
        } else if (msg.type === 'frame_heartbeat') {
          this.#lastMessageAt = Date.now();
        } else if (msg.type === 'rotated') {
          this.#setOrientation(typeof msg.landscape === 'boolean' ? msg.landscape : !this.#isLandscape);
          this.#onRotateEnd(true);
        } else if (msg.type === 'rotate_failed') {
          this.#onRotateEnd(false);
        } else if (msg.type === 'server_stats') {
          this.#serverStats = { fps: msg.fps ?? null, sentFps: msg.sent_fps ?? null, quality: msg.quality ?? null };
        }
      } catch (error) { console.warn('Simwisp video message:', error); }
    };
    clearInterval(this.#watchdog);
    this.#watchdog = setInterval(() => {
      if (this.#ws?.readyState === WebSocket.OPEN && this.#lastMessageAt > 0 && Date.now() - this.#lastMessageAt > WATCHDOG_STALE) this.#connect();
    }, WATCHDOG_POLL);
    clearInterval(this.#statsTimer);
    // A reconnect starts a fresh rate window; old partial-window bytes/frames
    // must not be charged to the new connection's first sample.
    this.#stats.lastFrames = this.#stats.frames; this.#stats.lastBytes = this.#stats.bytes; this.#stats.lastAt = performance.now();
    this.#statsTimer = setInterval(() => {
      const now = performance.now(), elapsed = (now - this.#stats.lastAt) / 1000;
      if (!Number.isFinite(elapsed) || elapsed <= 0) return;
      const frames = this.#stats.frames - this.#stats.lastFrames, bytes = this.#stats.bytes - this.#stats.lastBytes;
      this.#stats.lastFrames = this.#stats.frames; this.#stats.lastBytes = this.#stats.bytes; this.#stats.lastAt = now;
      // Browser timers can be delayed/throttled: a tick is not necessarily1s.
      this.#stats.fps = frames / elapsed; this.#stats.bps = bytes / elapsed;
      this.#stats.avgFrame = frames ? bytes / frames : this.#stats.avgFrame;
      this.#onStats({ fps: this.#stats.fps, bps: this.#stats.bps, intervalSeconds: elapsed, intervalBytes: bytes, receivedBytes: this.#stats.bytes, avgFrame: this.#stats.avgFrame, dropped: this.#stats.dropped, serverFps: this.#serverStats.fps, serverSentFps: this.#serverStats.sentFps, serverQuality: this.#serverStats.quality, codec: 'h264' });
    }, 1000);
  }

  #setupPointer() {
    const canvas = this.#canvas;
    canvas.style.touchAction = 'none';

    let activePointer = null;
    let origin = null;
    let live = false;
    let twoFingerGesture = false;
    let dragging = false;
    let pending = null;
    let raf = 0;
    let lastSentAt = 0;
    let lastSent = null;

    const norm = e => {
      const r = canvas.getBoundingClientRect();
      return {
        x: Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)),
        y: Math.max(0, Math.min(1, (e.clientY - r.top) / r.height)),
      };
    };

    const sendMove = p => {
      this.send({ type: 'touch_move', x: p.x, y: p.y });
      lastSent = p;
      lastSentAt = performance.now();
    };

    // At most ~60 pointer-move messages per second. Only the latest point
    // matters between animation frames; the backend preserves down/up order.
    const flushOnFrame = () => {
      raf = 0;
      if (activePointer === null || !live || !pending) return;
      if (performance.now() - lastSentAt >= 15) {
        sendMove(pending);
        pending = null;
      } else {
        raf = requestAnimationFrame(flushOnFrame);
      }
    };

    const finish = (e, cancelled = false) => {
      if (activePointer !== e.pointerId) return;
      e.preventDefault();
      const end = norm(e);
      if (raf) cancelAnimationFrame(raf);
      raf = 0;
      pending = null;

      if (twoFingerGesture) {
        // This deliberately sends no Quartz events while the finger moves.
        // Perform one swipe through the selected input backend on finger lift.
        if (!cancelled && origin &&
            Math.hypot(end.x - origin.x, end.y - origin.y) >= DRAG_THRESHOLD) {
          this.send({
            type: 'accessibility_swipe',
            x1: origin.x, y1: origin.y,
            x2: end.x, y2: end.y,
          });
        }
      } else if (live) {
        // Preserve the final position before mouse-up.
        if (dragging && (!lastSent ||
            Math.hypot(end.x - lastSent.x, end.y - lastSent.y) > 0.001)) {
          sendMove(end);
        }
        this.send({ type: 'touch_up', x: end.x, y: end.y });
      } else if (!cancelled && origin) {
        // Existing tap/drag protocol for non-Quartz backends.
        const dx = end.x - origin.x, dy = end.y - origin.y;
        if (Math.hypot(dx, dy) < DRAG_THRESHOLD) {
          this.send({ type: 'tap', x: end.x, y: end.y });
        } else {
          this.send({ type: 'drag', x1: origin.x, y1: origin.y, x2: end.x, y2: end.y });
        }
      }

      // Clear before releasePointerCapture, which may fire lostpointercapture.
      activePointer = null;
      origin = null;
      live = false;
      twoFingerGesture = false;
      dragging = false;
      lastSent = null;
      if (canvas.hasPointerCapture(e.pointerId)) {
        canvas.releasePointerCapture(e.pointerId);
      }
    };

    this.#cancelPointer = () => {
      const id = activePointer; activePointer = null; origin = null; live = false; twoFingerGesture = false; dragging = false; pending = null; lastSent = null;
      if (raf) { cancelAnimationFrame(raf); raf = 0; }
      if (id !== null && canvas.hasPointerCapture(id)) canvas.releasePointerCapture(id);
    };
    canvas.addEventListener('pointerdown', e => {
      if (activePointer !== null || e.isPrimary === false) return;
      e.preventDefault();
      canvas.setPointerCapture(e.pointerId);
      activePointer = e.pointerId;
      origin = norm(e);
      // Freeze mode for this drag; do not send Quartz down/move/up in 2F.
      twoFingerGesture = this.#twoFinger;
      live = !twoFingerGesture && this.#liveTouch &&
             this.#ws?.readyState === WebSocket.OPEN;
      dragging = false;
      pending = null;
      lastSentAt = 0;
      lastSent = origin;
      if (live) this.send({ type: 'touch_down', x: origin.x, y: origin.y });
    }, { passive: false });

    canvas.addEventListener('pointermove', e => {
      if (e.pointerId !== activePointer || !live || !origin) return;
      e.preventDefault();
      const p = norm(e);
      if (!dragging && Math.hypot(p.x - origin.x, p.y - origin.y) >= DRAG_THRESHOLD) {
        dragging = true;
      }
      if (!dragging) return;
      pending = p;
      if (!raf) raf = requestAnimationFrame(flushOnFrame);
    }, { passive: false });

    canvas.addEventListener('pointerup', e => finish(e), { passive: false });
    canvas.addEventListener('pointercancel', e => finish(e, true), { passive: false });
    canvas.addEventListener('lostpointercapture', e => {
      if (activePointer === e.pointerId) finish(e, true);
    });
  }
}
