import {MetroObjectView,safeRemote} from './metro-objects.js';
let styles, consoleSerial = 0;
export function loadConsoleStyles() {
  return styles ||= new Promise((resolve, reject) => {
    const link = document.createElement('link'); link.rel = 'stylesheet'; link.href = '/css/metro-console.css';
    link.onload = resolve; link.onerror = () => { styles = null; link.remove(); reject(Error('Console styles unavailable')); }; document.head.append(link);
  });
}
export class ConsoleBuffer {
  entries = []; bytes = 0; dropped = 0; offset = 0;
  push(entry, reserved = 0) {
    const bytes = new TextEncoder().encode(JSON.stringify(entry)).length;
    if (bytes > 5_242_880) { this.dropped++; return; }
    this.entries.push({ entry, bytes }); this.bytes += bytes;
    while (this.entries.length > this.offset && (this.entries.length - this.offset > 5000 || this.bytes + reserved > 5_242_880)) { this.bytes -= this.entries[this.offset++].bytes; this.dropped++; }
    if (this.offset > 1024) { this.entries = this.entries.slice(this.offset); this.offset = 0; }
  }
  trim(reserved=0){while(this.entries.length>this.offset&&this.bytes+reserved>5_242_880){this.bytes-=this.entries[this.offset++].bytes;this.dropped++;}if(this.offset>1024){this.entries=this.entries.slice(this.offset);this.offset=0;}}
  get values() { return this.entries.slice(this.offset).map(v => v.entry); }
  clear() { this.entries = []; this.offset = 0; this.bytes = 0; this.dropped = 0; }
}
function el(tag, className, text) { const e = document.createElement(tag); e.className = className; if (text != null) e.textContent = text; return e; }
function control(text, label, fn) { const b = el('button', 'console-control', text); b.type = 'button'; b.setAttribute('aria-label', label); b.addEventListener('click', fn); return b; }
function safeEntry(e) {
  if (!e || !Number.isSafeInteger(e.sequence) || typeof e.text !== 'string' || e.text.length > 40000 || !['log', 'info', 'warn', 'error'].includes(e.level)) return null;
  return { arguments: (Array.isArray(e.arguments)?e.arguments:[]).slice(0,50).map(safeRemote), sequence: e.sequence, level: e.level, text: e.text, timestamp_ms: Number.isFinite(e.timestamp_ms) ? e.timestamp_ms : Date.now(),
    source: e.source && typeof e.source.url === 'string' ? { url: e.source.url.slice(0, 512), line: e.source.line, column: e.source.column } : null,
    stack: (Array.isArray(e.stack) ? e.stack : []).slice(0, 100).map(f => ({ url: String(f.url || '').slice(0, 512), line: Number(f.line) || 0, column: Number(f.column) || 0, function: String(f.function || '').slice(0, 256) })) };
}
export class MetroConsole {
  buffer = new ConsoleBuffer(); target = null; generation = 0; unread = 0; errors = 0; dropped = 0;
  #objectQueue=[]; #objectCurrent=null; #objectSerial=0;
  #ws; #closed = false; #visible = false; #paused = false; #scroll = true; #query = ''; #levels = new Set(['log','info','warn','error']);
  #anchor = null; #position = null; #pageKey = null; #pageSize = 300; #expanded = new Set(); #rowSerial = 0; #id = ++consoleSerial;
  #renderTimer; #noticeTimer; #retryTimer; #connectTimer; #searchTimer; #retry = 0; #lastDrop = 0; #lastSequence = 0; #epoch = 0;
  constructor(element, { deviceId, binding, onStatus = () => {}, onUnread = () => {}, requestRefresh = () => {} }) {
    this.element = element; this.deviceId = deviceId; this.binding = binding; this.onStatus = onStatus; this.onUnread = onUnread; this.requestRefresh = requestRefresh;
    element.classList.add('metro-console'); element.tabIndex = -1;
    this.objects=new MetroObjectView({element,request:ref=>this.#getProperties(ref),active:()=>!this.#closed&&this.#visible&&!this.#paused,onBytes:bytes=>this.buffer.trim(bytes)});
    this.toolbar = el('div','console-toolbar');
    for (const level of ['log','info','warn','error']) {
      const b = control(level[0].toUpperCase()+level.slice(1), 'Show '+level+' messages', () => { this.#levels.has(level) ? this.#levels.delete(level) : this.#levels.add(level); b.setAttribute('aria-pressed', String(this.#levels.has(level))); this.#pageKey = null; this.#pageSize = 300; this.#anchor = null; this.render(); });
      b.dataset.level = level; b.setAttribute('aria-pressed','true'); this.toolbar.append(b);
    }
    this.search = el('input','console-search'); this.search.type = 'search'; this.search.placeholder = 'Search console'; this.search.setAttribute('aria-label','Search console');
    this.search.addEventListener('input', () => { clearTimeout(this.#searchTimer); this.#searchTimer = setTimeout(() => { this.#query = this.search.value.slice(0, 256).toLowerCase(); this.#pageKey = null; this.#pageSize = 300; this.#anchor = null; this.render(); },150); });
    this.pause = control('Pause','Pause console updates', () => { this.#paused = !this.#paused; this.pause.textContent = this.#paused ? 'Resume' : 'Pause'; this.pause.setAttribute('aria-pressed',String(this.#paused)); if (!this.#paused) this.render(); });
    this.pause.setAttribute('aria-pressed','false');
    this.toolbar.append(this.search, this.pause, control('Clear','Clear local console',()=>{ this.objects.clear();this.#cancelObjectQueue();this.buffer.clear(); this.dropped = 0; this.unread = 0; this.errors = 0; this.#pageKey = null; this.#pageSize = 300; this.#anchor = null; this.#expanded.clear(); this.list.replaceChildren(); this.render(); this.onUnread(0,0); }));
    this.auto = control('Auto-scroll','Console auto-scroll',()=>{ this.#scroll = !this.#scroll; if(this.#scroll){this.#pageKey=null;this.#pageSize=300;this.#anchor=null;} this.auto.setAttribute('aria-pressed',String(this.#scroll)); this.render(); });this.auto.setAttribute('aria-pressed','true');
    this.toolbar.append(this.auto, control('Retry','Retry console connection',()=>{ this.#retry=0; this.requestRefresh(true); this.reconnect(); }));
    this.state = el('div','console-state','Connecting'); this.state.setAttribute('role','status'); this.state.setAttribute('aria-live','polite');
    this.list = el('div','console-list'); this.list.tabIndex = 0; this.list.setAttribute('role','log'); this.list.setAttribute('aria-live','off'); this.list.setAttribute('aria-label','Read-only React Native console');
    this.list.addEventListener('scroll',()=>this.#scrolled());
    this.pager = el('div','console-pager');
    const page=direction=>{this.#scroll=false;this.auto.setAttribute('aria-pressed','false');this.render(direction);};
    this.older=control('Older','Older retained console messages',()=>page(-1));this.newer=control('Newer','Newer retained console messages',()=>page(1));
    this.count=el('span','console-count');this.pager.append(this.older,this.count,this.newer);
    element.append(this.toolbar,this.state,this.list,this.pager);
  }
  // The retained page and the visible row/pixel offset are independent. Resize
  // only refits the existing DOM; it must never turn the visible tail into a page.
  #rememberScroll(){
    if(!this.#visible||!this.list.clientHeight)return;
    const top=this.list.getBoundingClientRect().top+this.list.clientTop;
    const row=[...this.list.children].find(r=>r.getBoundingClientRect().bottom>top);
    this.#anchor=row?{key:Number(row.dataset.sequence),offset:row.getBoundingClientRect().top-top}:null;
    this.#position={top:this.list.scrollTop,height:this.list.clientHeight,width:this.list.clientWidth,extent:this.list.scrollHeight};
  }
  #scrolled(){
    if(!this.#visible||!this.list.clientHeight)return;
    const p=this.#position;
    const layout=p&&(p.height!==this.list.clientHeight||p.width!==this.list.clientWidth||p.extent!==this.list.scrollHeight);
    if(this.#scroll){
      // Layout/clamping and our own scroll restoration also emit scroll events.
      // Only movement away from a known settled position can disable following.
      if(layout)this.list.scrollTop=this.list.scrollHeight;
      else if(p&&Math.abs(this.list.scrollTop-p.top)>.5&&this.list.scrollHeight-this.list.scrollTop-this.list.clientHeight>=24){this.#scroll=false;this.auto.setAttribute('aria-pressed','false');}
    }
    this.#rememberScroll();
  }
  #restoreScroll(anchor,top=0){
    if(!this.list.clientHeight)return;
    if(this.#scroll)this.list.scrollTop=this.list.scrollHeight;
    else{
      const row=anchor&&[...this.list.children].find(r=>Number(r.dataset.sequence)===anchor.key);
      if(row){
        const rect=row.getBoundingClientRect();
        // Widening/font reflow can make a formerly valid in-row offset too deep.
        const offset=Math.max(anchor.offset,Math.min(0,1-rect.height));
        this.list.scrollTop+=rect.top-this.list.getBoundingClientRect().top-this.list.clientTop-offset;
      }else this.list.scrollTop=anchor?0:top;
    }
    this.#rememberScroll();
  }
  #status(state,message='') { if(this.#closed)return;this.state.textContent=state[0].toUpperCase()+state.slice(1)+(message?' · '+String(message).slice(0,512):'');this.state.dataset.state=state;this.onStatus(state); }
  setTarget(target,generation) {
    if(this.#closed)return;this.generation=generation;
    const changed=this.target?.key!==target?.key;this.target=target;
    if(changed){this.#epoch++;this.#lastSequence=0;this.#disconnect();this.#retry=0;}
    if(target&&(!this.#ws||this.#ws.readyState===WebSocket.CLOSED))this.#connect();
    else if(!target){this.#disconnect();this.#status('reconnecting','Target unavailable; waiting for shared discovery');}
  }
  #getProperties(ref){return new Promise((resolve,reject)=>{if(this.#closed||this.#objectQueue.length>=32){reject(Error('Inspection unavailable'));return;}this.#objectQueue.push({ref,resolve,reject,id:String(this.#id)+'-'+(++this.#objectSerial)});this.#pumpObjects();});}
  #cancelObjectQueue(){for(const job of this.#objectQueue)job.reject(Error('Inspection cancelled'));this.#objectQueue=[];}
  #pumpObjects(){
    if(this.#objectCurrent||!this.#objectQueue.length)return;
    const job=this.#objectQueue.shift(),ws=this.#ws;
    if(!ws||ws.readyState!==WebSocket.OPEN||this.state.dataset.state!=='attached'){job.reject(Error('Object reference is unavailable while disconnected'));this.#pumpObjects();return;}
    this.#objectCurrent=job;job.timer=setTimeout(()=>{if(this.#objectCurrent===job){job.reject(Error('Object inspection timed out'));ws.close();}},7500);
    ws.send(JSON.stringify({type:'get_properties',request_id:job.id,object_ref:job.ref}));
  }
  #cancelObjects(){this.#cancelObjectQueue();const job=this.#objectCurrent;this.#objectCurrent=null;if(job){clearTimeout(job.timer);job.reject(Error('Object inspection disconnected'));}}
  #disconnect() {this.#cancelObjects();clearTimeout(this.#connectTimer);clearTimeout(this.#retryTimer);const ws=this.#ws;this.#ws=null;if(ws){ws.onclose=null;ws.onmessage=null;ws.onopen=null;ws.close();}}
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
          if(entry.sequence>this.#lastSequence){this.#lastSequence=entry.sequence;entry.local_key=++this.#rowSerial;this.buffer.push(entry,this.objects.bytes);if(!this.#visible||this.#paused){this.unread++;if(entry.level==='error')this.errors++;}this.#scheduleRender();this.#notice();}
          if(Number.isSafeInteger(m.dropped)&&m.dropped>=this.#lastDrop){this.dropped+=m.dropped-this.#lastDrop;this.#lastDrop=m.dropped;}
          ws.send(JSON.stringify({type:'entry_ack',sequence:entry.sequence}));
         }else if(m.type==='properties'&&this.#objectCurrent?.id===m.request_id){
          const job=this.#objectCurrent;job.resolve(m);ws.send(JSON.stringify({type:'properties_ack',request_id:job.id}));
        }else if(m.type==='properties_ready'&&this.#objectCurrent?.id===m.request_id){
          clearTimeout(this.#objectCurrent.timer);this.#objectCurrent=null;this.#pumpObjects();
        }else if(m.type==='status'&&['connecting','attached','reconnecting','disconnected','error'].includes(m.state)) {this.#status(m.state,m.message);if(m.state==='attached')this.#retry=0;}
        else if(m.type==='console_error'){this.#status('error',m.message);this.requestRefresh(false);}
        else if(m.type==='dropped'&&Number.isSafeInteger(m.count))this.dropped=Math.max(this.dropped,m.count);
      }catch{/* discard malformed console messages only */}
    };
    ws.onerror=()=>ws.close();ws.onclose=()=>{clearTimeout(this.#connectTimer);if(this.#closed||this.#ws!==ws)return;this.#cancelObjects();this.#status('reconnecting','Runtime disconnected');this.#retryTimer=setTimeout(()=>{this.requestRefresh(false);this.#connect();},Math.min(30000,1000*2**Math.min(5,this.#retry++)));};
  }
  reconnect(){if(this.#closed)return;this.#disconnect();this.#connect();}
  #notice(){if(this.#noticeTimer)return;this.#noticeTimer=setTimeout(()=>{this.#noticeTimer=null;if(!this.#closed)this.onUnread(this.unread,this.errors);},250);}
  #scheduleRender(){if(!this.#visible||this.#paused||this.#renderTimer)return;this.#renderTimer=setTimeout(()=>{this.#renderTimer=null;this.render();},100);}
  setVisible(visible){this.#visible=visible;if(!visible){clearTimeout(this.#renderTimer);this.#renderTimer=null;}else{if(!this.#paused){this.unread=0;this.errors=0;this.onUnread(0,0);}this.render();}}
  render(page=0){
    if(this.#closed||!this.#visible||this.#paused)return;
    const keepPosition=!this.#scroll&&this.#pageKey!=null&&!page;
    if(keepPosition)this.#rememberScroll();
    const anchor=keepPosition?this.#anchor:null,previousTop=keepPosition?this.list.scrollTop:0;
    this.objects.capture();this.objects.prune(new Set(this.buffer.values.map(e=>e.local_key)));
    // Native toggle events are queued; capture their current state before replacing rows.
    for(const details of this.list.querySelectorAll('.console-details')){const key=Number(details.parentElement.dataset.sequence);if(details.open)this.#expanded.add(key);else this.#expanded.delete(key);}
    while(this.#expanded.size>300)this.#expanded.delete(this.#expanded.values().next().value);
    const entries=this.buffer.values.filter(e=>this.#levels.has(e.level)&&(!this.#query||e.text.toLowerCase().includes(this.#query)));
    const latest=this.#scroll||this.#pageKey==null,index=entries.findIndex(e=>e.local_key===this.#pageKey);
    if(latest||index<0)this.#pageSize=300;
    let start=latest?Math.max(0,entries.length-300):Math.max(0,index),end=Math.min(entries.length,start+this.#pageSize);
    if(page<0&&start>0){end=start;start=Math.max(0,end-300);this.#pageSize=end-start;}
    else if(page>0&&end<entries.length){start=end;end=Math.min(entries.length,start+300);this.#pageSize=300;}
    this.#pageKey=entries[start]?.local_key??null;
    const active=document.activeElement;
    const objectFocus=active?.matches('.console-object-summary')?active.parentElement.dataset.nodeKey:null;
    const focusKey=this.list.contains(active)&&active.matches('.console-source-link, .console-details > summary')?active.closest('.console-row').dataset.sequence:null;
    const fragment=document.createDocumentFragment();let restoreFocus;
    for(const entry of entries.slice(start,end)){
      const row=el('div','console-row console-'+entry.level);row.dataset.sequence=entry.local_key;
      const head=el('div','console-row-head');const time=el('time','console-time',new Date(entry.timestamp_ms).toLocaleTimeString());const text=el('span','console-text');
      if((entry.arguments||[]).some(v=>v.object_ref)){(entry.arguments||[]).forEach((v,i)=>{if(i)text.append(document.createTextNode(' '));text.append(this.objects.value(v,String(entry.local_key)+':arg'+i));});}
      else text.textContent=entry.text;
      head.append(time,el('span','console-level',entry.level),text);row.append(head);
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
    this.list.replaceChildren(fragment);if(objectFocus)this.list.querySelector(`[data-node-key="${CSS.escape(objectFocus)}"] > summary`)?.focus({preventScroll:true});restoreFocus?.focus({preventScroll:true});this.older.disabled=start===0;this.newer.disabled=end>=entries.length;
    this.count.textContent=`${entries.length?start+1:0}–${end} / ${entries.length}${this.buffer.dropped+this.dropped?' · Dropped '+(this.buffer.dropped+this.dropped):''}`;
    this.#restoreScroll(anchor,previousTop);
  }
  fit(){if(!this.#closed&&this.#visible)this.#restoreScroll(this.#anchor,this.#position?.top??this.list.scrollTop);}
  focus(){this.list.focus();}
  setFontSize(size){this.element.style.setProperty('--console-font',size+'px');this.fit();}
  destroy(){this.#closed=true;this.#epoch++;this.#disconnect();for(const t of [this.#renderTimer,this.#noticeTimer,this.#searchTimer])clearTimeout(t);this.objects.clear();this.buffer.clear();this.#expanded.clear();this.element.replaceChildren();}
}
