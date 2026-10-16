// Production native HTTPS/JPEG/ImageIO/VT/WebCodecs + inert phone ADB/socket peers.
import fs from 'node:fs';import crypto from 'node:crypto';import {spawn} from 'node:child_process';
const root=process.argv[2],base='https://127.0.0.1:45154',cookie=crypto.createHash('sha256').update('simwisp-session-v1:isolated-android-backends').digest('hex');
const ids=['adb-PHYSICAL-TEST._adb-tls-connect._tcp','USBPHYSICALTEST123','192.0.2.10:37123','[2001:db8::1]:5555'];
const checks=[],exceptions=[],pending=new Map();let chrome,ws,seq=0,received=0;
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
async function active(){await until('physical JPEG + scrcpy stream',async()=>{const s=await live();return s?.state==='Streaming'&&s.frames>2&&s.android_backends.effective_capture==='jpeg'&&s.android_backends.effective_input==='scrcpy'});return live()}
async function directClose(){await ev('window.phoneStream?.destroy();window.phoneStream=null');await until('all stream work retired',async()=>!await live());await sleep(300)}
async function direct(id,capture='auto',input='auto',scale='1'){
  fs.writeFileSync(root+'/serial',id);await api('/api/sims');
  await ev(`(async()=>{const{SimStream}=await import('/js/stream.js');const c=document.getElementById('phone-canvas')||Object.assign(document.createElement('canvas'),{id:'phone-canvas'});c.width=411;c.height=914;document.body.append(c);window.phoneStats=[];window.phoneStatus=[];window.phoneStream=new SimStream(${JSON.stringify(id)},c,{fps:30,quality:20,backends:{capture:${JSON.stringify(capture)},input:${JSON.stringify(input)},scaling:${JSON.stringify(scale)}},onStats:s=>phoneStats.push(s),onStatus:s=>phoneStatus.push(s)});return true})()`);
}
async function send(value){await ev(`phoneStream.send(${JSON.stringify(value)})`)}
const ownedFiles=['sidebar-inventory.json','serial','device-offline','unavailable','jpeg-unavailable','headless','jpeg-mode.json','jpeg-rotation','physical-size.json','display.json','window-size.json'];
try{
  for(const f of ownedFiles)remove(f);fs.writeFileSync(root+'/serial',ids[0]);put('display.json',{width:1080,height:2400});
  const profile=fs.mkdtempSync(root+'/physical-chrome-');
  chrome=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new','--disable-gpu','--ignore-certificate-errors','--remote-debugging-address=127.0.0.1','--remote-debugging-port=0','--user-data-dir='+profile,'--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-sync','--disable-extensions','about:blank'],{stdio:['ignore','ignore','pipe'],detached:true});chrome.stderr.resume();
  await until('owned Chrome',()=>fs.existsSync(profile+'/DevToolsActivePort'));
  const port=fs.readFileSync(profile+'/DevToolsActivePort','utf8').split('\n')[0],tabs=await(await fetch('http://127.0.0.1:'+port+'/json/list')).json();
  ws=new WebSocket(tabs.find(t=>t.type==='page').webSocketDebuggerUrl);await new Promise((r,j)=>{ws.addEventListener('open',r,{once:true});ws.addEventListener('error',j,{once:true})});
  ws.addEventListener('message',e=>{const m=JSON.parse(e.data);if(m.id&&pending.has(m.id)){const p=pending.get(m.id);pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result)}else if(m.method==='Runtime.exceptionThrown')exceptions.push(m.params);else if(m.method==='Network.webSocketFrameReceived'&&m.params.response.opcode===2)received++});
  await cdp('Page.enable');await cdp('Runtime.enable');await cdp('Network.enable');await cdp('Network.setCookie',{name:'simwisp_session',value:cookie,url:base,secure:true,httpOnly:true,sameSite:'Strict'});await cdp('Page.navigate',{url:base});
  await until('phone listed',()=>ev("document.querySelector('.device-item')!==null"));
  const listing=(await api('/api/sims')).value;
  check('phone inventory exposes physical identity and native1080×2400 size',listing.length===1&&listing[0].physical===true&&listing[0].width===1080&&listing[0].height===2400&&listing[0].avd===null);
  check('physical phone has no destructive Stop button',await ev("!document.querySelector('.device-stop-btn')&&document.querySelector('.device-dims').textContent.includes('Android device')"));
  await ev(`localStorage.setItem('simwisp.android-backends.v1:'+encodeURIComponent('device:'+${JSON.stringify(ids[0])}),JSON.stringify({capture:'raw',input:'current'}));window.phoneSockets=[];const NativeSocket=WebSocket;window.WebSocket=class extends NativeSocket{constructor(...args){super(...args);phoneSockets.push(this)}};document.querySelector('.device-item').click()`);
  const initial=await active();
  check('actual phone panel overrides stale unsafe choices with JPEG+control-only',initial.android_backends.capture==='jpeg'&&initial.android_backends.input==='scrcpy');
  check('initial product capture budget uses physical display, not411×914 fixture limit',initial.capture_counters.max_size===2400);
  check('JPEG is hardware H264 and fixed intermediate quality70',initial.capture_counters.hardware_encoder===true&&initial.capture_counters.jpeg_quality===70);
  check('actual phone view decodes synthetic pixels',await ev("(()=>{const d=document.querySelector('.device-frame canvas').getContext('2d').getImageData(100,100,1,1).data;return d[0]>150&&d[1]<100&&d[2]<120})()"));
  // Actual DOM pointer + keyboard interactions, not just fabricated messages.
  const pointerStart=events().filter(e=>e.kind==='control'&&e.type===2).length;
  const rect=await ev("(()=>{const r=document.querySelector('.device-frame canvas').getBoundingClientRect();return{x:r.x,y:r.y,w:r.width,h:r.height}})()");
  const from={x:rect.x+rect.w*.3,y:rect.y+rect.h*.3},to={x:rect.x+rect.w*.6,y:rect.y+rect.h*.5};
  await cdp('Input.dispatchMouseEvent',{type:'mouseMoved',...from});await cdp('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',buttons:1,clickCount:1,...from});
  await cdp('Input.dispatchMouseEvent',{type:'mouseMoved',button:'left',buttons:1,...to});await sleep(70);await cdp('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',buttons:0,clickCount:1,...to});
  await until('actual canvas gesture',()=>events().filter(e=>e.kind==='control'&&e.type===2).length>=pointerStart+3);
  const pointerEvents=events().filter(e=>e.kind==='control'&&e.type===2).slice(pointerStart);
  check('actual canvas DOWN/MOVE/UP reach the phone socket',pointerEvents.every(e=>e.serial===ids[0])&&[0,2,1].every(action=>pointerEvents.some(e=>e.action===action)));
  const keyboardStart=events().filter(e=>e.kind==='control').length;
  await ev("document.querySelector('[data-action=kbd]').click();document.getElementById('kbd-input').value='phone DOM keyboard';document.getElementById('kbd-send').click();document.getElementById('kbd-bs').click();document.getElementById('kbd-ret').click()");
  await until('actual keyboard drawer',()=>events().filter(e=>e.kind==='control').length>=keyboardStart+5);
  const keyboardEvents=events().filter(e=>e.kind==='control').slice(keyboardStart);
  check('actual keyboard text/Backspace/Return target phone',keyboardEvents.every(e=>e.serial===ids[0])&&keyboardEvents.some(e=>e.type===1)&&keyboardEvents.filter(e=>e.type===0).length===4);
  check('phone toolbar omits simulator Rotate and appearance',await ev("!document.querySelector('[data-action=rotate]')&&!document.querySelector('[data-action=appear]')"));
  await ev("document.querySelector('.backend-trigger').click()");
  check('physical Scaling row exists directly below Capture',await ev("(()=>{const groups=[...document.querySelectorAll('.backend-field')];return groups.map(g=>g.querySelector('.backend-field-label').textContent).join(',')==='Capture,Scaling,Input'&&document.querySelectorAll('[data-kind=scaling]').length===3})()"));
  check('physical Capture offers JPEG and scrcpy video',await ev("document.querySelectorAll('[data-kind=capture]').length===2&&!!document.querySelector('[data-kind=capture][data-choice=scrcpy]')&&document.querySelector('[data-kind=capture][data-choice=jpeg]')?.getAttribute('aria-checked')==='true'&&document.querySelectorAll('[data-kind=input]').length===1&&!!document.querySelector('[data-kind=input][data-choice=scrcpy]')"));
  check('phone backend explanation and active badge are accurate',await ev("document.querySelector('.backend-explainer').textContent.includes('USB or Wi-Fi')&&document.querySelector('[data-effective=capture]').textContent==='Using JPEG70 → H.264'"));
  for(const action of ['home','back','app-switcher']){
    const n=events().filter(e=>e.kind==='control'&&e.type===0).length;
    await ev(`document.querySelector('[data-action=${action}]').click()`);
    await until('actual toolbar '+action,()=>events().filter(e=>e.kind==='control'&&e.type===0).length>=n+2);
    const last=events().filter(e=>e.kind==='control'&&e.type===0).slice(-2);
    check('toolbar '+action+' targets selected phone control socket',last.every(e=>e.serial===ids[0]));
  }
  const beforeStop={frames:initial.frames,jpeg:launches().length,control:controls().length};
  check('forged physical Stop is rejected natively',(await api('/api/stop/'+encodeURIComponent(ids[0]),'POST')).status===404);
  check('forged physical shutdown-status is rejected natively',(await api('/api/stop-status/'+encodeURIComponent(ids[0]))).status===404);
  await sleep(500);const afterStop=await live();
  check('rejected Stop leaves phone stream/helpers running',afterStop.frames>beforeStop.frames&&launches().length===beforeStop.jpeg&&controls().length===beforeStop.control);
  const image=await cdp('Page.captureScreenshot',{format:'png'});fs.writeFileSync(root+'/physical-panel-synthetic.png',Buffer.from(image.data,'base64'));
  check('scaling options are exactly x1/x0.5/x0.25 and default x1',await ev("[...document.querySelectorAll('[data-kind=scaling]')].map(b=>b.textContent).join(',')==='x1,x0.5,x0.25'&&document.querySelector('[data-kind=scaling][data-choice=\"1\"]').getAttribute('aria-checked')==='true'"));
  for(const [scale,edge]of [['0.5',1200],['0.25',600]]) {
    const n=launches().length;
    const selector='[data-kind=scaling][data-choice="'+scale+'"]';await ev('document.querySelector('+JSON.stringify(selector)+').click()');
    await until('UI source scaling '+scale,async()=>{const s=await live();return s?.frames>2&&s.android_backends.jpeg_scale===scale&&s.capture_counters.max_size===edge});
    check('scale '+scale+' reaches Android helper before transmission',launches().length===n+1&&events().filter(e=>e.kind==='jpeg_process').at(-1).source_edge===edge);
    check('scale '+scale+' persisted per physical identity',await ev('JSON.parse(localStorage.getItem("simwisp.android-backends.v1:"+encodeURIComponent("device:"+'+JSON.stringify(ids[0])+'))).scaling==='+JSON.stringify(scale)));
    check('scale '+scale+' never shrinks full physical input coordinates',(await live()).input_counters.width===1080&&(await live()).input_counters.height===2400);
  }
  for(const [width,height]of [[320,568],[390,844],[844,390]]) {
    await cdp('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:false});
    await sleep(150); // Allow viewport resize/layout/position listeners to settle.
    check('physical Scaling popover fits '+width+'×'+height,await ev("(()=>{const r=document.querySelector('.backend-popover').getBoundingClientRect();return r.left>=0&&r.top>=0&&r.right<=innerWidth+1&&r.bottom<=innerHeight+1&&[...document.querySelectorAll('[data-kind=scaling]')].every(b=>b.getBoundingClientRect().height>=44)})()"));
  }
  const scaledShot=await cdp('Page.captureScreenshot',{format:'png'});fs.writeFileSync(root+'/physical-scaling-synthetic.png',Buffer.from(scaledShot.data,'base64'));
  await cdp('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});
  await ev("document.querySelector('[data-action=close]').click()");await until('scale panel retired',async()=>!await live());
  await ev("document.querySelector('.device-item').click()");await active();
  check('scale persists across panel recreation',(await live()).capture_counters.max_size===600&&(await live()).android_backends.jpeg_scale==='0.25');
  await ev("document.querySelector('.backend-trigger').click();document.querySelector('[data-kind=scaling][aria-checked=true]').focus()");
  await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:'Home',code:'Home',windowsVirtualKeyCode:36});await cdp('Input.dispatchKeyEvent',{type:'keyUp',key:'Home',code:'Home',windowsVirtualKeyCode:36});
  await until('keyboard scaling x1',async()=>(await live())?.capture_counters.max_size===2400);
  check('keyboard Home selects scaling x1 without changing capture/input',(await live()).android_backends.capture==='jpeg'&&(await live()).android_backends.input==='scrcpy');
  await ev("document.querySelector('[data-action=close]').click()");await until('phone panel closed',async()=>!await live());await sleep(300);
  for(const id of ids){
    const before=events().length;await direct(id);const s=await active();
    check('native Auto routes '+id+' to JPEG+scrcpy',s.android_backends.capture==='jpeg'&&s.android_backends.input==='scrcpy'&&s.capture_counters.max_size===2400);
    const count=events().filter(e=>e.kind==='control').length;
    for(const m of [{type:'touch_down',x:.2,y:.3},{type:'touch_move',x:.4,y:.5},{type:'touch_up',x:.4,y:.5},{type:'text',text:'physical fixture'},{type:'key',key:'enter'},{type:'home'},{type:'back'},{type:'app_switcher'}])await send(m);
    await until('physical controls '+id,()=>events().filter(e=>e.kind==='control').length>=count+12);
    const control=events().filter(e=>e.kind==='control').slice(count),down=Buffer.from(control.find(e=>e.type===2).hex,'hex');
    check('touch/key/text/navigation are serial-scoped for '+id,control.every(e=>e.serial===id)&&control.some(e=>e.type===1)&&control.some(e=>e.type===0));
    check('touch packets use physical1080×2400 coordinates for '+id,down.readUInt16BE(18)===1080&&down.readUInt16BE(20)===2400&&down.readUInt32BE(10)===216&&down.readUInt32BE(14)===720);
    await send({type:'rotate'});await send({type:'appearance',mode:'light'});await sleep(250);
    check('unsupported physical controls never reach legacy/host input '+id,legacy().length===0);
    const command=events().slice(before).filter(e=>e.kind==='command').map(e=>e.args);
    check('no emulator/video/shaping commands for '+id,command.every(a=>a[0]==='-s'&&a[1]===id)&&!command.some(a=>a.includes('emu')||a.includes('setprop')||a.includes('settings')||a.includes('video=true')));
    await directClose();
  }
  // The fake Android producer emits pre-sized JPEG bytes, before any Mac decode.
  put('physical-size.json',{width:320,height:640});put('display.json',{width:320,height:640});put('jpeg-mode.json',{scaledFixture:true,static:true});
  for(const [scale,edge,w,h]of [['1',640,320,640],['0.5',320,160,320],['0.25',160,80,160]]) {
    await direct(ids[0],'jpeg','scrcpy',scale);await active();
    await until('actual presized JPEG '+scale,()=>ev('document.getElementById("phone-canvas").width==='+w+'&&document.getElementById("phone-canvas").height==='+h));
    const s=await live();check('wire JPEG and WebCodecs dimensions match '+scale,s.capture_counters.video_width===w&&s.capture_counters.video_height===h&&s.capture_counters.max_size===edge&&events().filter(e=>e.kind==='jpeg_process').at(-1).source_edge===edge);
    const n=events().filter(e=>e.kind==='control'&&e.type===2).length;await send({type:'touch_down',x:.2,y:.3});await send({type:'touch_up',x:.2,y:.3});
    await until('scaled view input '+scale,()=>events().filter(e=>e.kind==='control'&&e.type===2).length>=n+2);
    const d=Buffer.from(events().filter(e=>e.kind==='control'&&e.type===2).slice(n)[0].hex,'hex');
    check('downscaled JPEG never scales touch coordinates '+scale,d.readUInt16BE(18)===320&&d.readUInt16BE(20)===640&&d.readUInt32BE(10)===64&&d.readUInt32BE(14)===192);
    if(scale==='0.25') {
      put('display.json',{width:640,height:320});put('jpeg-mode.json',{scaledFixture:true,static:true,rotation:true});
      await until('scaled landscape JPEG',()=>ev('document.getElementById("phone-canvas").width===160&&document.getElementById("phone-canvas").height===80'));
      await until('scaled rotation retains physical input size',async()=>(await live()).input_counters.width===640);
      check('scaled rotation uses full physical display, not JPEG dimensions',(await live()).input_counters.height===320);
    }
    await directClose();
  }
  for(const bad of ['0','2','-1','NaN','0.5;id']) {
    await direct(ids[0],'jpeg','scrcpy',bad);await active();
    check('native rejects arbitrary scale via x1 normalization '+bad,(await live()).capture_counters.max_size===640&&(await live()).android_backends.jpeg_scale==='1');await directClose();
  }
  remove('physical-size.json');remove('jpeg-mode.json');put('display.json',{width:1080,height:2400});
  await direct(ids[0]);await active();const h=launches().length,c=controls().length;
  await send({type:'settings',dev_w:320,dev_h:640});put('window-size.json',{width:411,height:914});await sleep(800);
  check('browser decode/host size cannot shrink physical source budget',(await live()).capture_counters.max_size===2400&&launches().length===h);
  put('display.json',{width:640,height:320});put('jpeg-mode.json',{rotation:true});
  await until('rotated WebCodecs pixels',()=>ev("document.getElementById('phone-canvas').width===640&&document.getElementById('phone-canvas').height===320"));
  await until('rotated input dimensions',async()=>(await live()).input_counters.width===640);
  check('physical rotation updates independent input without restarting helper',launches().length===h&&controls().length===c);
  await send({type:'settings',stream_paused:true});await until('paused phone',async()=>(await live()).state==='Paused');await sleep(500);
  check('pause retires only owned JPEG producers',events().filter(e=>e.kind==='jpeg_process').every(e=>{try{process.kill(e.pid,0);return false}catch{return true}}));
  await send({type:'settings',stream_paused:false});await active();check('resume owns a fresh JPEG helper',launches().length===h+1);
  fs.writeFileSync(root+'/device-offline','1');await api('/api/sims');await until('offline latches unavailable',async()=>(await live()).android_backends.effective_capture==='unavailable');
  const offline=await live(),wire=received;await sleep(450);const stoppedWire=received;await sleep(500);
  check('disconnect cannot keep sending cached phone pixels',received===stoppedWire&&offline.android_backends.effective_input==='unavailable'&&offline.android_backends.reason.includes('offline'));
  check('offline/unauthorized device is excluded from refreshed inventory',(await api('/api/sims')).value.length===0);
  check('disconnect never invokes legacy input',legacy().length===0&&stoppedWire>=wire);
  await directClose();for(const f of ['device-offline','jpeg-mode.json','window-size.json'])remove(f);put('display.json',{width:1080,height:2400});
  // Explicit unsupported requests must fail before any producer is started.
  for(const [capture,input]of [['raw','scrcpy'],['current','scrcpy'],['scrcpy','current'],['jpeg','current']]){
    const before={jpeg:launches().length,control:controls().length};await direct(ids[0],capture,input);
    await until('native capability refusal '+capture+'/'+input,async()=>(await live())?.android_backends.effective_capture==='unavailable');await sleep(200);
    check('native rejects forged '+capture+'/'+input+' without producer',(await live()).frames===0&&launches().length===before.jpeg&&controls().length===before.control);
    await directClose();
  }
  fs.writeFileSync(root+'/unavailable','1');await direct(ids[0]);await until('missing physical input visibly unavailable',async()=>{const s=await live();return s?.frames>2&&s.android_backends.effective_input==='unavailable'});
  const unavailable=await live();await send({type:'touch_down',x:.2,y:.3});await sleep(300);
  check('missing scrcpy input never falls back to Current/HID',unavailable.android_backends.capture==='jpeg'&&unavailable.android_backends.effective_input==='unavailable'&&legacy().length===0);
  await directClose();remove('unavailable');fs.writeFileSync(root+'/jpeg-unavailable','1');await direct(ids[0]);await until('missing helper visible',async()=>(await live())?.android_backends.effective_capture==='unavailable');
  check('missing phone helper never selects another capture method',(await live()).frames===0&&(await live()).android_backends.reason.includes('JPEG fixture unavailable'));
  await directClose();remove('jpeg-unavailable');put('physical-size.json',{width:8000,height:5000});await direct(ids[0]);await active();
  check('large physical display obeys existing4096px bound, not914px',(await live()).capture_counters.max_size===4096);await directClose();
  put('physical-size.json',{width:0,height:0});await direct(ids[0]);await active();
  check('unknown size retains existing valid initial browser budget',(await live()).capture_counters.max_size===914);await directClose();
  check('every ADB operation is a known selected fixture serial',events().filter(e=>e.kind==='command').every(e=>e.args[0]==='-s'&&ids.includes(e.args[1])));
  check('all phone sessions are control-only/no shaping/no global ADB',events().filter(e=>e.kind==='command').every(e=>!e.args.includes('video=true')&&!e.args.includes('setprop')&&!e.args.includes('emu')&&!e.args.includes('kill-server')));
  check('zero legacy input calls across phone scenarios',legacy().length===0);
  remove('physical-size.json');put('display.json',{width:320,height:640});
  await direct('emulator-5554','jpeg','scrcpy','0.25');
  await until('emulator ignores forged phone scaling',async()=>{const s=await live();return s?.frames>2&&s.android_backends.effective_capture==='jpeg'});
  check('emulator ignores physical-only scale query',(await live()).capture_counters.max_size===640&&(await live()).android_backends.jpeg_scale==='1');await directClose();
  await cdp('Page.reload');await until('emulator inventory ready',()=>ev("document.querySelector('.device-item')!==null"));
  await ev("document.querySelector('.device-item').click()");await until('emulator panel streams',async()=>(await live())?.frames>2);
  await ev("document.querySelector('.backend-trigger').click()");
  check('emulator scrcpy gains Scaling without changing capture/input choices',await ev("document.querySelectorAll('[data-kind=scaling]').length===3&&document.querySelectorAll('[data-kind=capture]').length===5&&document.querySelectorAll('[data-kind=input]').length===3"));
  await ev("document.querySelector('[data-action=close]').click()");await until('emulator fixture retired',async()=>!await live());
  // Intentionally interleaved native inventory: sort only the rendered sidebar.
  put('sidebar-inventory.json',{reverse:false});await api('/api/sims');await cdp('Page.reload');
  const sidebarIDs=()=>ev("[...document.querySelectorAll('button.device-item')].map(b=>b.dataset.udid).join(',')");
  await until('mixed sidebar inventory',async()=>(await sidebarIDs()).split(',').length===4);
  check('sidebar always lists real devices before simulators',await sidebarIDs()==='USBPHYSICALTEST123,adb-PHYSICAL-TEST._adb-tls-connect._tcp,ios-sidebar,emulator-5554');
  check('sidebar keeps native inventory order unchanged',(await api('/api/sims')).value.map(d=>d.id).join(',')==='ios-sidebar,USBPHYSICALTEST123,emulator-5554,adb-PHYSICAL-TEST._adb-tls-connect._tcp');
  await ev("(()=>{const c=document.getElementById('proj-filter');c.checked=true;c.dispatchEvent(new Event('change'))})()");
  check('project filter still groups remaining real devices first',await sidebarIDs()==='USBPHYSICALTEST123,ios-sidebar');
  await ev("(()=>{const c=document.getElementById('proj-filter');c.checked=false;c.dispatchEvent(new Event('change'))})()");
  check('filter reset preserves real-first grouping',await sidebarIDs()==='USBPHYSICALTEST123,adb-PHYSICAL-TEST._adb-tls-connect._tcp,ios-sidebar,emulator-5554');
  put('sidebar-inventory.json',{reverse:true});await api('/api/sims');await cdp('Page.reload');
  await until('refreshed native order applied',async()=>(await sidebarIDs())==='adb-PHYSICAL-TEST._adb-tls-connect._tcp,USBPHYSICALTEST123,emulator-5554,ios-sidebar');
  check('refresh/reload keeps stable order within real and simulator groups',true);
  check('real-first sidebar still exposes no phone Stop buttons',await ev("[...document.querySelectorAll('button.device-item')].filter(b=>!b.dataset.udid.startsWith('emulator-')&&b.dataset.platform==='android').every(b=>!b.closest('.device-row').querySelector('.device-stop-btn'))"));
  remove('sidebar-inventory.json');
  check('zero browser exceptions',exceptions.length===0);
  fs.writeFileSync(root+'/physical-browser-review.json',JSON.stringify({checks,exceptions,initial,received,real_device_actions:false,real_capture:false,real_input:false},null,2));
  console.log(JSON.stringify({physicalBrowserChecks:checks.length,received,exceptions:exceptions.length}));
}catch(error){let debug;try{debug={session:await live(),status:await ev('window.phoneStatus'),layout:await ev("(()=>{const m=document.querySelector('.backend-popover');return m?{hidden:m.hidden,box:m.getBoundingClientRect().toJSON(),viewport:[innerWidth,innerHeight],scaling:[...m.querySelectorAll('[data-kind=scaling]')].map(b=>b.getBoundingClientRect().toJSON())}:null})()"),recent:events().slice(-15)}}catch{}fs.writeFileSync(root+'/physical-browser-review.json',JSON.stringify({error:String(error),checks,exceptions,debug},null,2));throw error}
finally{
  for(const f of ownedFiles)remove(f);
  if(ws?.readyState===WebSocket.OPEN){try{await cdp('Browser.close')}catch{}ws.close()}
  for(const p of pending.values())clearTimeout(p.timer);await sleep(250);
  if(chrome?.exitCode===null)try{process.kill(-chrome.pid,'SIGTERM')}catch{}
}
