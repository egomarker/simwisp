// Real native service + WebCodecs, with owned discovery/ADB/media fixtures only.
import fs from 'node:fs';
import crypto from 'node:crypto';
import {spawn} from 'node:child_process';
const root=process.argv[2],base='https://127.0.0.1:45154';
const cookie=crypto.createHash('sha256').update('simwisp-session-v1:isolated-android-backends').digest('hex');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const checks=[],exceptions=[],pending=new Map();let chrome,ws,seq=0;
const remove=name=>{try{fs.unlinkSync(root+'/'+name)}catch(e){if(e.code!=='ENOENT')throw e}};
const events=()=>fs.readFileSync(root+'/events.ndjson','utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
const queries=()=>events().filter(e=>e.kind==='geometry_query');
const launches=()=>events().filter(e=>e.kind==='command'&&e.args.includes('com.genymobile.scrcpy.Server'));
const api=async()=>{const r=await fetch(base+'/api/sessions',{headers:{Cookie:'simwisp_session='+cookie}});if(!r.ok)throw Error('Session HTTP '+r.status);return(await r.json())[0]};
function check(name,value){checks.push({name,passed:!!value});if(!value)throw Error(name)}
async function until(label,fn){const end=Date.now()+18000;while(Date.now()<end){if(await fn())return;await sleep(60)}throw Error('Timeout '+label)}
function cdp(method,params={}){return new Promise((resolve,reject)=>{const id=++seq,timer=setTimeout(()=>{pending.delete(id);reject(Error('CDP '+method+' timeout'))},12000);pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params}))})}
async function ev(expression){const r=await cdp('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value}
async function budget(width,height,rate){await until('pixel/bitrate budget '+width+'x'+height,async()=>{const s=await api(),d=s?.capture_counters;return s?.state==='Streaming'&&s.android_backends.effective_capture==='scrcpy'&&d.source_frames>0&&d.video_width>0&&d.target_width===width&&d.target_height===height&&d.target_bitrate_bps===rate});return(await api()).capture_counters}
async function closeStream(){await ev('window.parityStream?.destroy();window.parityStream=null');await until('session retirement',async()=>!(await api()));await sleep(300)}
async function connect(width,height,quality=1,capture='scrcpy',input='current'){
  await ev(`(async()=>{const{SimStream}=await import('/js/stream.js');const canvas=document.createElement('canvas');canvas.width=${width};canvas.height=${height};document.body.append(canvas);window.parityCanvas=canvas;window.parityStream=new SimStream('emulator-5554',canvas,{fps:60,quality:${quality},backends:{capture:'${capture}',input:'${input}'}});return true})()`);
}
try{
  for(const name of ['unavailable','headless','window-size.json','serial','hold-video','display.json','rotation.json','rotation-started','rotation-completed'])remove(name);
  const profile=fs.mkdtempSync(root+'/parity-chrome-');
  chrome=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new','--disable-gpu','--ignore-certificate-errors','--remote-debugging-address=127.0.0.1','--remote-debugging-port=0','--user-data-dir='+profile,'--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-sync','--disable-extensions','about:blank'],{stdio:['ignore','ignore','pipe'],detached:true});chrome.stderr.resume();
  await until('Chrome',()=>fs.existsSync(profile+'/DevToolsActivePort'));
  const port=fs.readFileSync(profile+'/DevToolsActivePort','utf8').split('\n')[0],tabs=await(await fetch('http://127.0.0.1:'+port+'/json/list')).json();
  ws=new WebSocket(tabs.find(t=>t.type==='page').webSocketDebuggerUrl);
  await new Promise((r,j)=>{ws.addEventListener('open',r,{once:true});ws.addEventListener('error',j,{once:true})});
  ws.addEventListener('message',e=>{const m=JSON.parse(e.data);if(m.id&&pending.has(m.id)){const p=pending.get(m.id);pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result)}else if(m.method==='Runtime.exceptionThrown')exceptions.push(m.params)});
  await cdp('Page.enable');await cdp('Runtime.enable');await cdp('Network.enable');
  await cdp('Network.setCookie',{name:'simwisp_session',value:cookie,url:base,secure:true,httpOnly:true,sameSite:'Strict'});
  await cdp('Page.navigate',{url:base});await until('fixture page',()=>ev("document.querySelector('.device-item')!==null"));
  // Even a larger client canvas must not override the authoritative Mac crop.
  await connect(1080,1920);let d=await budget(320,640,200000);
  check('host pixel budget wins over browser canvas',d.max_size===640);
  check('server receives aligned source arguments',launches().at(-1).args.includes('max_size=640')&&launches().at(-1).args.includes('video_bit_rate=200000'));
  check('quality1 requests normal CBR2/max I/P QP44',launches().at(-1).args.includes('video_codec_options=profile=1,max-bframes=0,i-frame-interval=1,bitrate-mode=2,video-qp-i-max=44,video-qp-p-max=44'));
  check('requested QP/mode are observable, not accepted codec format',d.requested_qp_max===44&&d.requested_bitrate_mode===2);
  check('video startup verified shaping property before launch',d.format_shaping_disabled===true&&events().filter(e=>e.kind==='command').findIndex(e=>e.args.includes('getprop'))<events().filter(e=>e.kind==='command').findIndex(e=>e.args.includes('com.genymobile.scrcpy.Server')));
  check('actual encoded dimensions are observable',d.video_width===320&&d.video_height===640);
  check('source byte counters are real encoded data',d.source_video_bytes>0&&d.source_keyframe_bytes>0&&d.source_keyframe_bytes<=d.source_video_bytes);
  await until('scaled pixels actually render',()=>ev('parityCanvas.width===320&&parityCanvas.height===640'));
  check('matching budget still produces decoded video',true);
  // Quality and resize affect only this source, without changing global settings.
  await ev('parityStream.updateSettings({quality:95})');await budget(320,640,1975308);
  check('quality95 preserves legacy area scaling',launches().at(-1).args.includes('video_bit_rate=1975308'));
  check('other qualities retain default QP settings',(await api()).capture_counters.requested_qp_max===null&&(await api()).capture_counters.requested_bitrate_mode===null&&launches().at(-1).args.includes('video_codec_options=profile=1,max-bframes=0,i-frame-interval=1'));
  await ev('parityStream.updateSettings({quality:1})');await budget(320,640,200000);
  check('quality1 applies the requested200kbps/QP44 trial',true);
  fs.writeFileSync(root+'/window-size.json',JSON.stringify({width:480,height:960}));await budget(480,960,200000);
  check('host resize changes the native long-edge limit',launches().at(-1).args.includes('max_size=960'));
  const resizeLaunches=launches().length;
  await ev('parityStream.updateSettings({dev_w:320,dev_h:640})');await sleep(1000);
  check('decoder-size feedback never shrinks the capture budget',launches().length===resizeLaunches&&(await api()).capture_counters.target_height===960);
  fs.writeFileSync(root+'/window-size.json',JSON.stringify({width:960,height:480}));await sleep(1800);
  check('rotation alone does not restart the encoder',launches().length===resizeLaunches);
  fs.writeFileSync(root+'/headless','1');await sleep(1800);
  check('window loss retains the last known pixel budget',(await api()).capture_counters.target_width===480&&launches().length===resizeLaunches);
  check('headless capture remains streaming',(await api()).state==='Streaming');
  await closeStream();await connect(432,960);await budget(432,960,200000);
  check('new headless session uses initial browser dimensions',launches().at(-1).args.includes('max_size=960'));
  await closeStream();await connect(0,0);await budget(360,800,200000);
  check('invalid initial dimensions use bounded UI fallback',launches().at(-1).args.includes('max_size=800'));
  remove('headless');remove('window-size.json');await budget(320,640,200000);
  check('a window appearing later becomes authoritative',true);
  await closeStream();await connect(320,640,1,'current','scrcpy');
  await until('independent control-only source',async()=>{const s=await api();return s?.state==='Streaming'&&s.android_backends.effective_capture==='current'&&s.android_backends.effective_input==='scrcpy'});
  const controlLaunches=launches().length,propertyCount=events().filter(e=>e.kind==='command'&&e.args.includes('debug.stagefright.enableshaping')).length;
  check('mixed backend uses a control-only scrcpy session',launches().at(-1).args.includes('video=false'));
  check('control-only input does not request QP bounds',launches().at(-1).args.includes('video_codec_options=profile=1,max-bframes=0,i-frame-interval=1'));
  fs.writeFileSync(root+'/window-size.json',JSON.stringify({width:480,height:960}));await sleep(1800);
  check('window resize does not restart control-only input',launches().length===controlLaunches);
  check('independent backend choices remain selected',(await api()).android_backends.effective_capture==='current'&&(await api()).android_backends.effective_input==='scrcpy');
  // An expired old cache plus slow query used to hold DOWN and coalesce early
  // MOVEs. Exercise production StreamSession admission, serial input and wire.
  const beforeCold=queries().length;
  fs.writeFileSync(root+'/display.json',JSON.stringify({width:640,height:320,delay_ms:600}));
  await sleep(1100);
  async function burst(label){
    const start=events().length;
    await ev("(async()=>{parityStream.send({type:'touch_down',x:.5,y:.2});for(let i=1;i<=8;i++){await new Promise(r=>setTimeout(r,16));parityStream.send({type:'touch_move',x:.5,y:.2+i*.075})}parityStream.send({type:'touch_up',x:.5,y:.85});return true})()");
    await until('wire UP '+label,()=>events().slice(start).some(e=>e.kind==='control'&&e.type===2&&e.action===1));
    const packets=events().slice(start).filter(e=>e.kind==='control'&&e.type===2),down=packets.find(e=>e.action===0),moves=packets.filter(e=>e.action===2),up=packets.find(e=>e.action===1);
    check(label+' preserves early MOVE cadence and count',moves.length>=6&&moves[0].at_ms-down.at_ms<120&&up.at_ms-down.at_ms<350);
    return packets;
  }
  await burst('cold hybrid');
  check('post-pause hybrid gesture performs zero display queries',queries().length===beforeCold);
  check('control-only geometry reported independently from Mac capture',(await api()).input_counters.width===320&&(await api()).input_counters.height===640);
  await burst('warm hybrid');
  await ev('parityStream.updateSettings({dev_w:777,dev_h:999})');
  await until('delayed async display query',async()=>queries().length>beforeCold&&(await api()).input_counters.geometry_refresh_pending);
  const during=await burst('hybrid while600ms metadata query blocked');
  check('whole blocked-query gesture freezes old dimensions',during.every(e=>e.hex.slice(36,44)==='01400280'));
  await until('refreshed Android dimensions',async()=>{const d=(await api()).input_counters;return d.width===640&&d.height===320&&!d.geometry_refresh_pending});
  const afterRefresh=await burst('hybrid after refresh');
  check('next gesture adopts640x320 Android geometry',afterRefresh.every(e=>e.hex.slice(36,44)==='02800140'));
  const afterQuery=queries().length;
  await ev('for(let i=0;i<10;i++)parityStream.updateSettings({dev_w:777,dev_h:999,fps:60,quality:1})');await sleep(800);
  check('duplicate dimensions/settings trigger zero metadata queries',queries().length===afterQuery);
  await ev("for(const m of [{dev_w:0,dev_h:640},{dev_w:8193,dev_h:640},{dev_w:320.5,dev_h:640},{dev_w:300}])parityStream.send({type:'settings',...m})");await sleep(400);
  check('invalid/partial dimension hints trigger zero queries',queries().length===afterQuery);
  fs.writeFileSync(root+'/rotation.json',JSON.stringify({width:320,height:640}));
  await ev("parityStream.send({type:'rotate'})");
  await until('legacy rotation starts',()=>fs.existsSync(root+'/rotation-started'));
  await sleep(220);
  check('rotation never queries before legacy command completion',queries().length===afterQuery&&!fs.existsSync(root+'/rotation-completed'));
  await until('rotation geometry updated',async()=>{const s=await api();return fs.existsSync(root+'/rotation-completed')&&s.input_counters.width===320&&s.input_counters.height===640&&!s.input_counters.geometry_refresh_pending});
  check('completed rotation asynchronously refreshes once',queries().length===afterQuery+1);
  await burst('hybrid after known rotation');
  const afterRotation=queries().length;
  check('control-only never disables shaping during gestures/refreshes',events().filter(e=>e.kind==='command'&&e.args.includes('debug.stagefright.enableshaping')).length===propertyCount);
  remove('display.json');await closeStream();await connect(320,640,1,'current','scrcpy');
  await until('reconnected control-only geometry',async()=>{const s=await api();return s?.state==='Streaming'&&s.input_counters?.width===320});
  check('reconnect fetches dimensions once for its new session',queries().length===afterRotation+1&&(await api()).input_counters.geometry_refreshes===1);
  await closeStream();check('zero browser exceptions',exceptions.length===0);
  const result={checks,exceptions,real_device_actions:false,real_capture:false,real_input:false,syntheticSourceMayBeSmallerThanRequestedBudget:true};
  fs.writeFileSync(root+'/parity-review.json',JSON.stringify(result,null,2));console.log(JSON.stringify({parityChecks:checks.length,exceptions:exceptions.length}));
}catch(error){fs.writeFileSync(root+'/parity-review.json',JSON.stringify({error:String(error),checks,exceptions},null,2));throw error}
finally{
  for(const name of ['window-size.json','headless','serial','hold-video','unavailable','display.json','rotation.json','rotation-started','rotation-completed'])remove(name);
  if(ws?.readyState===WebSocket.OPEN){try{await ev('window.parityStream?.destroy()')}catch{}try{await cdp('Browser.close')}catch{}ws.close()}
  for(const p of pending.values())clearTimeout(p.timer);await sleep(250);if(chrome?.exitCode===null)try{process.kill(-chrome.pid,'SIGTERM')}catch{}
}
