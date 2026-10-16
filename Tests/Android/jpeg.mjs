// Real native service / ImageIO / VideoToolbox / WebCodecs; synthetic JPEGs and ADB only.
import fs from 'node:fs';import crypto from 'node:crypto';import {spawn} from 'node:child_process';
const root=process.argv[2],base='https://127.0.0.1:45154',cookie=crypto.createHash('sha256').update('simwisp-session-v1:isolated-android-backends').digest('hex');
const checks=[],exceptions=[],samples=[],pending=new Map();let chrome,ws,seq=0,received=0,configs=0;
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),events=()=>fs.readFileSync(root+'/events.ndjson','utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
const launches=()=>events().filter(e=>e.kind==='command'&&e.args.includes('exec-out'));
const controls=()=>events().filter(e=>e.kind==='command'&&e.args.includes('com.genymobile.scrcpy.Server'));
const legacy=()=>fs.existsSync(root+'/legacy.ndjson')?fs.readFileSync(root+'/legacy.ndjson','utf8').split('\n').filter(Boolean).map(JSON.parse):[];
const put=(p,v)=>fs.writeFileSync(root+'/'+p,JSON.stringify(v));const remove=p=>{try{fs.unlinkSync(root+'/'+p)}catch{}};
function check(name,v){checks.push({name,passed:v===true});if(v!==true)throw Error(name)}
async function until(name,fn){const end=Date.now()+18000;while(Date.now()<end){if(await fn())return;await sleep(50)}throw Error('Timeout '+name)}
function cdp(method,params={}){return new Promise((resolve,reject)=>{const id=++seq,timer=setTimeout(()=>{pending.delete(id);reject(Error(method+' timeout'))},12000);pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params}))})}
async function ev(expression){const r=await cdp('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value}
async function api(){const r=await fetch(base+'/api/sessions',{headers:{Cookie:'simwisp_session='+cookie}});if(!r.ok)throw Error('API '+r.status);return(await r.json())[0]}
async function active(capture='jpeg',input='current'){await until(capture+'/'+input,async()=>{const s=await api();return s?.state==='Streaming'&&s.android_backends.effective_capture===capture&&s.android_backends.effective_input===input&&s.frames>2});return api()}
async function destroy(){await ev('window.testStream?.destroy();window.testStream=null');await until('session retired',async()=>!await api());await sleep(300)}
async function connect(capture='jpeg',input='current',saver=false){await destroy();await ev(`(()=>{const c=document.getElementById('jpeg-canvas');c.width=320;c.height=640;window.testStats=[];window.testStatus=[];window.auditStart=transportAudit.bytes;window.testStream=new window.SimStream('emulator-5554',c,{fps:60,quality:20,data_saver:${saver},backends:{capture:'${capture}',input:'${input}'},onStats:s=>testStats.push({...s,at:performance.now(),auditBytes:transportAudit.bytes}),onStatus:s=>testStatus.push(s)});return true})()`);return active(capture==='auto'?'scrcpy':capture,input==='auto'?'scrcpy':input)}
async function setting(value){await ev(`testStream.send(${JSON.stringify({type:'settings',...value})})`)}
try{
 for(const n of ['headless','unavailable','jpeg-unavailable','jpeg-rotation','jpeg-mode.json','window-size.json','display.json','hold-video'])remove(n);
 const profile=fs.mkdtempSync(root+'/chrome-jpeg-');chrome=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new','--disable-gpu','--ignore-certificate-errors','--remote-debugging-address=127.0.0.1','--remote-debugging-port=0','--user-data-dir='+profile,'--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-sync','--disable-extensions','about:blank'],{stdio:['ignore','ignore','pipe'],detached:true});chrome.stderr.resume();
 await until('Chrome',()=>fs.existsSync(profile+'/DevToolsActivePort'));const port=fs.readFileSync(profile+'/DevToolsActivePort','utf8').split('\n')[0],pages=await(await fetch('http://127.0.0.1:'+port+'/json/list')).json();ws=new WebSocket(pages.find(p=>p.type==='page').webSocketDebuggerUrl);await new Promise((r,j)=>{ws.addEventListener('open',r,{once:true});ws.addEventListener('error',j,{once:true})});
 ws.addEventListener('message',e=>{const m=JSON.parse(e.data);if(m.id&&pending.has(m.id)){const p=pending.get(m.id);pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result)}else if(m.method==='Runtime.exceptionThrown')exceptions.push(m.params);else if(m.method==='Network.webSocketFrameReceived'){const f=m.params.response;if(f.opcode===2)received++;else if(f.opcode===1){try{if(JSON.parse(f.payloadData).type==='video_config')configs++}catch{}}}});
 await cdp('Page.enable');await cdp('Runtime.enable');await cdp('Network.enable');await cdp('Network.setCookie',{name:'simwisp_session',value:cookie,url:base,secure:true,httpOnly:true,sameSite:'Strict'});await cdp('Page.navigate',{url:base});await until('page',()=>ev("document.readyState==='complete'&&document.querySelector('.device-item')!==null"));
 await ev(`(async()=>{const {SimStream}=await import('/js/stream.js');window.SimStream=SimStream;window.transportAudit={bytes:0,frames:0,nonIncreasingPackets:0,keyframes:0,current:null,feedback:null};const NativeSocket=WebSocket;window.WebSocket=class extends NativeSocket{send(data){try{const m=JSON.parse(data);if(m.type==='video_feedback')transportAudit.feedback=m}catch{}super.send(data)}constructor(...args){super(...args);let id=0,epoch=0,time=0n,bytes=0;this.addEventListener('message',e=>{if(e.data instanceof ArrayBuffer){transportAudit.bytes+=e.data.byteLength;transportAudit.frames++;bytes+=e.data.byteLength;const v=new DataView(e.data),nextEpoch=v.getUint32(8),nextID=v.getUint32(12),nextTime=v.getBigUint64(16);if(nextID<=id||(nextEpoch===epoch&&nextTime<=time))transportAudit.nonIncreasingPackets++;transportAudit.current={epoch:nextEpoch,frameID:nextID,bytes,time:String(nextTime)};if(v.getUint8(4)===1)transportAudit.keyframes++;id=nextID;epoch=nextEpoch;time=nextTime}})}};window.decoderCreates=0;const NativeDecoder=VideoDecoder;window.VideoDecoder=class extends NativeDecoder{constructor(o){super(o);decoderCreates++}};const c=document.createElement('canvas');c.id='jpeg-canvas';document.body.append(c);return true})()`);
 const autoCount=launches().length;await connect('auto','auto');check('Auto still selects scrcpy, never JPEG',launches().length===autoCount);await destroy();
 for(const input of ['current','scrcpy','auto']){
   const before=events().length;await connect('jpeg',input);const selected=input==='auto'?'scrcpy':input;
   check('JPEG decoding reaches actual browser pixels with '+input,await ev("(()=>{const d=document.querySelector('#jpeg-canvas').getContext('2d').getImageData(100,100,1,1).data;return d[0]>150&&d[1]<100&&d[2]<120})()"));
   const start=events().filter(e=>e.kind==='control'&&e.type===2).length,old=legacy().length;
   await ev("testStream.send({type:'touch_down',x:.2,y:.3});testStream.send({type:'touch_move',x:.4,y:.5});testStream.send({type:'touch_up',x:.4,y:.5})");
   await until('input packets '+input,()=>selected==='scrcpy'?events().filter(e=>e.kind==='control'&&e.type===2).length>=start+3:legacy().length>=old+3);
   check('independent input routing '+input,selected==='scrcpy'?legacy().length===old:events().filter(e=>e.kind==='control'&&e.type===2).length===start);
   const commands=events().slice(before).filter(e=>e.kind==='command').map(e=>e.args);
   check('JPEG never starts Android video or changes shaping '+input,!commands.some(a=>a.includes('video=true')||a.includes('setprop')));
 }
 // A missing input dependency does not turn manual JPEG capture into Mac-window capture.
 await destroy();fs.writeFileSync(root+'/unavailable','1');await connect('jpeg','auto').catch(async()=>{await until('JPEG with input fallback',async()=>{const s=await api();return s?.state==='Streaming'&&s.android_backends.effective_input==='current'})});
 check('JPEG capture survives Auto input fallback',(await api()).android_backends.effective_capture==='jpeg');remove('unavailable');
 await connect('jpeg','scrcpy');const helperBefore=launches().length,controlBefore=controls().length;
 await setting({quality:1});await sleep(750);check('quality slider updates final Mac encode without restarting JPEG/control',(await api()).quality===1&&launches().length===helperBefore&&controls().length===controlBefore&&(await api()).capture_counters.jpeg_quality===70);
 put('window-size.json',{width:400,height:800});await until('debounced JPEG resize',async()=>(await api())?.capture_counters.max_size===800&&launches().length===helperBefore+1);check('host resize restarts only capture, not input',controls().length===controlBefore);
 fs.writeFileSync(root+'/headless','1');await sleep(1200);check('no host window required by JPEG+scrcpy',(await active('jpeg','scrcpy')).capture_counters.max_size===800&&launches().length===helperBefore+1);
 const decoderBefore=await ev('decoderCreates'),rotatedHelpers=launches().length;put('display.json',{width:640,height:320});fs.writeFileSync(root+'/jpeg-rotation','1');
 await until('rotation decode',()=>ev("document.getElementById('jpeg-canvas').width===640&&document.getElementById('jpeg-canvas').height===320"));await until('input geometry rotation',async()=>(await api()).input_counters.width===640);
 check('rotation changes H264 epoch exactly once without helper restart',await ev('decoderCreates')===decoderBefore+1&&launches().length===rotatedHelpers);
 await setting({stream_paused:true});await until('pause',async()=>(await api())?.state==='Paused');await sleep(500);
 const alive=events().filter(e=>e.kind==='jpeg_process').map(e=>e.pid).filter(pid=>{try{process.kill(pid,0);return true}catch{return false}});check('pause joins every owned JPEG process',alive.length===0);
 await setting({stream_paused:false});await active('jpeg','scrcpy');check('resume creates fresh capture session',launches().length===rotatedHelpers+1);
 await destroy();remove('headless');remove('jpeg-rotation');remove('display.json');remove('window-size.json');
 // Throughput of the integrated native JPEG decode/VT encode/WSS/WebCodecs path.
 await connect('jpeg','current');await sleep(1500);const first={at:performance.now(),received,decoders:await ev('decoderCreates')};
 for(let i=0;i<6;i++){await sleep(1000);samples.push({at:performance.now(),received,stats:await ev('testStats.at(-1)')})}
 const wireFPS=(received-first.received)/((samples.at(-1).at-first.at)/1000),live=await api();
 check('integrated synthetic JPEG pipeline sustains55–62wireFPS',wireFPS>=55&&wireFPS<=62);
 check('all six browser-render windows sustain55–62FPS',samples.every(s=>s.stats.fps>=55&&s.stats.fps<=62));
 check('final encoder is hardware VideoToolbox, intermediate fixedQ70',live.capture_counters.hardware_encoder===true&&live.capture_counters.jpeg_quality===70);
 check('at most one pending JPEG and bounded receiver decode',live.capture_counters.queued_frames<=1&&live.receiver_decode_queue<=3);
 check('natural IDRs preserve decoder',await ev('decoderCreates')===first.decoders);
 check('source/decodes/completed encodes are separate honest metrics',live.capture_counters.source_frames>=live.capture_counters.jpeg_decodes&&live.capture_counters.h264_encodes>=live.frames&&live.capture_counters.cached_image_encodes<=live.capture_counters.h264_encodes);
 const auditStart=await ev('auditStart');check('bandwidth counter equals independent WebSocket received bytes',samples.every(s=>s.stats.receivedBytes===s.stats.auditBytes-auditStart));
 check('bandwidth rate uses measured elapsed time',samples.slice(1).every((s,i)=>{const p=samples[i].stats,rate=(s.stats.auditBytes-p.auditBytes)/((s.stats.at-p.at)/1000);return Math.abs(s.stats.bps-rate)<=Math.max(1,rate*.02)}));
 const staticBefore=(await api()).capture_counters.source_frames;put('jpeg-mode.json',{static:true});
 const saverTransition={decoders:await ev('decoderCreates'),epoch:await ev('transportAudit.current.epoch'),keys:await ev('transportAudit.keyframes')};
 await setting({data_saver:true});await sleep(2500);const idle=await api();
 check('routine Data saver IDR preserves epoch and browser decoder',await ev('decoderCreates')===saverTransition.decoders&&await ev('transportAudit.current.epoch')===saverTransition.epoch&&await ev('transportAudit.keyframes')>saverTransition.keys);
 check('Data saver captures fresh JPEGs but skips identical H264 encodes',idle.capture_counters.source_frames>=staticBefore+100&&idle.sent_fps===0&&idle.data_saver===true);
 const count=received;await sleep(1100);check('no cached P-frame replay on static source',received===count);
 await setting({data_saver:false});await sleep(2200);check('Data saver off resumes new captures and encodes',(await api()).sent_fps>=55);
 const recoverBefore={decoders:await ev('decoderCreates'),helpers:launches().length};await ev("testStream.send({type:'video_keyframe'})");await until('keyframe reset',async()=>await ev('decoderCreates')===recoverBefore.decoders+1);await sleep(500);
 check('explicit recovery needs no guest/helper restart',launches().length===recoverBefore.helpers&&await ev('decoderCreates')===recoverBefore.decoders+1);
 // Local encode cadence must also obey lower requested FPS despite more source arrivals.
 await setting({fps:30});await until('JPEG30 source configuration',async()=>(await api()).capture_counters.source_fps_limit===30);await sleep(1500);
 const lowStart={at:performance.now(),received};await sleep(2200);const lowFPS=(received-lowStart.received)/((performance.now()-lowStart.at)/1000);
 check('local JPEG encoder obeys requested30FPS without arrival-driven bursts',lowFPS>=27&&lowFPS<=32&&(await api()).fps===30);
 await setting({fps:60});await until('JPEG60 source restored',async()=>(await api()).capture_counters.source_fps_limit===60);await sleep(1200);
 // No new guest JPEGs during heartbeat-only idle: Data saver OFF still sends
 // NEW, correctly paced H264 frames, decoded by the real browser decoder.
 put('jpeg-mode.json',{heartbeat:true});await sleep(1100);
 const mirrorBaseline=await api(),idleHelpers=launches().length,idleDecoder=await ev('decoderCreates'),mirrorStart={at:performance.now(),received},continuousSamples=[];
 for(let i=0;i<6;i++){await sleep(1000);continuousSamples.push(await ev('testStats.at(-1)'))}
 await sleep(3200);const mirrorIdle=await api(),staticWireFPS=(received-mirrorStart.received)/((performance.now()-mirrorStart.at)/1000);
 check('idle heartbeats preserve real native/browser session beyond8s',mirrorIdle.state==='Streaming'&&mirrorIdle.android_backends.effective_capture==='jpeg'&&mirrorIdle.capture_counters.source_heartbeats>=16);
 check('Data saver OFF keeps continuous55–62wireFPS and all six rendered windows',staticWireFPS>=55&&staticWireFPS<=62&&continuousSamples.every(s=>s.fps>=55&&s.fps<=62)&&mirrorIdle.data_saver===false);
 check('continuous static stream does not invent source frames/bytes/decodes',mirrorIdle.capture_counters.source_frames===mirrorBaseline.capture_counters.source_frames&&mirrorIdle.capture_counters.source_jpeg_bytes===mirrorBaseline.capture_counters.source_jpeg_bytes&&mirrorIdle.capture_counters.jpeg_decodes===mirrorBaseline.capture_counters.jpeg_decodes&&mirrorIdle.capture_counters.last_frame_age_ms>9000);
 check('static stream performs new hardware encodes using latest decoded image',mirrorIdle.capture_counters.h264_encodes>=mirrorBaseline.capture_counters.h264_encodes+500&&mirrorIdle.capture_counters.cached_image_encodes>=mirrorBaseline.capture_counters.cached_image_encodes+500&&mirrorIdle.frames>=mirrorBaseline.frames+500&&mirrorIdle.capture_counters.hardware_encoder===true);
 check('continuous idle needs no helper restart or routine decoder recreation',launches().length===idleHelpers&&await ev('decoderCreates')===idleDecoder&&mirrorIdle.receiver_decode_queue<=3);
 // A different SAME-SIZE JPEG must replace the cached pixels, not just keep
 // resending the initial image until rotation/reconnect.
 put('jpeg-mode.json',{static:true,index:20});
 await until('new same-size source image replaces cached browser pixels',()=>ev("(()=>{const d=document.getElementById('jpeg-canvas').getContext('2d').getImageData(276,164,1,1).data;return d[0]>200&&d[1]>180&&d[2]>180})()"));
 check('new source pixels replace cache without helper/decoder restart',(await api()).capture_counters.source_frames>mirrorIdle.capture_counters.source_frames&&launches().length===idleHelpers&&await ev('decoderCreates')===idleDecoder);
 put('jpeg-mode.json',{heartbeat:true});await sleep(1100);
 // Force genuine server-side adaptive pacing, with valid cumulative receipt
 // metadata, while the unchanged guest produces ONLY heartbeats. Old code
 // retires the helper after5s and loses its only decoded image here.
 await setting({quality:1});await sleep(750);
 const adaptiveStart={live:await api(),helpers:launches().length,decoders:await ev('decoderCreates'),epoch:await ev('transportAudit.current.epoch'),at:performance.now()},adaptiveSamples=[];
 await until('valid congestion feedback admitted',()=>ev("(()=>{const c=transportAudit.current;if(!c||c.frameID<=(transportAudit.feedback?.frame_id??0))return false;testStream.send({type:'video_feedback',epoch:c.epoch,frame_id:c.frameID,pending_frames:16,decode_queue:0,oldest_pending_ms:300});return true})()"));
 await until('adaptive FPS decreases below requested cap',async()=>(await api()).fps<60);
 let adaptiveStable=true,adaptiveMinFPS=60;
 await until('adaptive FPS recovers without source or decoder replacement',async()=>{const s=await api(),decoder=await ev('decoderCreates'),epoch=await ev('transportAudit.current.epoch');adaptiveSamples.push({at:performance.now(),fps:s.fps,frames:s.frames,encodes:s.capture_counters.h264_encodes,encoders:s.capture_counters.encoder_creations,sourceFrames:s.capture_counters.source_frames,decoders:decoder,epoch});adaptiveMinFPS=Math.min(adaptiveMinFPS,s.fps);adaptiveStable&&=s.state==='Streaming'&&s.capture_counters.source_fps_limit===60&&s.capture_counters.encoder_creations===1&&s.capture_counters.source_frames===adaptiveStart.live.capture_counters.source_frames&&launches().length===adaptiveStart.helpers&&decoder===adaptiveStart.decoders&&epoch===adaptiveStart.epoch;if(!adaptiveStable)throw Error('Adaptive pacing replaced a persistent JPEG/decoder session');await sleep(200);return s.fps===60&&performance.now()-adaptiveStart.at>5000});
 const adaptiveEnd=await api();
 check('adaptive feedback reduces FPS then restores user target',adaptiveMinFPS<60&&adaptiveEnd.fps===60&&adaptiveEnd.target_fps===60);
 check('adaptive FPS recovery preserves helper encoder cache epoch and decoder',adaptiveStable&&adaptiveEnd.capture_counters.h264_encodes>adaptiveStart.live.capture_counters.h264_encodes+200&&adaptiveEnd.capture_counters.jpeg_decodes===adaptiveStart.live.capture_counters.jpeg_decodes);
 check('latest decoded static pixels survive adaptive recovery',await ev("(()=>{const d=document.getElementById('jpeg-canvas').getContext('2d').getImageData(276,164,1,1).data;return d[0]>200&&d[1]>180&&d[2]>180})()"));
 const adaptiveContinuity={start:adaptiveStart,end:adaptiveEnd,minFPS:adaptiveMinFPS,samples:adaptiveSamples};
 await setting({data_saver:true});await sleep(1500);
 const saverBaseline=await api(),saverReceived=received;await sleep(2200);const mirrorSaverIdle=await api();
 check('only Data saver ON idles at zero while the guest produces only heartbeats',mirrorSaverIdle.data_saver===true&&mirrorSaverIdle.sent_fps===0&&await ev('testStats.at(-1).fps')===0&&received===saverReceived);
 check('Data saver idle performs no captures/decodes/H264 encodes',mirrorSaverIdle.capture_counters.source_frames===saverBaseline.capture_counters.source_frames&&mirrorSaverIdle.capture_counters.jpeg_decodes===saverBaseline.capture_counters.jpeg_decodes&&mirrorSaverIdle.capture_counters.h264_encodes===saverBaseline.capture_counters.h264_encodes);
 const cacheRecovery={decoders:await ev('decoderCreates'),frames:received};await ev("testStream.send({type:'video_keyframe'})");
 await until('Data saver cached-image recovery IDR',async()=>await ev('decoderCreates')===cacheRecovery.decoders+1&&received>cacheRecovery.frames);await sleep(600);
 const recoveredFrames=received;await sleep(1500);
 check('explicit idle IDR is new encode then Data saver sleeps again',received===recoveredFrames&&launches().length===idleHelpers&&(await api()).capture_counters.source_frames===mirrorSaverIdle.capture_counters.source_frames);
 const resumedStart={at:performance.now(),received};await setting({data_saver:false});
 // Wait for a complete rate window, not the first server sample mixing idle
 // and resumed time. Independently count actual wire frames over the transition.
 await sleep(2200);const resumedCache=await api(),resumedWireFPS=(received-resumedStart.received)/((performance.now()-resumedStart.at)/1000);
 check('Data saver OFF resumes continuous encode without any new JPEG',resumedCache.sent_fps>=55&&resumedWireFPS>=55&&resumedWireFPS<=62&&resumedCache.capture_counters.source_frames===mirrorSaverIdle.capture_counters.source_frames&&resumedCache.capture_counters.jpeg_decodes===mirrorSaverIdle.capture_counters.jpeg_decodes&&launches().length===idleHelpers);
 // Pausing clears this session's cache; resume with heartbeat-only source
 // cannot inherit old pixels or mark the replacement capture ready.
 await setting({stream_paused:true});await until('cached stream pause',async()=>(await api()).state==='Paused');await sleep(500);const pausedFrames=received;
 await setting({stream_paused:false});await sleep(1200);const pendingSource=await api();
 check('paused/replaced source cannot resurrect cached pixels before a new JPEG',received===pausedFrames&&pendingSource.state!=='Streaming'&&pendingSource.capture_counters.source_frames===0);
 const wakeAt=performance.now();put('jpeg-mode.json',{rotation:true});
 await until('first fresh rotated image after idle renders',()=>ev("document.getElementById('jpeg-canvas').width===640&&document.getElementById('jpeg-canvas').height===320"));
 const mirrorWakeMS=performance.now()-wakeAt;
 check('new source after resume starts with its own rotated pixels',mirrorWakeMS<2000&&(await api()).capture_counters.source_frames>0);
 // Corruption arriving AFTER a good cache must not leave a frozen continuous
 // stream that hides the failed source.
 put('jpeg-mode.json',{corrupt:true});await until('cached-source corruption visible',async()=>(await api()).android_backends.effective_capture==='unavailable');await sleep(300);const corruptFrames=received;await sleep(800);
 check('corrupt replacement fails visibly instead of streaming older cached image',received===corruptFrames&&(await api()).android_backends.reason.includes('JPEG image'));
 check('wire packets have strictly increasing IDs/PTS within each decoder epoch',await ev('transportAudit.nonIncreasingPackets')===0);
 const continuousStatic={wireFPS:staticWireFPS,renderFPS:continuousSamples.map(s=>s.fps),baseline:mirrorBaseline,idle:mirrorIdle,dataSaverIdle:mirrorSaverIdle,resumedCache,resumedWireFPS,lowerFPS:lowFPS};
 await destroy();remove('jpeg-mode.json');
 // Manual failure is latched; never silently select Mac-window/scrcpy capture.
 fs.writeFileSync(root+'/jpeg-unavailable','1');await connect('jpeg','current').catch(()=>{});await until('missing helper visible',async()=>(await api())?.android_backends.effective_capture==='unavailable');
 const failed=await api(),failedLaunches=launches().length;await sleep(800);check('missing helper fails visibly and stays manual-only',failed.android_backends.reason.includes('JPEG fixture unavailable <img')&&failed.frames===0&&launches().length===failedLaunches);await destroy();remove('jpeg-unavailable');
 put('jpeg-mode.json',{corrupt:true});await connect('jpeg','current').catch(()=>{});await until('decode corruption visible',async()=>(await api())?.android_backends.effective_capture==='unavailable');check('corrupt JPEG cannot enter browser transport',(await api()).frames===0);await destroy();remove('jpeg-mode.json');
 // Exercise the real panel, capture-only radios, keyboard and AVD preference.
 await ev("document.querySelector('.device-item').click()");await until('panel',()=>ev("document.querySelector('.backend-trigger')!==null"));await ev("document.querySelector('.backend-trigger').click()");
 check('UI offers five capture choices but only three input choices',await ev("document.querySelectorAll('[data-kind=capture]').length===5&&document.querySelectorAll('[data-kind=input]').length===3&&!document.querySelector('[data-kind=input][data-choice=jpeg]')"));
 await ev("document.querySelector('[data-kind=capture][data-choice=jpeg]').click()");await active('jpeg','scrcpy');check('actual active JPEG badge comes from native service',await ev("document.querySelector('[data-effective=capture]').textContent==='Using JPEG70 → H.264'"));
 await ev("document.querySelector('[data-kind=capture][data-choice=raw]').focus()");await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:'ArrowRight',code:'ArrowRight',windowsVirtualKeyCode:39});await until('keyboard wraps fifth capture choice',()=>ev("document.querySelector('[data-kind=capture][data-choice=auto]').getAttribute('aria-checked')==='true'"));await ev("document.querySelector('[data-kind=capture][data-choice=jpeg]').click()");await active('jpeg','scrcpy');
 await ev("document.querySelector('.backend-close').click();document.querySelector('[data-action=close]').click()");await until('closed panel',async()=>!await api());await cdp('Page.reload');await until('reloaded page',()=>ev("document.querySelector('.device-item')!==null"));await ev("document.querySelector('.device-item').click()");await active('jpeg','scrcpy');check('JPEG preference persists per AVD across reload',true);
 check('invalid JPEG input preference normalizes to Auto',await ev("(async()=>{const{backendChoice}=await import('/js/android-backends.js');return backendChoice({capture:'jpeg',input:'jpeg'}).capture==='jpeg'&&backendChoice({capture:'jpeg',input:'jpeg'}).input==='auto'})()"));
 await ev("document.querySelector('[data-action=close]').click()");await until('all panels closed',async()=>!await api());await sleep(500);
 check('all fixture ADB remains serial scoped',events().filter(e=>e.kind==='command').every(e=>e.args[0]==='-s'&&e.args[1]==='emulator-5554'));
 check('zero browser exceptions',exceptions.length===0);
 const report={checks,exceptions,samples,wireFPS,renderFPS:samples.map(s=>s.stats.fps),live,idle,continuousStatic,adaptiveContinuity,mirrorIdle,mirrorWakeMS,real_device_actions:false,real_capture:false,real_input:false};fs.writeFileSync(root+'/jpeg-browser-review.json',JSON.stringify(report,null,2));console.log(JSON.stringify({jpegBrowserChecks:checks.length,wireFPS,renderFPS:report.renderFPS,exceptions:exceptions.length}));
}catch(error){let debug;try{debug={api:await api(),browser:await ev('({status:window.testStatus,stats:window.testStats?.slice(-5),decoders:window.decoderCreates,transport:window.transportAudit})')}}catch{}fs.writeFileSync(root+'/jpeg-browser-review.json',JSON.stringify({error:String(error),debug,checks,exceptions,samples},null,2));throw error}
finally{for(const n of ['headless','unavailable','jpeg-unavailable','jpeg-rotation','jpeg-mode.json','window-size.json','display.json','hold-video'])remove(n);if(ws?.readyState===WebSocket.OPEN){try{await cdp('Browser.close')}catch{}ws.close()}for(const p of pending.values())clearTimeout(p.timer);await sleep(250);if(chrome?.exitCode===null)try{process.kill(-chrome.pid,'SIGTERM')}catch{}}
