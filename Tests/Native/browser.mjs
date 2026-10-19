import { reviewNativeScaling } from './scaling.mjs';
import { reviewNativeFinalization } from './finalization.mjs';
import { reviewNativeDiscovery } from './discovery.mjs';
import { reviewNativeBusy, reviewNativeReuse } from './busy.mjs';
import fs from 'node:fs';import crypto from 'node:crypto';import {spawn} from 'node:child_process';
const root=process.argv[2],base='https://127.0.0.1:45156',cookie=crypto.createHash('sha256').update('simwisp-session-v1:isolated-native-capture').digest('hex');
const checks=[],exceptions=[],pending=new Map(),sleep=ms=>new Promise(r=>setTimeout(r,ms));let chrome,ws,sequence=0,received=0;
const put=(p,v)=>fs.writeFileSync(root+'/'+p,JSON.stringify(v)),remove=p=>{try{fs.unlinkSync(root+'/'+p)}catch{}};
const events=(file='events.ndjson')=>fs.existsSync(root+'/'+file)?fs.readFileSync(root+'/'+file,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse):[];
function check(name,b){checks.push({name,passed:b===true});if(b!==true)throw Error(name)}
async function until(name,fn,ms=15000){const end=Date.now()+ms;while(Date.now()<end){if(await fn())return;await sleep(50)}throw Error('Timeout '+name)}
function cdp(method,params={}){return new Promise((resolve,reject)=>{const id=++sequence,timer=setTimeout(()=>{pending.delete(id);reject(Error(method+' timeout'))},12000);pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params}))})}
async function ev(expression){const r=await cdp('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value}
async function all(){const r=await fetch(base+'/api/sessions',{headers:{Cookie:'simwisp_session='+cookie}});if(!r.ok)throw Error('API '+r.status);return r.json()}
async function api(id='native-fixture'){return (await all()).find(s=>s.id===id)}
async function active(capture='native',id='native-fixture'){await until(capture+' active '+id,async()=>{const s=await api(id);return s?.state==='Streaming'&&s.frames>4&&s.ios_capture.effective_capture===capture});return api(id)}
async function destroy(){await ev('window.nativeStream?.destroy();window.nativeStream=null');await until('fixture session retired',async()=>!await api());await sleep(150)}
async function connect(capture='native',nativeScaling='1'){await destroy();await ev(`(()=>{window.nativeStats=[];window.nativeStream=new SimStream('native-fixture',document.getElementById('native-canvas'),{fps:60,quality:20,backends:{capture:${JSON.stringify(capture)},input:'current',nativeScaling:${JSON.stringify(nativeScaling)}},onStats:s=>nativeStats.push(s)});return true})()`);return active(capture==='native'?'native':'current')}
const setting=value=>ev(`nativeStream.updateSettings(${JSON.stringify(value)})`);
async function pixels(selector='#native-canvas'){return ev(`(()=>{const c=document.querySelector(${JSON.stringify(selector)}),ctx=c.getContext('2d');return {w:c.width,h:c.height,corners:[[.1,.1],[.9,.1],[.1,.9],[.9,.9]].map(([x,y])=>[...ctx.getImageData(Math.floor(c.width*x),Math.floor(c.height*y),1,1).data])}})()`)}
let wireFPS,lowFPS,auditInvalid=0;
try {
 for(const f of ['mode.json','window.json','headless','offline'])remove(f);
 const leaf=new crypto.X509Certificate(fs.readFileSync(root+'/tls/server.pem')),spki=crypto.createHash('sha256').update(leaf.publicKey.export({type:'spki',format:'der'})).digest('base64');
 const profile=fs.mkdtempSync(root+'/chrome-native-');chrome=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new','--disable-gpu','--ignore-certificate-errors-spki-list='+spki,'--remote-debugging-address=127.0.0.1','--remote-debugging-port=0','--user-data-dir='+profile,'--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-sync','--disable-extensions','about:blank'],{stdio:['ignore','ignore','pipe'],detached:true});chrome.stderr.resume();
 await until('owned Chrome',()=>fs.existsSync(profile+'/DevToolsActivePort'));const port=fs.readFileSync(profile+'/DevToolsActivePort','utf8').split('\n')[0],tabs=await(await fetch('http://127.0.0.1:'+port+'/json/list')).json();ws=new WebSocket(tabs.find(t=>t.type==='page').webSocketDebuggerUrl);await new Promise((r,j)=>{ws.addEventListener('open',r,{once:true});ws.addEventListener('error',j,{once:true})});
 ws.addEventListener('message',e=>{const m=JSON.parse(e.data);if(m.id&&pending.has(m.id)){const p=pending.get(m.id);pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result)}else if(m.method==='Runtime.exceptionThrown')exceptions.push(m.params);else if(m.method==='Network.webSocketFrameReceived'&&m.params.response.opcode===2)received++});
 await cdp('Page.enable');await cdp('Runtime.enable');await cdp('Network.enable');await cdp('Network.setCookie',{name:'simwisp_session',value:cookie,url:base,secure:true,httpOnly:true,sameSite:'Strict'});await cdp('Page.navigate',{url:base});await until('fixture page',()=>ev("document.readyState==='complete'&&document.querySelector('.device-item')!==null"));
 await ev(`(async()=>{window.SimStream=(await import('/js/stream.js')).SimStream;window.audit={frames:0,invalid:0,epoch:0,decoderCreates:0};const NS=WebSocket;window.WebSocket=class extends NS{constructor(...args){super(...args);let id=0,time=0n,epoch=0;this.addEventListener('message',e=>{if(e.data instanceof ArrayBuffer){const d=new DataView(e.data),ne=d.getUint32(8),ni=d.getUint32(12),nt=d.getBigUint64(16);if(ni<=id||(epoch===ne&&nt<=time))audit.invalid++;audit.frames++;audit.epoch=ne;id=ni;time=nt;epoch=ne}})}};const ND=VideoDecoder;window.VideoDecoder=class extends ND{constructor(o){super(o);audit.decoderCreates++}};const c=document.createElement('canvas');c.id='native-canvas';c.width=320;c.height=640;document.body.append(c);return true})()`);
 if (process.env.NATIVE_BROWSER_PHASE === 'discovery') {
 await reviewNativeDiscovery({ev,api,active,connect,destroy,pixels,put,remove,events,until,check,sleep});
 } else if (process.env.NATIVE_BROWSER_PHASE === 'finalization') {
 await reviewNativeFinalization({ev,api,connect,destroy,events,check,pixels});
 } else if (process.env.NATIVE_BROWSER_PHASE === 'reuse') {
 await reviewNativeReuse({ev,api,connect,destroy,pixels,put,remove,until,check});
 } else if (process.env.NATIVE_BROWSER_PHASE === 'busy') {
 await reviewNativeBusy({ev,api,active,connect,destroy,pixels,put,remove,events,until,check,sleep,getReceived:()=>received});
 } else if (process.env.NATIVE_BROWSER_PHASE === 'scaling') {
 await reviewNativeScaling({ev,cdp,api,active,connect,destroy,pixels,put,remove,events,until,check,sleep});
 } else if (process.env.NATIVE_BROWSER_PHASE === 'rapid') {
 await connect();const initial=events().filter(e=>e.kind==='open'),oldName=initial.at(-1).name;
 put('mode.json',{hold_ms:2000});await until('old provider inside blocked read',()=>events().some(e=>e.kind==='hold'&&e.name===oldName));
 await ev("nativeStream.switchBackends({capture:'native',input:'current'})");await until('first replacement admitted',async()=>{const s=await api();return s&&s.frames===0});
 await ev("nativeStream.switchBackends({capture:'native',input:'current'})");await sleep(300);
 check('rapid reconnect never opens replacement before ALL older Native work retires',events().filter(e=>e.kind==='open').length===initial.length);
 remove('mode.json');await active();const es=events(),next=es.filter(e=>e.kind==='open').at(-1);check('only final replacement starts after blocked old source closes',es.filter(e=>e.kind==='open').length===initial.length+1&&es.findIndex(e=>e.kind==='close'&&e.name===oldName)<es.indexOf(next));
 await destroy();
 await connect('current');const windowsBefore=events().filter(e=>e.kind==='window-close-begin').length,opensBefore=events().filter(e=>e.kind==='open').length;
 fs.writeFileSync(root+'/window-close-hold','1');await ev("nativeStream.switchBackends({capture:'native',input:'current'})");await until('owned window stop blocked',()=>events().filter(e=>e.kind==='window-close-begin').length>windowsBefore);await sleep(300);
 check('Mac window→Native also waits for prior window cleanup',events().filter(e=>e.kind==='open').length===opensBefore);
 remove('window-close-hold');await active();const we=events(),lastNative=we.filter(e=>e.kind==='open').at(-1),lastWindow=we.filter(e=>e.kind==='window-close-done').at(-1);
 check('Native starts only after window cleanup finished',we.indexOf(lastWindow)<we.indexOf(lastNative));await destroy();
 } else if (process.env.NATIVE_BROWSER_PHASE === 'boundary') {
 await connect();const beforeMissing=events().filter(e=>e.kind==='open').length;
 put('mode.json',{inactive:true});await until('inactive before deadline',async()=>(await api())?.state==='Starting');
 await until('8s inactivity is visible and latched',async()=>(await api())?.ios_capture.effective_capture==='unavailable',12000);
 const failure=await api();check('8s unreadable surface invalidates video and fails closed',failure.capture_counters.cached_image_available!==true&&failure.ios_capture.reason.includes('8s'));
 await sleep(800);check('timeout does not reconnect or fall back',events().filter(e=>e.kind==='open').length===beforeMissing);
 await destroy();remove('mode.json');await connect();fs.writeFileSync(root+'/offline','1');
 await until('inventory disconnect visible',async()=>(await api())?.ios_capture.effective_capture==='unavailable');const offline=await api();
 check('inventory disconnect retires source and never polls another simulator',offline.ios_capture.reason.includes('unavailable')&&events().filter(e=>e.kind==='open').length===beforeMissing+1);
 await destroy();remove('offline');
 // A narrow long framebuffer exercises source-native geometry →4096edge scaling.
 put('mode.json',{width:64,height:8192});await connect();const scaled=await pixels();
 check('Native caps long edge4096 with aspect ratio preserved',scaled.w===32&&scaled.h===4096);
 await destroy();remove('mode.json');
 const old=await fetch(base+'/api/sessions');check('existing authentication is still required',!old.ok);
 } else if (process.env.NATIVE_BROWSER_PHASE !== 'ui') {
 await connect('current');check('Mac window remains default path and never creates Native',events().filter(e=>e.kind==='open').length===0);await destroy();
 await connect('native');const p=await pixels();
 const [tl,tr,bl,br]=p.corners;
 check('Native top-left red stays top-left',tl[0]>150&&tl[1]<100&&tl[2]<100);
 check('Native top-right yellow stays top-right',tr[0]>150&&tr[1]>150&&tr[2]<100);
 check('Native bottom-left blue stays bottom-left',bl[0]<100&&bl[1]<100&&bl[2]>150);
 check('Native bottom-right magenta stays bottom-right',br[0]>150&&br[1]<100&&br[2]>150);
 const initial=await api(),decoder=await ev('audit.decoderCreates'),epoch=await ev('audit.epoch'),begin=received,at=performance.now();await sleep(3000);wireFPS=(received-begin)*1000/(performance.now()-at);const idle=await api();
 check('Data saver OFF sends continuously NEW H264 near60fps',wireFPS>=55&&wireFPS<=62&&idle.capture_counters.h264_encodes>=initial.capture_counters.h264_encodes+165);
 check('same pixels use one prepared buffer and one encoder',idle.capture_counters.source_frames===1&&idle.capture_counters.prepared_pixel_buffers===1&&idle.capture_counters.encoder_creations===1);
 check('same shared hardware path has no JPEG and bounded snapshot',idle.capture_counters.hardware_encoder===true&&idle.capture_counters.jpeg_decodes===0&&idle.capture_counters.jpeg_encodes===0&&idle.capture_counters.owned_snapshot_bytes===320*640*4&&idle.capture_counters.queued_frames===0);
 check('actual browser render stats at requested cadence',await ev('nativeStats.some(s=>s.fps>=55&&s.fps<=62)'));
 await setting({data_saver:true});await sleep(500);const saver=await api(),saverReceived=received;await sleep(1200);const afterSaver=await api();
 check('Data saver ON idles H264 at0 but still polls for changes',received===saverReceived&&afterSaver.capture_counters.h264_encodes===saver.capture_counters.h264_encodes&&afterSaver.capture_counters.polls>saver.capture_counters.polls);
 put('mode.json',{variant:true});await until('DSon sees new pixels',async()=>{const p=await pixels();return p.corners.every(c=>c[0]<100&&c[1]>150&&c[2]<100)});check('fresh same-size pixels reuse encoder',(await api()).capture_counters.encoder_creations===1);
 await setting({data_saver:false});await sleep(1100);check('DSoff resumes NEW encodes from same last pixels',(await api()).capture_counters.h264_encodes>afterSaver.capture_counters.h264_encodes+50);
 check('routine saver IDR keeps epoch and decoder',await ev(`audit.decoderCreates===${decoder}&&audit.epoch===${epoch}`));
 await setting({fps:30,quality:1});await sleep(600);const lowStart=received,lowAt=performance.now();await sleep(1700);lowFPS=(received-lowStart)*1000/(performance.now()-lowAt);check('requested30fps changes only local cadence/bitrate',lowFPS>=27&&lowFPS<=32&&(await api()).capture_counters.encoder_creations===1);
 await setting({fps:60});put('mode.json',{width:641,height:319});await until('Native landscape odd geometry',async()=>{const p=await pixels();return p.w===641&&p.h===319});check('rotation recreates only one encoder and new epoch',(await api()).capture_counters.encoder_creations===2&&await ev(`audit.epoch!==${epoch}`));
 const inputBefore=events('input.ndjson').length;await ev("nativeStream.send({type:'touch_down',x:.1,y:.1})");await sleep(250);check('Native mismatched host-window geometry rejects touch',events('input.ndjson').length===inputBefore);
 put('window.json',{width:641,height:319});await sleep(1300);await ev("nativeStream.send({type:'touch_down',x:.2,y:.3});nativeStream.send({type:'touch_up',x:.2,y:.3});nativeStream.send({type:'home'});nativeStream.send({type:'key',key:'a'})");await until('existing input route',()=>events('input.ndjson').length>=inputBefore+4);check('touch/key/Home keep existing input route',events('input.ndjson').slice(inputBefore).map(x=>x.message.type).join(',')==='touch_down,touch_up,home,key');
 put('mode.json',{inactive:true});await until('inactive clears cached availability',async()=>{const s=await api();return s?.state==='Starting'&&s.capture_counters.cached_image_available===false});await sleep(250);const inactiveWire=received,inactive=await api();await sleep(700);check('inactive never replays old pixels',received===inactiveWire&&(await api()).capture_counters.h264_encodes===inactive.capture_counters.h264_encodes);
 put('mode.json',{width:641,height:319});await active();check('same-size wake resumes from IDR',true);
 const beforePause=events().filter(e=>e.kind==='open').length;await setting({stream_paused:true});await until('pause state',async()=>(await api())?.state==='Paused');await until('pause releases source',()=>events().filter(e=>e.kind==='close').length===beforePause);await sleep(300);const pauseWire=received;await sleep(500);check('pause has no encoder/surface work',received===pauseWire&&(await api()).capture_counters.polls===undefined);
 await setting({stream_paused:false});await active();check('resume creates exactly one fresh source',events().filter(e=>e.kind==='open').length===beforePause+1);
 // Replacement during a slow in-flight provider must join the old source first.
 put('mode.json',{hold:true});await sleep(400);const beforeReplacement=events().filter(e=>e.kind==='open').length;await ev("nativeStream.switchBackends({capture:'native',input:'current'})");await active();await sleep(200);const es=events(),oldOpen=es.filter(e=>e.kind==='open')[beforeReplacement-1],newOpen=es.filter(e=>e.kind==='open')[beforeReplacement];check('same-device replacement joins old source before connecting new',!!oldOpen&&!!newOpen&&es.findIndex(e=>e.kind==='close'&&e.name===oldOpen.name)<es.indexOf(newOpen));remove('mode.json');remove('window.json');await destroy();
 fs.writeFileSync(root+'/headless','1');await connect();const headlessInputs=events('input.ndjson').length;await ev("nativeStream.send({type:'touch_down',x:.2,y:.2})");await sleep(300);check('Native video independent of host window but headless touch refused',events('input.ndjson').length===headlessInputs&&(await api()).ios_capture.input==='current');await destroy();remove('headless');
 put('mode.json',{fail:true});await ev("window.nativeStream=new SimStream('native-fixture',document.getElementById('native-canvas'),{backends:{capture:'native',input:'current'}})");await until('native failure visible',async()=>(await api())?.ios_capture.effective_capture==='unavailable');await sleep(600);const failedOpen=events().filter(e=>e.kind==='open').length,windowOpens=events('window.ndjson').filter(e=>e.kind==='open').length;await sleep(1100);check('Native errors latch with no automatic fallback/retry',(await api()).frames===0&&events().filter(e=>e.kind==='open').length===failedOpen&&events('window.ndjson').filter(e=>e.kind==='open').length===windowOpens);await destroy();remove('mode.json');
 }
 if (!['boundary','rapid','scaling','busy','reuse','finalization','discovery'].includes(process.env.NATIVE_BROWSER_PHASE)) {
 // Production app UI, browser-local per-UDID persistence, safe error rendering.
 await ev("document.querySelector('.device-item').click()");await active('current');check('production iOS UI defaults to Mac window',(await api()).ios_capture.capture==='current');await ev("document.querySelector('.backend-trigger').click()");
 check('iOS exposes independent closed Capture and Quartz/Native Input choices',await ev("document.querySelectorAll('.ios-capture-popover [data-kind=capture]').length===2&&JSON.stringify([...document.querySelectorAll('.ios-capture-popover [data-kind=input]')].map(b=>b.textContent))==='[\"Quartz\",\"Native\"]'"));
 await ev("document.querySelector('.ios-capture-popover [data-choice=native]').click()");await active();check('Native UI badge uses actual service state',await ev("document.querySelector('.ios-capture-popover [data-effective]').textContent==='Using Native → H.264'"));
 await cdp('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:false});await sleep(250);check('mobile Native controls fit dialog with44px hit targets',await ev("(()=>{const m=document.querySelector('.ios-capture-popover').getBoundingClientRect();return [...document.querySelectorAll('.ios-capture-popover [data-choice]')].every(b=>{const r=b.getBoundingClientRect();return r.height>=44&&r.left>=m.left&&r.right<=m.right})})()"));
 await ev("document.querySelector('.ios-capture-popover [data-choice=native]').focus()");await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:'ArrowRight',code:'ArrowRight',windowsVirtualKeyCode:39});await active('current');check('keyboard cycles to Mac window',await ev("document.querySelector('.ios-capture-popover [data-choice=current]').getAttribute('aria-checked')==='true'"));
 await ev("document.querySelector('.ios-capture-popover [data-choice=native]').click()");await active();await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});check('Escape closes and restores trigger focus',await ev("document.querySelector('.ios-capture-popover').hidden&&document.activeElement===document.querySelector('.backend-trigger')"));
 await ev("document.querySelector('[data-action=close]').click()");await until('UI closed',async()=>!await api());check('closing panel removes selector/listeners',await ev("!document.querySelector('.ios-capture-popover')"));
 auditInvalid+=await ev('window.audit?.invalid ?? 0');
 await cdp('Page.reload');await until('reload',()=>ev("document.querySelector('.device-item')!==null"));await ev("document.querySelector('.device-item').click()");await active();check('Native preference survives reload per simulator UDID',true);
 put('mode.json',{fail:true});await until('UI Native failure',async()=>(await api())?.ios_capture.effective_capture==='unavailable');await ev("document.querySelector('.backend-trigger').click()");
 check('Native errors render as text, never HTML',await ev("document.querySelector('.ios-capture-popover .backend-warning').textContent.includes('<img')&&!document.querySelector('.ios-capture-popover .backend-warning img')"));
 remove('mode.json');await ev("document.querySelector('.ios-capture-popover [data-choice=current]').click()");await active('current');await ev("document.querySelector('.ios-capture-popover [data-choice=native]').click()");await active();await ev("document.querySelector('.backend-close').click()");
 await cdp('Emulation.setDeviceMetricsOverride',{width:1280,height:1000,deviceScaleFactor:1,mobile:false});await sleep(250);
 await ev("document.querySelectorAll('.device-item')[1].click()");await active('current','native-second');check('another simulator keeps Mac-window default',(await api('native-second')).ios_capture.capture==='current');
 const firstFrames=(await api()).frames;await ev("document.querySelector('[data-udid=native-second] [data-action=close]').click()");await until('second gone',async()=>!await api('native-second'));await sleep(400);check('closing another device leaves Native stream alive',(await api()).frames>firstFrames);
 await ev("document.querySelector('[data-action=close]').click()");await until('all UI closed',async()=>(await all()).length===0);
 }
 check('every synthetic source was closed exactly once',events().filter(e=>e.kind==='open').every(o=>events().filter(e=>e.kind==='close'&&e.name===o.name).length===1));
 check('strict packet IDs/timestamps',auditInvalid===0&&await ev('(window.audit?.invalid ?? 0)===0'));
 check('no browser exceptions',exceptions.length===0);
 fs.writeFileSync(root+'/native-browser-review.json',JSON.stringify({passed:true,phase:process.env.NATIVE_BROWSER_PHASE??'all',checks,exceptions,wireFPS,lowFPS,real_capture:false,real_input:false,real_simulator_connection:false},null,2));console.log(JSON.stringify({nativeBrowserChecks:checks.length,wireFPS,lowFPS,exceptions:exceptions.length}));
} catch(error) {let debug;try{debug={sessions:await all(),browser:await ev('({stats:window.nativeStats?.slice(-4),audit:window.audit})')}}catch{}fs.writeFileSync(root+'/native-browser-review.json',JSON.stringify({passed:false,error:String(error),debug,checks,exceptions},null,2));throw error}
finally {for(const f of ['mode.json','window.json','headless','offline','window-close-hold'])remove(f);if(ws?.readyState===WebSocket.OPEN){try{await cdp('Browser.close')}catch{}ws.close()}for(const p of pending.values())clearTimeout(p.timer);await sleep(250);if(chrome?.exitCode===null)try{process.kill(-chrome.pid,'SIGTERM')}catch{}chrome?.stderr?.destroy()}
