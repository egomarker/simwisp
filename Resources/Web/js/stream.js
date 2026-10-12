const CONNECT_TIMEOUT = 5000;
const RECONNECT_DELAY = 2000;
const NO_FRAME_WARN   = 4000;
const WATCHDOG_POLL   = 3000;
const WATCHDOG_STALE  = 16000;
const DRAG_THRESHOLD  = 0.015;

export class SimStream {
  #liveTouch = false;
  #twoFinger = false;
  #udid; #canvas; #ctx;
  #ws = null; #connectTimer = null; #reconnectTimer = null; #watchdog = null;
  #lastFrameAt = 0; #firstFrame = false; #captureUnavailable = false;
  #decoder = null; #decoderToken = 0; #videoConfig = null; #configuration = null;
  #pendingFrame = null; #needsKeyframe = true; #noFrameTimer = null; #destroyed = false;
  #portraitW; #portraitH; #isLandscape = false;
  #onStatus; #onFirstFrame; #onOrientationChange; #onRotateStart; #onRotateEnd;
  #onStats; #onAccessibility; #statsTimer = null;
  #stats = { frames: 0, bytes: 0, dropped: 0, lastFrames: 0, lastBytes: 0, fps: 0, bps: 0, avgFrame: 0 };
  #serverStats = { fps: null, quality: null };

  constructor(
    udid,
    canvas,
    {
      fps = 60,
      quality = 20,
      data_saver = false,
      onStatus,
      onFirstFrame,
      onOrientationChange,
      onRotateStart,
      onRotateEnd,
      onStats,
      onAccessibility,
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

    this.settings = { fps, quality, data_saver, dev_w: canvas.width, dev_h: canvas.height };

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

  setTwoFinger(enabled) {
    this.#twoFinger = Boolean(enabled);
  }
  destroy() {
    this.#destroyed = true; this.#resetDecoder();
    clearTimeout(this.#noFrameTimer);
    clearTimeout(this.#connectTimer);
    clearTimeout(this.#reconnectTimer);
    clearInterval(this.#watchdog);
    clearInterval(this.#statsTimer);
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
    this.#pendingFrame = null; this.#needsKeyframe = true;
  }

  #unsupported(message) {
    this.#resetDecoder();
    clearTimeout(this.#noFrameTimer); clearTimeout(this.#connectTimer);
    clearTimeout(this.#reconnectTimer); clearInterval(this.#watchdog); clearInterval(this.#statsTimer);
    if (this.#ws) { this.#ws.onclose = null; this.#ws.close(); this.#ws = null; }
    this.#onStatus('unsupported', message);
  }

  #recover(error, token = this.#decoderToken) {
    if (token !== this.#decoderToken || this.#destroyed) return;
    console.warn('H.264 decoder recovery:', error?.message ?? error);
    this.#stats.dropped++;
    const pending = this.#pendingFrame;
    this.#resetDecoder();
    if (pending) this.send({ type: 'frame_ack', epoch: pending.epoch, frame_id: pending.id, decode_error: true });
    else this.send({ type: 'video_keyframe' });
  }

  #configureVideo(msg, ws) {
    if (this.settings.stream_paused === true) return;
    if (!Number.isInteger(msg.epoch) || msg.epoch < 0 || msg.epoch > 0xffffffff ||
        !/^avc1\.[0-9a-f]{6}$/i.test(msg.codec) || typeof msg.description !== 'string' || msg.description.length > 8192 ||
        ![msg.width, msg.height, msg.coded_width, msg.coded_height].every(n => Number.isInteger(n) && n > 0 && n <= 8192) ||
        msg.width > msg.coded_width || msg.height > msg.coded_height) {
      this.#recover('Invalid H.264 configuration'); return;
    }
    if (this.#videoConfig?.epoch === msg.epoch && this.#videoConfig?.description === msg.description &&
        this.#videoConfig.width === msg.width && this.#videoConfig.height === msg.height && this.#decoder?.state === 'configured') return;
    this.#resetDecoder();
    const token = this.#decoderToken;
    this.#videoConfig = msg;
    const config = { codec: msg.codec, description: Uint8Array.from(atob(msg.description), c => c.charCodeAt(0)),
      codedWidth: msg.coded_width, codedHeight: msg.coded_height, optimizeForLatency: true, hardwareAcceleration: 'no-preference' };
    this.#configuration = VideoDecoder.isConfigSupported(config).then(support => {
      if (this.#destroyed || this.#ws !== ws || token !== this.#decoderToken) return false;
      if (!support.supported) { this.#unsupported('This browser cannot decode H.264 with WebCodecs. Use a current Chrome, Edge or Safari over trusted HTTPS.'); return false; }
      this.#decoder = new VideoDecoder({ output: frame => this.#present(frame, token, ws), error: error => this.#recover(error, token) });
      this.#decoder.configure(config);
      return true;
    }).catch(error => { this.#recover(error, token); return false; });
  }

  #decodePacket(buffer, ws) {
    if (this.settings.stream_paused === true) return;
    if (buffer.byteLength < 25 || buffer.byteLength > 16_000_024) { this.#recover('Invalid H.264 packet size'); return; }
    const view = new DataView(buffer);
    if (view.getUint32(0) !== 0x53575631 || view.getUint8(4) > 1 || view.getUint8(5) || view.getUint16(6)) {
      this.#recover('Invalid H.264 packet header'); return;
    }
    const epoch = view.getUint32(8), id = view.getUint32(12), timestamp = Number(view.getBigUint64(16));
    const keyframe = view.getUint8(4) === 1;
    if (!Number.isSafeInteger(timestamp)) { this.#recover('Invalid video timestamp'); return; }
    if (epoch !== this.#videoConfig?.epoch || !this.#configuration) {
      this.#stats.dropped++; this.send({ type: 'frame_ack', epoch, frame_id: id, decode_error: true }); return;
    }
    if (this.#pendingFrame || (this.#needsKeyframe && !keyframe)) {
      this.#recover('Video backpressure or missing keyframe');
      this.send({ type: 'frame_ack', epoch, frame_id: id, decode_error: true }); return;
    }
    const token = this.#decoderToken;
    this.#stats.bytes += buffer.byteLength; this.#lastFrameAt = Date.now();
    this.#pendingFrame = { epoch, id, timestamp };
    // Exactly one packet may wait for asynchronous capability probing. It is
    // invalidated on pause, resize, disconnect or destruction, not queued.
    this.#configuration.then(ready => {
      if (!ready || token !== this.#decoderToken || this.#ws !== ws || this.#destroyed) return;
      try {
        if (this.#decoder.decodeQueueSize > 0) throw Error('Decoder queue is full');
        this.#decoder.decode(new EncodedVideoChunk({ type: keyframe ? 'key' : 'delta', timestamp, data: new Uint8Array(buffer, 24) }));
        this.#needsKeyframe = false;
      } catch (error) { this.#recover(error, token); }
    });
  }

  #present(frame, token, ws) {
    const pending = this.#pendingFrame, timestamp = frame.timestamp;
    let error = null;
    try {
      if (this.#destroyed || token !== this.#decoderToken || this.#ws !== ws || !pending || timestamp !== pending.timestamp) return;
      const { width, height } = this.#videoConfig;
      const landscape = width > height, pw = Math.min(width, height), ph = Math.max(width, height);
      if (pw !== this.#portraitW || ph !== this.#portraitH) {
        this.#portraitW = pw; this.#portraitH = ph; this.#isLandscape = landscape;
        this.#canvas.width = width; this.#canvas.height = height;
        this.send({ type: 'settings', dev_w: width, dev_h: height });
        this.#onOrientationChange(width, height);
      } else { this.#setOrientation(landscape); }
      // Odd capture sizes are padded by one pixel for 4:2:0; never show that padding.
      this.#ctx.drawImage(frame, 0, 0, width, height, 0, 0, this.#canvas.width, this.#canvas.height);
      this.#stats.frames++; this.#lastFrameAt = Date.now();
      if (!this.#firstFrame || this.#captureUnavailable) {
        const first = !this.#firstFrame;
        this.#firstFrame = true; this.#captureUnavailable = false;
        clearTimeout(this.#noFrameTimer); this.#onStatus('streaming');
        if (first) this.#onFirstFrame();
      }
    } catch (failure) { error = failure; }
    finally {
      frame.close();
      if (token === this.#decoderToken && this.#ws === ws && this.#pendingFrame === pending && pending && timestamp === pending.timestamp) {
        this.#pendingFrame = null;
        // ACK only after decode + drawing + close. Generation/frame identity
        // stops delayed outputs from acknowledging a replacement encoder.
        this.send({ type: 'frame_ack', epoch: pending.epoch, frame_id: pending.id, ...(error ? { decode_error: true } : {}) });
      }
    }
    if (error) this.#recover(error, token);
  }

  #sessionReady() {
    // Production discovery may finish after the HTTP upgrade. Initial client
    // messages can precede native handlers; capabilities confirm binding.
    this.send({ type: 'settings', ...this.settings, stream_paused: this.settings.stream_paused === true,
      accessibility_enabled: this.settings.accessibility_enabled === true, accessibility_subscription: this.settings.accessibility_subscription ?? 0 });
    this.send({ type: 'video_ready' });
  }

  #connect() {
    if (this.#destroyed) return;
    clearTimeout(this.#connectTimer); clearTimeout(this.#reconnectTimer); clearTimeout(this.#noFrameTimer);
    this.#resetDecoder();
    if (this.#ws) { this.#ws.onclose = null; this.#ws.close(); }
    if (!globalThis.isSecureContext || typeof VideoDecoder === 'undefined' || typeof EncodedVideoChunk === 'undefined') {
      this.#unsupported('H.264 requires WebCodecs in a secure context. Trust the public Simwisp local CA and open the HTTPS link in a current Chrome, Edge or Safari.'); return;
    }
    this.#firstFrame = false; this.#captureUnavailable = false; this.#liveTouch = false;
    this.#onStatus('connecting');
    const ws = new WebSocket(
      `${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/ws/${this.#udid}?fps=${this.settings.fps}&quality=${this.settings.quality}&w=${this.#portraitW}&h=${this.#portraitH}&data_saver=${this.settings.data_saver ? 1 : 0}`
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
      this.#sessionReady();
      this.#noFrameTimer = setTimeout(() => { if (!this.#firstFrame) this.#onStatus('no-frames'); }, NO_FRAME_WARN);
    };
    ws.onclose = () => {
      if (this.#ws !== ws || this.#destroyed) return;
      clearTimeout(this.#connectTimer); clearTimeout(this.#noFrameTimer); this.#resetDecoder();
      this.#onStatus('reconnecting');
      this.#reconnectTimer = setTimeout(() => this.#connect(), RECONNECT_DELAY);
    };
    ws.onerror = () => ws.close();
    ws.onmessage = e => {
      if (this.#ws !== ws || this.#destroyed) return;
      if (typeof e.data !== 'string') {
        if (e.data instanceof ArrayBuffer) this.#decodePacket(e.data, ws);
        return;
      }
      try {
        const msg = JSON.parse(e.data);
        if (msg.type === 'video_config') {
          this.#configureVideo(msg, ws);
        } else if (msg.type === 'accessibility_status' || msg.type === 'accessibility_event') {
          if (this.settings.accessibility_enabled === true && this.settings.stream_paused !== true) this.#onAccessibility(msg);
        } else if (msg.type === 'input_capabilities') {
          this.#liveTouch = msg.live_touch === true;
          this.#sessionReady();
        } else if (msg.type === 'capture_error' || msg.type === 'input_error') {
          console.warn('Simwisp:', msg.message);
          if (msg.type === 'capture_error') { this.#captureUnavailable = true; this.#resetDecoder(); this.#onStatus('no-frames'); }
        } else if (msg.type === 'frame_heartbeat') {
          this.#lastFrameAt = Date.now();
        } else if (msg.type === 'rotated') {
          this.#setOrientation(typeof msg.landscape === 'boolean' ? msg.landscape : !this.#isLandscape);
          this.#onRotateEnd(true);
        } else if (msg.type === 'rotate_failed') {
          this.#onRotateEnd(false);
        } else if (msg.type === 'server_stats') {
          this.#serverStats = { fps: msg.fps ?? null, quality: msg.quality ?? null };
        }
      } catch (error) { console.warn('Simwisp video message:', error); }
    };
    clearInterval(this.#watchdog);
    this.#watchdog = setInterval(() => {
      if (this.#ws?.readyState === WebSocket.OPEN && this.#lastFrameAt > 0 && Date.now() - this.#lastFrameAt > WATCHDOG_STALE) this.#connect();
    }, WATCHDOG_POLL);
    clearInterval(this.#statsTimer);
    this.#statsTimer = setInterval(() => {
      const frames = this.#stats.frames - this.#stats.lastFrames, bytes = this.#stats.bytes - this.#stats.lastBytes;
      this.#stats.lastFrames = this.#stats.frames; this.#stats.lastBytes = this.#stats.bytes;
      this.#stats.fps = frames; this.#stats.bps = bytes;
      this.#stats.avgFrame = frames ? bytes / frames : this.#stats.avgFrame;
      this.#onStats({ fps: this.#stats.fps, bps: this.#stats.bps, avgFrame: this.#stats.avgFrame, dropped: this.#stats.dropped, serverFps: this.#serverStats.fps, serverQuality: this.#serverStats.quality, codec: 'h264' });
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
        // Perform one compat-style ADB swipe when the browser finger lifts.
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
