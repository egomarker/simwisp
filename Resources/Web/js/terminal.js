import { terminalTheme } from './theme.js';

let assets;
function stylesheet(href) {
  return new Promise((resolve, reject) => {
    const link = document.createElement('link'); link.rel = 'stylesheet'; link.href = href;
    link.onload = resolve; link.onerror = () => reject(new Error('Could not load ' + href));
    document.head.append(link);
  });
}
function script(src) {
  return new Promise((resolve, reject) => {
    const element = document.createElement('script'); element.src = src;
    element.onload = resolve; element.onerror = () => reject(new Error('Could not load ' + src));
    document.head.append(element);
  });
}
export function loadTerminalAssets() {
  if (!assets) {
    assets = Promise.all([
      stylesheet('/css/vendor/xterm.css'), stylesheet('/css/terminal.css'),
      script('/js/vendor/xterm.js').then(() => script('/js/vendor/xterm-addon-fit.js')),
    ]).catch(error => { assets = null; throw error; });
  }
  return assets;
}

export class SimTerminal {
  #term; #fit; #ws; #sessionId; #closing = false; #connectedBefore = false;
  #connectTimer; #reconnectTimer; #onStatus; #onSession; #retries = 0;
  #themeChanged = () => { this.#term.options.theme = terminalTheme(); };
  #clicked = () => this.focus();
  #element;
  constructor(element, { sessionId = null, onStatus = () => {}, onSession = () => {} } = {}) {
    this.#element = element; this.#sessionId = sessionId; this.#onStatus = onStatus; this.#onSession = onSession;
    this.#term = new window.Terminal({
      fontFamily: '"SF Mono", Menlo, Monaco, "Courier New", monospace',
      fontSize: 13, lineHeight: 1.4, scrollback: 5000, scrollOnUserInput: false,
      cursorBlink: false, smoothScrollDuration: 0, theme: terminalTheme(),
    });
    this.#fit = new window.FitAddon.FitAddon(); this.#term.loadAddon(this.#fit); this.#term.open(element);
    window.addEventListener('simmer:themechange', this.#themeChanged);
    element.addEventListener('click', this.#clicked);
    this.#term.onData(data => {
      // Keep paste frames within the server's bounded 64 KiB message/input
      // budget. Flow control for shell output is independent of simulator ACKs.
      if (this.#ws?.readyState !== WebSocket.OPEN) return;
      const bytes = new TextEncoder().encode(data);
      if (bytes.length > 65536 || this.#ws.bufferedAmount + bytes.length > 65536) {
        this.#onStatus('input-too-large'); return;
      }
      this.#ws.send(bytes);
    });
    this.#term.onResize(({ cols, rows }) => this.#send({ type: 'resize', cols, rows }));
    this.#connect();
  }
  get sessionId() { return this.#sessionId; }
  fit() { if (this.#element.getClientRects().length) this.#fit.fit(); }
  focus() { this.#term.focus(); }
  reconnect() { if (!this.#closing && this.#ws?.readyState === WebSocket.CLOSED) { this.#retries = 0; this.#connect(); } }
  setFontSize(size) { this.#term.options.fontSize = size; this.fit(); }
  #send(message) { if (this.#ws?.readyState === WebSocket.OPEN) this.#ws.send(JSON.stringify(message)); }
  destroy({ terminate = true } = {}) {
    this.#closing = true; clearTimeout(this.#connectTimer); clearTimeout(this.#reconnectTimer);
    window.removeEventListener('simmer:themechange', this.#themeChanged);
    this.#element.removeEventListener('click', this.#clicked);
    const ws = this.#ws; this.#ws = null;
    if (ws) {
      ws.onmessage = null; ws.onclose = null;
      if (terminate && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'close' }));
      if (terminate && ws.readyState === WebSocket.CONNECTING) {
        ws.onopen = () => { ws.send(JSON.stringify({ type: 'close' })); ws.close(); };
        setTimeout(() => { if (ws.readyState !== WebSocket.CLOSED) ws.close(); }, 8000);
      } else ws.close();
    }
    this.#term.dispose();
  }
  #connect() {
    if (this.#closing) return;
    clearTimeout(this.#connectTimer); clearTimeout(this.#reconnectTimer);
    this.#onStatus('connecting');
    const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const query = this.#sessionId ? '?session=' + encodeURIComponent(this.#sessionId) : '';
    const ws = new WebSocket(`${scheme}//${location.host}/ws/pty${query}`);
    this.#ws = ws; ws.binaryType = 'arraybuffer';
    this.#connectTimer = setTimeout(() => ws.close(), 8000);
    ws.onopen = () => { clearTimeout(this.#connectTimer); this.#retries = 0; this.#onStatus('connected'); this.fit(); this.#send({ type: 'resize', cols: this.#term.cols, rows: this.#term.rows }); };
    ws.onclose = () => {
      clearTimeout(this.#connectTimer);
      if (this.#closing || this.#ws !== ws) return;
      if (this.#retries >= 5) { this.#onStatus('disconnected'); return; }
      this.#onStatus('reconnecting');
      this.#reconnectTimer = setTimeout(() => this.#connect(), Math.min(30000, 1500 * 2 ** this.#retries++));
    };
    ws.onerror = () => ws.close();
    ws.onmessage = event => {
      if (event.data instanceof ArrayBuffer) {
        // Acknowledge only after xterm has parsed the chunk. At most one bounded
        // output chunk can be in flight; an idle terminal schedules no redraws.
        this.#term.write(new Uint8Array(event.data), () => {
          if (this.#ws === ws) this.#send({ type: 'output_ack' });
        });
        return;
      }
      try {
        const message = JSON.parse(event.data);
        if (message.type === 'session') {
          if (this.#connectedBefore) this.#term.reset();
          this.#connectedBefore = true; this.#sessionId = message.id; this.#onSession(message.id);
        } else if (message.type === 'exit' || message.type === 'terminal_error') {
          this.#closing = true; clearTimeout(this.#reconnectTimer);
          this.#onStatus(message.type === 'exit' ? 'exited' : 'error');
          if (message.message) this.#term.write('\r\n' + message.message + '\r\n');
          this.#sessionId = null; this.#onSession(null);
        }
      } catch { /* ignore unrelated control messages */ }
    };
  }
}
