// Production native HTTPS/JPEG/ImageIO/VT/WebCodecs + inert phone ADB/socket peers.
import fs from 'node:fs';import crypto from 'node:crypto';import {spawn} from 'node:child_process';
const root=process.argv[2],base='https://127.0.0.1:45154',cookie=crypto.createHash('sha256').update('simwisp-session-v1:isolated-android-backends').digest('hex');
const ids=['adb-PHYSICAL-TEST._adb-tls-connect._tcp','USBPHYSICALTEST123','192.0.2.10:37123','[2001:db8::1]:5555'];
const checks=process.env.PHYSICAL_SCRCPY_PREVIOUS_REPORT?JSON.parse(fs.readFileSync(process.env.PHYSICAL_SCRCPY_PREVIOUS_REPORT,'utf8')).checks.filter(c=>c.passed):[],exceptions=[],pending=new Map();let chrome,ws,seq=0,received=0;const packets=[];let noJPEG=0;
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),put=(p,v)=>fs.writeFileSync(root+'/'+p,JSON.stringify(v)),remove=p=>{try{fs.unlinkSync(root+'/'+p)}catch{}};
const events=()=>fs.readFileSync(root+'/events.ndjson','utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
const launches=()=>events().filter(e=>e.kind==='command'&&e.args.includes('exec-out'));
const controls=()=>events().filter(e=>e.kind==='command'&&e.args.includes('com.genymobile.scrcpy.Server'));
const legacy=()=>fs.existsSync(root+'/legacy.ndjson')?fs.readFileSync(root+'/legacy.ndjson','utf8').trim().split('\n').filter(Boolean):[];
function check(name,v){checks.push({name,passed:v===true});if(v!==true)throw Error(name)}
async function until(name,fn){const end=Date.now()+16000;while(Date.now()<end){if(await fn())return;await sleep(50)}throw Error('Timeout '+name)}
function cdp(method,params={}){return new Promise((resolve,reject)=>{const id=++seq,timer=setTimeout(()=>{pending.delete(id);reject(Error('CDP '+method+' timeout'))},10000);pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params}))})}
async function ev(expression){const r=await cdp('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value}
async function api(path='/api/sessions',method='GET'){const r=await fetch(base+path,{method,headers:{Cookie:'simwisp_session='+cookie,Origin:base}});return{status:r.status,value:await r.json()}}
async function live(){return(await api()).value[0]}
async function active(){await until('physical JPEG + scrcpy stream',async()=>{const s=await live();return s?.state==='Streaming'&&s.frames>2&&s.android_backends.effective_capture==='scrcpy'&&s.android_backends.effective_input==='scrcpy'});return live()}
async function directClose(){await ev('window.phoneStream?.destroy();window.phoneStream=null');await until('all stream work retired',async()=>!await live());await sleep(300)}
async function direct(id,capture='auto',input='auto',scale='1'){
  fs.writeFileSync(root+'/serial',id);await api('/api/sims');
  await ev(`(async()=>{const{SimStream}=await import('/js/stream.js');const c=document.getElementById('phone-canvas')||Object.assign(document.createElement('canvas'),{id:'phone-canvas'});c.width=411;c.height=914;document.body.append(c);window.phoneStats=[];window.phoneStatus=[];window.phoneStream=new SimStream(${JSON.stringify(id)},c,{fps:30,quality:20,backends:{capture:${JSON.stringify(capture)},input:${JSON.stringify(input)},scaling:${JSON.stringify(scale)}},onStats:s=>phoneStats.push(s),onStatus:s=>phoneStatus.push(s)});return true})()`);
}
async function send(value){await ev(`phoneStream.send(${JSON.stringify(value)})`)}
// All source pixels, devices, ADB processes and input targets are inert owned peers.
const ownedFiles=['serial','device-offline','unavailable','jpeg-unavailable','headless','jpeg-mode.json','jpeg-rotation','physical-size.json','display.json','window-size.json','scrcpy-mode.json','sidebar-inventory.json'];
const serverStarts=()=>events().filter(e=>e.kind==='command'&&e.args.includes('com.genymobile.scrcpy.Server'));
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
function pictures(hex){const b=Buffer.from(hex,'hex'),starts=[];for(let i=0;i<b.length-2;i++)if(b[i]===0&&b[i+1]===0){if(b[i+2]===1){starts.push([i,3]);i+=2}else if(b[i+2]===0&&b[i+3]===1){starts.push([i,4]);i+=3}}return Buffer.concat(starts.map(([p,n],i)=>b.subarray(p+n,starts[i+1]?.[0]??b.length)).filter(n=>![7,8].includes(n[0]&31)).map(n=>{const h=Buffer.alloc(4);h.writeUInt32BE(n.length);return Buffer.concat([h,n])}))}
async function select(kind,value){await ev(`(()=>{const m=document.querySelector('.backend-popover');if(m.hidden)document.querySelector('.backend-trigger').click();document.querySelector(${JSON.stringify('[data-kind='+kind+'][data-choice="'+value+'"]')}).click()})()`)}
async function panelSend(value){await ev(`phoneSockets.at(-1).send(${JSON.stringify(JSON.stringify(value))})`)}
async function matching(scale,width,height){await until('scrcpy scaled '+scale+' '+width+'x'+height,async()=>{const s=await live();return s?.frames>3&&s.android_backends.effective_capture==='scrcpy'&&s.android_backends.jpeg_scale===scale&&s.capture_counters.video_width===width&&s.capture_counters.video_height===height});return live()}
try{
  for(const f of ownedFiles)remove(f);fs.writeFileSync(root+'/serial',ids[0]);put('physical-size.json',{width:320,height:640});put('display.json',{width:320,height:640});put('scrcpy-mode.json',{scaled:true});
  if(!fs.existsSync(root+'/events.ndjson'))fs.writeFileSync(root+'/events.ndjson',''); // Standalone browser run has not issued ADB yet.
  const boundary=events().length,profile=fs.mkdtempSync(root+'/phone-video-chrome-');
  chrome=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new','--disable-gpu','--ignore-certificate-errors','--remote-debugging-address=127.0.0.1','--remote-debugging-port=0','--user-data-dir='+profile,'--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-sync','--disable-extensions','about:blank'],{stdio:['ignore','ignore','pipe'],detached:true});chrome.stderr.resume();
  await until('owned Chrome',()=>fs.existsSync(profile+'/DevToolsActivePort'));
  const port=fs.readFileSync(profile+'/DevToolsActivePort','utf8').split('\n')[0],tabs=await(await fetch('http://127.0.0.1:'+port+'/json/list')).json();
  ws=new WebSocket(tabs.find(t=>t.type==='page').webSocketDebuggerUrl);await new Promise((r,j)=>{ws.addEventListener('open',r,{once:true});ws.addEventListener('error',j,{once:true})});
  ws.addEventListener('message',e=>{const m=JSON.parse(e.data);if(m.id&&pending.has(m.id)){const p=pending.get(m.id);pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result)}else if(m.method==='Runtime.exceptionThrown')exceptions.push(m.params);else if(m.method==='Network.webSocketFrameReceived'&&m.params.response.opcode===2){received++;if(packets.length<4000)packets.push(Buffer.from(m.params.response.payloadData,'base64'))}});
  await cdp('Page.enable');await cdp('Runtime.enable');await cdp('Network.enable');await cdp('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});
  await cdp('Network.setCookie',{name:'simwisp_session',value:cookie,url:base,secure:true,httpOnly:true,sameSite:'Strict'});await cdp('Page.navigate',{url:base});await until('physical phone',()=>ev("document.querySelector('.device-item')!==null"));
  await ev("window.phoneSockets=[];const NativeSocket=WebSocket;window.WebSocket=class extends NativeSocket{constructor(...a){super(...a);phoneSockets.push(this)}};");
  if(process.env.PHYSICAL_SCRCPY_REMAINDER!=='1'){
  await ev("document.querySelector('.device-item').click()");
  await until('default JPEG',async()=>(await live())?.android_backends.effective_capture==='jpeg'&&(await live())?.frames>2);
  check('physical default remains JPEG',(await live()).android_backends.capture==='jpeg');
  const beforeJPEG=launches().length;await select('capture','scrcpy');await matching('1',320,640);
  check('actual physical UI selects scrcpy capture and scrcpy input',(await live()).android_backends.capture==='scrcpy'&&(await live()).android_backends.effective_input==='scrcpy');
  check('switch JPEG to scrcpy starts no replacement JPEG producer',launches().length===beforeJPEG);
  const golden=JSON.parse(fs.readFileSync(root+'/phone-video.json','utf8'));
  for(const[scale,w,h,edge]of [['1',320,640,640],['0.5',160,320,320],['0.25',80,160,160]]){
    await select('scaling',scale);const s=await matching(scale,w,h);
    await until('actual browser scaled decode '+scale,()=>ev(`document.querySelector('.device-frame canvas').width===${w}&&document.querySelector('.device-frame canvas').height===${h}`));
    check('x'+scale+' reaches phone scrcpy max_size',s.capture_counters.max_size===edge&&serverStarts().at(-1).args.includes('max_size='+edge));
    check('x'+scale+' has phone video counters, no Mac JPEG/H264 work',s.capture_counters.source_frames>0&&s.capture_counters.jpeg_decodes===undefined&&s.capture_counters.h264_encodes===undefined);
    const allowed=new Set(golden[w+'x'+h].frames.map(f=>sha(pictures(f.payload))));
    check('x'+scale+' forwards pre-encoded H264 picture bytes unchanged',packets.some(b=>b.length>24&&allowed.has(sha(b.subarray(24)))));
    check('x'+scale+' browser preserves four corner colors/orientation',await ev(`(()=>{const c=document.querySelector('.device-frame canvas'),x=c.getContext('2d'),p=(a,b)=>[...x.getImageData(Math.floor(c.width*a),Math.floor(c.height*b),1,1).data];const a=p(.2,.2),b=p(.8,.2),d=p(.2,.8),e=p(.8,.8);return a[0]>150&&a[1]<110&&a[2]<110&&b[1]>150&&b[0]<110&&d[2]>150&&d[0]<110&&e[0]>150&&e[1]>150&&e[2]<110})()`));
    check('x'+scale+' badge and local preference describe H264 scaling',await ev(`document.querySelector('[data-effective=scaling]').textContent==='Before H.264'&&JSON.parse(localStorage.getItem('simwisp.android-backends.v1:'+encodeURIComponent('device:'+${JSON.stringify(ids[0])}))).scaling===${JSON.stringify(scale)}`));
    await ev("if(!document.querySelector('.backend-popover').hidden)document.querySelector('.backend-trigger').click()");
    const n=events().filter(e=>e.kind==='control'&&e.type===2).length,r=await ev("document.querySelector('.device-frame canvas').getBoundingClientRect().toJSON()"),point={x:r.x+r.width*.2,y:r.y+r.height*.3};
    await cdp('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',buttons:1,clickCount:1,...point});await cdp('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',buttons:0,clickCount:1,...point});
    await until('actual scaled scrcpy canvas tap',()=>events().filter(e=>e.kind==='control'&&e.type===2).length>=n+2);
    const tap=events().filter(e=>e.kind==='control'&&e.type===2).slice(n),d=Buffer.from(tap[0].hex,'hex');
    check('x'+scale+' touch uses reported video coordinates for scrcpy display mapping',tap.every(e=>e.serial===ids[0])&&d.readUInt16BE(18)===w&&d.readUInt16BE(20)===h&&Math.abs(d.readUInt32BE(10)-w*.2)<=1&&Math.abs(d.readUInt32BE(14)-h*.3)<=1);
    check('x'+scale+' phone avoids emulator shaping/QP trial',s.capture_counters.format_shaping_disabled===null&&s.capture_counters.requested_qp_max===null&&s.capture_counters.requested_bitrate_mode===null);
  }
  await panelSend({type:'settings',fps:15,quality:40});
  await until('phone FPS/quality reconfigure',async()=>{const s=await live();return s?.state==='Streaming'&&s.frames>3&&s.target_fps===15&&serverStarts().at(-1).args.includes('max_fps=15')});
  check('user FPS/quality change retains selected scrcpy scale',(await live()).capture_counters.max_size===160&&(await live()).android_backends.jpeg_scale==='0.25');
  const recoverStart=serverStarts().length,resetBefore=(await live()).capture_counters.reset_requests;
  await panelSend({type:'video_keyframe'});await until('phone decoder recovery IDR',async()=>{const s=await live();return s?.state==='Streaming'&&s.capture_counters.reset_requests>resetBefore});
  check('explicit decoder recovery reuses owned phone source and retains scale',serverStarts().length===recoverStart&&(await live()).capture_counters.max_size===160);
  const navStart=events().filter(e=>e.kind==='control'&&e.type===0).length;
  for(const action of ['home','back','app-switcher'])await ev(`document.querySelector('[data-action=${action}]').click()`);
  await until('scrcpy physical navigation',()=>events().filter(e=>e.kind==='control'&&e.type===0).length>=navStart+6);
  check('Home/Back/Recents remain selected-phone scrcpy controls',events().filter(e=>e.kind==='control'&&e.type===0).slice(navStart).every(e=>e.serial===ids[0]));
  const textStart=events().filter(e=>e.kind==='control'&&e.type===1).length;
  await ev("document.querySelector('[data-action=kbd]').click();document.getElementById('kbd-input').value='scrcpy phone keyboard';document.getElementById('kbd-send').click()");
  await until('physical scrcpy keyboard',()=>events().filter(e=>e.kind==='control'&&e.type===1).length>textStart);check('keyboard still uses the phone control socket',events().filter(e=>e.kind==='control'&&e.type===1).at(-1).serial===ids[0]);
  await ev("if(document.getElementById('kbd-bar').classList.contains('visible'))document.querySelector('[data-action=kbd]').click()");
  const gestures=events().filter(e=>e.kind==='control'&&e.type===2).length;await panelSend({type:'touch_down',x:.4,y:.5});await until('held phone pointer',()=>events().filter(e=>e.kind==='control'&&e.type===2).length>gestures);
  const rotations=serverStarts().length;put('physical-size.json',{width:640,height:320});put('display.json',{width:640,height:320});put('scrcpy-mode.json',{scaled:true,rotation:true});await matching('0.25',160,80);
  await until('landscape browser',()=>ev("document.querySelector('.device-frame canvas').width===160&&document.querySelector('.device-frame canvas').height===80"));
  check('phone rotation updates video/input without restarting its source',serverStarts().length===rotations&&(await live()).input_counters.width===160&&(await live()).input_counters.height===80);
  await until('rotation releases held phone pointer',()=>events().filter(e=>e.kind==='control'&&e.type===2).slice(gestures).some(e=>e.action===1));
  check('rotation releases held pointer using new valid video dimensions',events().filter(e=>e.kind==='control'&&e.type===2&&e.action===1).slice(-1).every(e=>{const d=Buffer.from(e.hex,'hex');return d.readUInt16BE(18)===160&&d.readUInt16BE(20)===80}));
  const settled=received;put('scrcpy-mode.json',{scaled:true,rotation:true,idle:true});await sleep(150);const idle=received;await sleep(500);
  check('scrcpy idle never replays encoded H264 to invent frames',received===idle&&idle>=settled);put('scrcpy-mode.json',{scaled:true,rotation:true});await until('phone motion resumes',()=>received>idle);
  const starts=serverStarts().length;await panelSend({type:'settings',stream_paused:true});await until('phone video paused',async()=>(await live()).state==='Paused');await sleep(400);
  check('pause retires owned scrcpy video process',events().filter(e=>e.kind==='process').every(e=>{try{process.kill(e.pid,0);return false}catch{return true}}));
  await panelSend({type:'settings',stream_paused:false});await matching('0.25',160,80);check('resume creates exactly one replacement scrcpy source',serverStarts().length===starts+1);
  check('phone video Stop remains forbidden',(await api('/api/stop/'+encodeURIComponent(ids[0]),'POST')).status===404&&(await api('/api/stop-status/'+encodeURIComponent(ids[0]))).status===404);
  const forbidden=events().length;await panelSend({type:'rotate'});await panelSend({type:'appearance',mode:'light'});await sleep(150);
  check('phone video unsupported controls never execute ADB or host effects',events().slice(forbidden).filter(e=>e.kind==='command').length===0&&legacy().length===0);
  const screenshot=await cdp('Page.captureScreenshot',{format:'png'});fs.writeFileSync(root+'/phone-scrcpy-scaled-synthetic.png',Buffer.from(screenshot.data,'base64'));
  put('scrcpy-mode.json',{scaled:true});put('physical-size.json',{width:320,height:640});put('display.json',{width:320,height:640});await select('capture','jpeg');
  await until('switch back JPEG at same scale',async()=>{const s=await live();return s?.android_backends.effective_capture==='jpeg'&&s.frames>3&&s.capture_counters.max_size===160&&s.input_counters.width===320});
  check('scrcpy to JPEG keeps scale and returns full-display control-only coordinates',(await live()).android_backends.jpeg_scale==='0.25'&&(await live()).input_counters.height===640);
  await select('capture','scrcpy');await matching('0.25',80,160);
  await ev("document.querySelector('[data-action=close]').click()");await until('panel gone',async()=>!await live());await ev("document.querySelector('.device-item').click()");await matching('0.25',80,160);
  check('physical scrcpy choice and scale persist across panel recreation',(await live()).android_backends.capture==='scrcpy');
  await ev("document.querySelector('[data-action=close]').click()");await until('panel retired',async()=>!await live());await sleep(300);
  for(const id of ids){await direct(id,'scrcpy','scrcpy','0.5');await matching('0.5',160,320);check('USB/Wi-Fi direct scrcpy selected '+id,(await live()).id===id);await directClose()}
  for(const bad of ['0','2','NaN','0.5;id']){await direct(ids[0],'scrcpy','scrcpy',bad);await matching('1',320,640);check('invalid scrcpy scale normalizes x1 '+bad,(await live()).capture_counters.max_size===640);await directClose()}
  put('physical-size.json',{width:300,height:640});put('scrcpy-mode.json',{scaled:true,width:300,height:640,align8:true});await direct(ids[0],'scrcpy','scrcpy','0.5');await matching('0.5',144,320);
  check('codec-aligned scrcpy output dimensions are accepted without stretching',(await live()).capture_counters.target_width===150&&(await live()).input_counters.width===144);await directClose();
  put('physical-size.json',{width:320,height:640});put('scrcpy-mode.json',{scaled:true});fs.writeFileSync(root+'/unavailable','1');noJPEG=launches().length;const missing=serverStarts().length;
  await direct(ids[0],'scrcpy','scrcpy','0.5');await until('missing dependency visible',async()=>(await live())?.android_backends.effective_capture==='unavailable');
  check('missing physical scrcpy never starts/falls back to JPEG or host window',(await live()).frames===0&&launches().length===noJPEG&&serverStarts().length===missing&&(await live()).android_backends.effective_input==='unavailable');await directClose();remove('unavailable');
  }
  noJPEG=launches().length;
  put('scrcpy-mode.json',{scaled:true,native_error:true});await direct(ids[0],'scrcpy','scrcpy');
  await until('native phone error retained',async()=>(await live())?.android_backends.effective_capture==='unavailable');
  await until('native output detail published after asynchronous drain',async()=>{const reason=(await live())?.android_backends?.reason;return reason?.includes('stack corruption detected')&&reason?.includes('Aborted')});
  check('real native server output survives generic socket disconnect',(await live()).android_backends.reason.includes('stack corruption detected')&&(await live()).android_backends.reason.includes('Aborted'));await directClose();
  put('scrcpy-mode.json',{scaled:true,bad_codec:true});await direct(ids[0],'scrcpy','scrcpy');await until('incompatible phone codec visible',async()=>(await live())?.android_backends.effective_capture==='unavailable');
  check('incompatible codec fails closed without alternate capture',launches().length===noJPEG&&(await live()).android_backends.reason.includes('H.264'));await directClose();
  put('scrcpy-mode.json',{scaled:true});await direct(ids[0],'scrcpy','scrcpy');await matching('1',320,640);put('scrcpy-mode.json',{scaled:true,disconnect:true});
  await until('broken phone transport fails',async()=>(await live())?.android_backends.effective_capture==='unavailable');await sleep(300);const wire=received;await sleep(350);
  check('failed phone stream cannot keep emitting cached encoded pixels',received===wire&&launches().length===noJPEG);await directClose();
  put('scrcpy-mode.json',{scaled:true});await direct(ids[0],'scrcpy','scrcpy');await matching('1',320,640);fs.writeFileSync(root+'/device-offline','1');await api('/api/sims');
  await until('offline phone scrcpy disabled',async()=>(await live())?.android_backends.effective_input==='unavailable');check('phone disconnect latches both backends unavailable',(await live()).android_backends.effective_capture==='unavailable');await directClose();remove('device-offline');
  const commands=events().slice(boundary).filter(e=>e.kind==='command').map(e=>e.args);
  check('all phone operations stay on selected synthetic serials',commands.every(a=>a[0]==='-s'&&ids.includes(a[1])));
  check('no phone shaping/property/settings/emulator/global ADB calls',commands.every(a=>!a.includes('setprop')&&!a.includes('getprop')&&!a.includes('settings')&&!a.includes('emu')&&!a.includes('kill-server')));
  check('all phone video launches disable power/clipboard and emulator codec trial',commands.filter(a=>a.includes('com.genymobile.scrcpy.Server')&&!a.includes('video=false')).every(a=>a.includes('power_on=false')&&a.includes('clipboard_autosync=false')&&!a.some(v=>v.includes('qp-')||v.includes('bitrate-mode='))));
  check('all compact phone video launches fit Samsung command budget',commands.filter(a=>a.includes('com.genymobile.scrcpy.Server')&&!a.includes('video=false')).every(a=>Buffer.byteLength(a.slice(a.indexOf('app_process')).join(' '))<255));
  check('all compact phone video launches explicitly request Baseline',commands.filter(a=>a.includes('com.genymobile.scrcpy.Server')&&!a.includes('video=false')).every(a=>a.includes('video_codec_options=profile=1')));
  check('zero legacy input fallback',legacy().length===0);check('zero browser exceptions',exceptions.length===0);
  fs.writeFileSync(root+'/physical-scrcpy-browser-review.json',JSON.stringify({checks,exceptions,received,real_capture:false,real_input:false,encoded_payload_hashes_preserved:true},null,2));console.log(JSON.stringify({physicalScrcpyBrowserChecks:checks.length,received,exceptions:exceptions.length}));
}catch(error){let debug;try{debug={session:await live(),recent:events().slice(-15)}}catch{}fs.writeFileSync(root+'/physical-scrcpy-browser-review.json',JSON.stringify({error:String(error),checks,exceptions,debug},null,2));throw error}
finally{
  for(const f of ownedFiles)remove(f);
  if(ws?.readyState===WebSocket.OPEN){try{await cdp('Browser.close')}catch{}ws.close()}
  for(const p of pending.values())clearTimeout(p.timer);await sleep(250);
  if(chrome?.exitCode===null)try{process.kill(-chrome.pid,'SIGTERM')}catch{}
  chrome?.stderr?.destroy();
}
