// Read-only, lazy RemoteObject views. Native details provide mouse/touch/keyboard
// disclosure; fetched data is bounded and never persisted or evaluated here.
const node = (tag, cls, text) => { const e=document.createElement(tag);e.className=cls;if(text!=null)e.textContent=text;return e; };
export function safeRemote(v) {
  if(!v||typeof v!=='object')return {type:'undefined',value:'undefined'};
  const text=(s,n)=>typeof s==='string'?s.slice(0,n):'';
  const result={type:text(v.type,32)};
  for(const[k,n]of[['subtype',128],['description',4096]])if(text(v[k],n))result[k]=text(v[k],n);
  if(['string','number','boolean'].includes(typeof v.value)||v.value===null)result.value=typeof v.value==='string'?v.value.slice(0,1024):v.value;
  if(typeof v.object_ref==='string'&&v.object_ref.length<=64)result.object_ref=v.object_ref;
  if(Array.isArray(v.preview)&&v.preview.length)result.preview=v.preview.slice(0,20).map(p=>({name:text(p.name,80),value:text(p.value,80),type:text(p.type,32)}));
  if(v.preview_overflow===true)result.preview_overflow=true;
  return result;
}
export function remoteText(v) {
  if(v.subtype==='null'||v.value===null)return 'null';
  return v.description||String(v.value===undefined?'undefined':v.value);
}
export class MetroObjectView {
  bytes=0; #cache=new Map();#pending=new Map();#states=new Map();#generation=0;
  constructor({element,request,active,onBytes}){this.element=element;this.request=request;this.active=active;this.onBytes=onBytes;}
  capture(){for(const d of this.element.querySelectorAll('.console-object[data-node-key]')){let s=this.#states.get(d.dataset.nodeKey)||d._objectState;if(s){s.open=d.open;if(d.open)this.#remember(d.dataset.nodeKey,s);}}}
  prune(keys){for(const k of this.#states.keys())if(!keys.has(Number(k.split(':')[0])))this.#states.delete(k);}
  clear(){this.#generation++;this.#cache.clear();this.#pending.clear();this.#states.clear();this.bytes=0;this.onBytes(0);}
  #put(ref,result){
    let bytes=new TextEncoder().encode(JSON.stringify(result)).length;
    while(bytes>131072&&result.properties?.length){result.properties.pop();result.truncated=true;bytes=new TextEncoder().encode(JSON.stringify(result)).length;}
    if(bytes>131072)return;
    const old=this.#cache.get(ref);if(old)this.bytes-=old.bytes;
    this.#cache.delete(ref);this.#cache.set(ref,{result,bytes});this.bytes+=bytes;
    while(this.#cache.size>128||this.bytes>1_048_576){const k=this.#cache.keys().next().value;this.bytes-=this.#cache.get(k).bytes;this.#cache.delete(k);}
    this.onBytes(this.bytes);
  }
  #load(ref){
    if(this.#pending.has(ref))return this.#pending.get(ref);
    if(this.#pending.size>=32)return Promise.resolve({error:'Too many expanded objects; collapse some and retry'});
    const generation=this.#generation;
    const p=this.request(ref).then(r=>({properties:(Array.isArray(r.properties)?r.properties:[]).slice(0,1128).map(p=>({name:String(p.name||'').slice(0,1024),...p.internal===true?{internal:true}:{},...p.wasThrown===true?{wasThrown:true}:{},
      ...Object.fromEntries(['value','get','set','symbol'].filter(k=>p[k]).map(k=>[k,safeRemote(p[k])]))})),truncated:r.truncated===true,...r.error?{error:String(r.error).slice(0,512)}:{}}),e=>({error:String(e.message||e).slice(0,512)})).then(r=>{
      if(generation===this.#generation){this.#put(ref,r);this.#pending.delete(ref);}return r;
    });this.#pending.set(ref,p);return p;
  }
  #remember(key,state){
    if(!this.#states.has(key)&&this.#states.size>=2048){const old=[...this.#states].find(([,s])=>!s.open);if(old)this.#states.delete(old[0]);else return false;}
    this.#states.set(key,state);return true;
  }
  value(v,key,depth=0,ancestors=new Set()){
    const text=remoteText(v), type=['string','number','boolean','undefined','bigint','symbol','object','function'].includes(v.type)?v.type:'object';
    if(!v.object_ref){const e=node('span','console-object-value',v.type==='string'&&depth>0?JSON.stringify(text):text);e.dataset.type=type;return e;}
    if(ancestors.has(v.object_ref))return node('span','console-object-value',text+' [Circular reference]');
    if(depth>=12)return node('span','console-object-note','[Inspection depth limit]');
    if(!this.#states.has(key)){
      if(!this.#remember(key,{open:false,attempted:false,page:0}))return node('span','console-object-note',text+' [Inspection view limit]');
    }
    const state=this.#states.get(key),d=node('details','console-object');d.dataset.nodeKey=key;d._objectState=state;d.open=state.open;
    const summary=node('summary','console-object-summary');summary.title='Properties are evaluated when expanded, not frozen at log time';
    summary.append(node('span','console-object-description',text));
    if(v.preview?.length)summary.append(node('span','console-object-preview',' {'+v.preview.map(p=>p.name+': '+p.value).join(', ')+(v.preview_overflow?', …':'')+'}'));
    const info=node('span','console-object-info',' ⓘ');info.title=summary.title;summary.append(info);d.append(summary);
    const body=node('div','console-object-body');d.append(body);const generation=this.#generation,seen=new Set(ancestors);seen.add(v.object_ref);
    const populate=()=>{
      if(generation!==this.#generation)return;
      const cached=this.#cache.get(v.object_ref)?.result;
      body.replaceChildren();
      if(!cached){
        body.append(node('span','console-object-note',this.#pending.has(v.object_ref)?'Loading…':state.attempted?'Properties no longer cached; expand again to reload':'Loading…'));
        if(!state.attempted&&this.active()){
          state.attempted=true;this.#load(v.object_ref).then(()=>{if(generation===this.#generation&&this.active()&&this.element.contains(d)&&d.open)populate();});
        }else if(this.#pending.has(v.object_ref))this.#pending.get(v.object_ref).then(()=>{if(generation===this.#generation&&this.active()&&this.element.contains(d)&&d.open)populate();});
        return;
      }
      if(cached.error){
        body.append(node('span','console-object-note',cached.error));const retry=node('button','console-control','Retry inspection');retry.type='button';
        retry.onclick=()=>{if(!this.active())return;this.bytes-=this.#cache.get(v.object_ref)?.bytes||0;this.#cache.delete(v.object_ref);this.onBytes(this.bytes);state.attempted=false;populate();};body.append(retry);return;
      }
      const props=cached.properties||[];state.page=Math.min(state.page,Math.max(0,Math.ceil(props.length/100)-1));
      let rendered=this.element.querySelectorAll('.console-object-property').length;
      for(let i=state.page*100;i<Math.min(props.length,(state.page+1)*100);i++){
        if(rendered++>=2000){body.append(node('span','console-object-note','Inspection view limit reached'));break;}
        const p=props[i],line=node('div','console-object-property');line.append(node('span','console-object-name',p.name+': '));
        if(p.value)line.append(this.value(p.value,key+':'+i,depth+1,seen));
        else line.append(node('span','console-object-note',p.get&&p.set?'[Getter/Setter — not evaluated]':p.get?'[Getter — not evaluated]':p.set?'[Setter]':'undefined'));
        if(p.wasThrown)line.append(node('span','console-object-note',' [Thrown]'));body.append(line);
      }
      if(!props.length)body.append(node('span','console-object-note','No own properties'));
      if(cached.truncated)body.append(node('div','console-object-note','Property response truncated by safety limits'));
      if(props.length>100){const pager=node('div','console-object-pager');for(const [label,change]of[['Previous fields',-1],['Next fields',1]]){const b=node('button','console-control',label);b.type='button';b.disabled=change<0?state.page===0:(state.page+1)*100>=props.length;b.onclick=()=>{state.page+=change;populate();};pager.append(b);}pager.append(node('span','console-object-note',`${state.page*100+1}–${Math.min(props.length,(state.page+1)*100)} / ${props.length}`));body.append(pager);}
    };
    d.addEventListener('toggle',()=>{if(generation!==this.#generation||!this.element.contains(d))return;const changed=state.open!==d.open;state.open=d.open;this.#remember(key,state);if(changed&&d.open){if(!this.#cache.has(v.object_ref)&&!this.#pending.has(v.object_ref))state.attempted=false;populate();}});
    if(d.open)populate();return d;
  }
}
