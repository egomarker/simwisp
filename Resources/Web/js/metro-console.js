let styles, consoleSerial = 0;
export function loadConsoleStyles() {
  return styles ||= new Promise((resolve, reject) => {
    const link = document.createElement('link'); link.rel = 'stylesheet'; link.href = '/css/metro-console.css';
    link.onload = resolve; link.onerror = () => { styles = null; link.remove(); reject(Error('Console styles unavailable')); }; document.head.append(link);
  });
}
export class ConsoleBuffer {
  entries = []; bytes = 0; dropped = 0; offset = 0;
  push(entry) {
    const bytes = new TextEncoder().encode(JSON.stringify(entry)).length;
    if (bytes > 5_242_880) { this.dropped++; return; }
    this.entries.push({ entry, bytes }); this.bytes += bytes;
    while (this.entries.length - this.offset > 5000 || this.bytes > 5_242_880) { this.bytes -= this.entries[this.offset++].bytes; this.dropped++; }
    if (this.offset > 1024) { this.entries = this.entries.slice(this.offset); this.offset = 0; }
  }
  get values() { return this.entries.slice(this.offset).map(v => v.entry); }
  clear() { this.entries = []; this.offset = 0; this.bytes = 0; this.dropped = 0; }
}
function el(tag, className, text) { const e = document.createElement(tag); e.className = className; if (text != null) e.textContent = text; return e; }
function control(text, label, fn) { const b = el('button', 'console-control', text); b.type = 'button'; b.setAttribute('aria-label', label); b.addEventListener('click', fn); return b; }
function safeEntry(e) {
  if (!e || !Number.isSafeInteger(e.sequence) || typeof e.text !== 'string' || e.text.length > 40000 || !['log', 'info', 'warn', 'error'].includes(e.level)) return null;
  return { sequence: e.sequence, level: e.level, text: e.text, timestamp_ms: Number.isFinite(e.timestamp_ms) ? e.timestamp_ms : Date.now(),
    source: e.source && typeof e.source.url === 'string' ? { url: e.source.url.slice(0, 512), line: e.source.line, column: e.source.column } : null,
    stack: (Array.isArray(e.stack) ? e.stack : []).slice(0, 100).map(f => ({ url: String(f.url || '').slice(0, 512), line: Number(f.line) || 0, column: Number(f.column) || 0, function: String(f.function || '').slice(0, 256) })) };
}
export class MetroConsole {
  buffer = new ConsoleBuffer(); target = null; generation = 0; unread = 0; errors = 0; dropped = 0;
  #ws; #closed = false; #visible = false; #paused = false; #scroll = true; #page = 0; #query = ''; #levels = new Set(['log','info','warn','error']);
  #anchor = null; #expanded = new Set(); #rowSerial = 0; #id = ++consoleSerial;
  #renderTimer; #noticeTimer; #retryTimer; #connectTimer; #searchTimer; #retry = 0; #lastDrop = 0; #lastSequence = 0; #epoch = 0;
  constructor(element, { deviceId, binding, onStatus = () => {}, onUnread = () => {}, requestRefresh = () => {} }) {
    this.element = element; this.deviceId = deviceId; this.binding = binding; this.onStatus = onStatus; this.onUnread = onUnread; this.requestRefresh = requestRefresh;
    element.classList.add('metro-console'); element.tabIndex = -1;
    this.toolbar = el('div','console-toolbar');
    for (const level of ['log','info','warn','error']) {
      const b = control(level[0].toUpperCase()+level.slice(1), 'Show '+level+' messages', () => { this.#levels.has(level) ? this.#levels.delete(level) : this.#levels.add(level); b.setAttribute('aria-pressed', String(this.#levels.has(level))); this.#page = 0; this.#anchor = null; this.render(); });
      b.dataset.level = level; b.setAttribute('aria-pressed','true'); this.toolbar.append(b);
    }
    this.search = el('input','console-search'); this.search.type = 'search'; this.search.placeholder = 'Search console'; this.search.setAttribute('aria-label','Search console');
    this.search.addEventListener('input', () => { clearTimeout(this.#searchTimer); this.#searchTimer = setTimeout(() => { this.#query = this.search.value.slice(0, 256).toLowerCase(); this.#page = 0; this.#anchor = null; this.render(); },150); });
    this.pause = control('Pause','Pause console updates', () => { this.#paused = !this.#paused; this.pause.textContent = this.#paused ? 'Resume' : 'Pause'; this.pause.setAttribute('aria-pressed',String(this.#paused)); if (!this.#paused) this.render(); });
    this.pause.setAttribute('aria-pressed','false');
    this.toolbar.append(this.search, this.pause, control('Clear','Clear local console',()=>{ this.buffer.clear(); this.dropped = 0; this.unread = 0; this.errors = 0; this.#page = 0; this.#anchor = null; this.#expanded.clear(); this.list.replaceChildren(); this.render(); this.onUnread(0,0); }));
    this.auto = control('Auto-scroll','Console auto-scroll',()=>{ this.#scroll = !this.#scroll; if(this.#scroll){this.#page=0;this.#anchor=null;} this.auto.setAttribute('aria-pressed',String(this.#scroll)); this.render(); });this.auto.setAttribute('aria-pressed','true');
    this.toolbar.append(this.auto, control('Retry','Retry console connection',()=>{ this.#retry=0; this.requestRefresh(true); this.reconnect(); }));
    this.state = el('div','console-state','Connecting'); this.state.setAttribute('role','status'); this.state.setAttribute('aria-live','polite');
    this.list = el('div','console-list'); this.list.tabIndex = 0; this.list.setAttribute('role','log'); this.list.setAttribute('aria-live','off'); this.list.setAttribute('aria-label','Read-only React Native console');
    this.list.addEventListener('scroll',()=>{const bottom=this.list.scrollHeight-this.list.scrollTop-this.list.clientHeight<24;if(!bottom&&this.#scroll){this.#scroll=false;this.auto.setAttribute('aria-pressed','false');}if(!this.#scroll){const top=this.list.getBoundingClientRect().top;const row=[...this.list.children].find(r=>r.getBoundingClientRect().bottom>top);if(row)this.#anchor=Number(row.dataset.sequence);}});
    this.pager = el('div','console-pager');this.older=control('Older','Older retained console messages',()=>{this.#page++;this.#anchor=null;this.#scroll=false;this.auto.setAttribute('aria-pressed','false');this.render();});this.newer=control('Newer','Newer retained console messages',()=>{this.#page=Math.max(0,this.#page-1);this.#anchor=null;this.render();});this.count=el('span','console-count');this.pager.append(this.older,this.count,this.newer);
    element.append(this.toolbar,this.state,this.list,this.pager);
  }
  #status(state,message='') { if(this.#closed)return;this.state.textContent=state[0].toUpperCase()+state.slice(1)+(message?' · '+String(message).slice(0,512):'');this.state.dataset.state=state;this.onStatus(state); }
  setTarget(target,generation) {
    if(this.#closed)return;this.generation=generation;
    const changed=this.target?.key!==target?.key;this.target=target;
    if(changed){this.#epoch++;this.#lastSequence=0;this.#disconnect();this.#retry=0;}
    if(target&&(!this.#ws||this.#ws.readyState===WebSocket.CLOSED))this.#connect();
    else if(!target){this.#disconnect();this.#status('reconnecting','Target unavailable; waiting for shared discovery');}
  }
  #disconnect() {clearTimeout(this.#connectTimer);clearTimeout(this.#retryTimer);const ws=this.#ws;this.#ws=null;if(ws){ws.onclose=null;ws.onmessage=null;ws.onopen=null;ws.close();}}
  #connect() {
    if(this.#closed||!this.target)return;
    clearTimeout(this.#retryTimer);clearTimeout(this.#connectTimer);const target=this.target,epoch=this.#epoch;
    const ws=new WebSocket(`${location.protocol==='https:'?'wss:':'ws:'}//${location.host}/ws/metro-console`);this.#ws=ws;this.#lastSequence=0;this.#lastDrop=0;this.#status('connecting');
    this.#connectTimer=setTimeout(()=>ws.close(),8000);
    ws.onopen=()=>{if(this.#closed||this.#ws!==ws){ws.close();return;}clearTimeout(this.#connectTimer);ws.send(JSON.stringify({type:'attach',device_id:this.deviceId,target_key:target.key,generation:this.generation,confirmed:this.binding.confirmed===true}));};
    ws.onmessage=e=>{
      if(this.#closed||this.#ws!==ws||epoch!==this.#epoch||typeof e.data!=='string'||e.data.length>1_048_576)return;
      try{const m=JSON.parse(e.data);
        if(m.type==='entry'){
          const entry=safeEntry(m.entry);if(!entry)return;
          if(entry.sequence>this.#lastSequence){this.#lastSequence=entry.sequence;entry.local_key=++this.#rowSerial;this.buffer.push(entry);if(!this.#visible||this.#paused){this.unread++;if(entry.level==='error')this.errors++;}this.#scheduleRender();this.#notice();}
          if(Number.isSafeInteger(m.dropped)&&m.dropped>=this.#lastDrop){this.dropped+=m.dropped-this.#lastDrop;this.#lastDrop=m.dropped;}
          ws.send(JSON.stringify({type:'entry_ack',sequence:entry.sequence}));
        }else if(m.type==='status'&&['connecting','attached','reconnecting','disconnected','error'].includes(m.state)) {this.#status(m.state,m.message);if(m.state==='attached')this.#retry=0;}
        else if(m.type==='console_error'){this.#status('error',m.message);this.requestRefresh(false);}
        else if(m.type==='dropped'&&Number.isSafeInteger(m.count))this.dropped=Math.max(this.dropped,m.count);
      }catch{/* discard malformed console messages only */}
    };
    ws.onerror=()=>ws.close();ws.onclose=()=>{clearTimeout(this.#connectTimer);if(this.#closed||this.#ws!==ws)return;this.#status('reconnecting','Runtime disconnected');this.#retryTimer=setTimeout(()=>{this.requestRefresh(false);this.#connect();},Math.min(30000,1000*2**Math.min(5,this.#retry++)));};
  }
  reconnect(){if(this.#closed)return;this.#disconnect();this.#connect();}
  #notice(){if(this.#noticeTimer)return;this.#noticeTimer=setTimeout(()=>{this.#noticeTimer=null;if(!this.#closed)this.onUnread(this.unread,this.errors);},250);}
  #scheduleRender(){if(!this.#visible||this.#paused||this.#renderTimer)return;this.#renderTimer=setTimeout(()=>{this.#renderTimer=null;this.render();},100);}
  setVisible(visible){this.#visible=visible;if(!visible){clearTimeout(this.#renderTimer);this.#renderTimer=null;}else{if(!this.#paused){this.unread=0;this.errors=0;this.onUnread(0,0);}this.render();}}
  render(){
    if(this.#closed||!this.#visible||this.#paused)return;
    // Native toggle events are queued; capture their current state before replacing rows.
    for(const details of this.list.querySelectorAll('.console-details')){const key=Number(details.parentElement.dataset.sequence);if(details.open)this.#expanded.add(key);else this.#expanded.delete(key);}
    while(this.#expanded.size>300)this.#expanded.delete(this.#expanded.values().next().value);
    const entries=this.buffer.values.filter(e=>this.#levels.has(e.level)&&(!this.#query||e.text.toLowerCase().includes(this.#query)));
    const pages=Math.max(1,Math.ceil(entries.length/300));this.#page=Math.min(this.#page,pages-1);let end=Math.max(0,entries.length-this.#page*300),start=Math.max(0,end-300);
    if(!this.#scroll&&this.#anchor!=null){const index=entries.findIndex(e=>e.local_key===this.#anchor);if(index>=0){start=index;end=Math.min(entries.length,index+300);this.#page=Math.floor((entries.length-end)/300);}}
    if(!this.#scroll&&entries[start])this.#anchor=entries[start].local_key;
    const active=document.activeElement;
    const focusKey=this.list.contains(active)&&active.matches('.console-source-link, .console-details > summary')?active.closest('.console-row').dataset.sequence:null;
    const fragment=document.createDocumentFragment();let restoreFocus;
    for(const entry of entries.slice(start,end)){
      const row=el('div','console-row console-'+entry.level);row.dataset.sequence=entry.local_key;
      const head=el('div','console-row-head');const time=el('time','console-time',new Date(entry.timestamp_ms).toLocaleTimeString());head.append(time,el('span','console-level',entry.level),el('span','console-text',entry.text));row.append(head);
      if(entry.source||entry.stack.length){
        const details=el('details','console-details');details.id=`console-source-${this.#id}-${entry.local_key}`;details.open=this.#expanded.has(entry.local_key);details.hidden=!details.open;
        details.append(el('summary','',entry.source?`${entry.source.url}:${(entry.source.line||0)+1}:${(entry.source.column||0)+1}`:'Stack'));
        details.append(el('pre','',entry.stack.map(f=>`${f.function} (${f.url}:${f.line+1}:${f.column+1})`).join('\n')));row.append(details);
        const summary=details.firstElementChild;
        const link=el('button','console-source-link',entry.source?`${(entry.source.line||0)+1}:${(entry.source.column||0)+1}`:'Stack');link.type='button';link.hidden=details.open;link.title=summary.textContent;
        link.setAttribute('aria-label','Show source details '+link.textContent);link.setAttribute('aria-controls',details.id);link.setAttribute('aria-expanded',String(details.open));head.append(link);
        const sync=()=>{
          link.hidden=details.open;details.hidden=!details.open;link.setAttribute('aria-expanded',String(details.open));
          if(details.open){this.#expanded.add(entry.local_key);if(this.#expanded.size>300)this.#expanded.delete(this.#expanded.values().next().value);}else this.#expanded.delete(entry.local_key);
        };
        link.addEventListener('click',()=>{details.open=true;sync();summary.focus({preventScroll:true});});
        details.addEventListener('toggle',()=>{if(this.#closed||!this.list.contains(details))return;const focused=document.activeElement===summary;sync();if(!details.open&&focused)link.focus({preventScroll:true});});
        if(row.dataset.sequence===focusKey)restoreFocus=details.open?summary:link;
      }
      fragment.append(row);
    }
    this.list.replaceChildren(fragment);restoreFocus?.focus({preventScroll:true});if(!this.#scroll)this.list.scrollTop=0;this.older.disabled=this.#page>=pages-1;this.newer.disabled=this.#page===0;
    this.count.textContent=`${entries.length?start+1:0}–${end} / ${entries.length}${this.buffer.dropped+this.dropped?' · Dropped '+(this.buffer.dropped+this.dropped):''}`;
    if(this.#scroll&&this.#page===0)this.list.scrollTop=this.list.scrollHeight;
  }
  fit(){if(this.#visible)this.#scheduleRender();}
  focus(){this.list.focus();}
  setFontSize(size){this.element.style.setProperty('--console-font',size+'px');}
  destroy(){this.#closed=true;this.#epoch++;this.#disconnect();for(const t of [this.#renderTimer,this.#noticeTimer,this.#searchTimer])clearTimeout(t);this.buffer.clear();this.#expanded.clear();this.element.replaceChildren();}
}
