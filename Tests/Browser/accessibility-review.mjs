import fs from 'node:fs';import path from 'node:path';import {spawn,execFileSync} from 'node:child_process';
const root=process.argv[2];const source=fs.realpathSync(process.cwd());if(!root||process.platform!=='darwin'||typeof WebSocket==='undefined')throw Error('Run on macOS with Node22 and a private output directory');
if(!fs.existsSync(source+'/Sources/Accessibility.swift'))throw Error('Run from the project root');
const report={host:execFileSync('/bin/hostname',{encoding:'utf8'}).trim(),canonical:source,fixtures:true,liveAppRestarted:false,checks:[],screenshots:[]};
const base='http://127.0.0.1:45151';const delay=ms=>new Promise(r=>setTimeout(r,ms));
const status=async()=>await(await fetch(base+'/fixture/status')).json();
const profile=path.join(root,'chrome-profile');
const child=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new','--disable-gpu','--force-device-scale-factor=1','--remote-debugging-address=127.0.0.1','--remote-debugging-port=0',`--user-data-dir=${profile}`,'--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-sync','--disable-extensions','about:blank'],{stdio:['ignore','ignore','pipe'],detached:true});
let chromeErr='';child.stderr.on('data',b=>chromeErr=(chromeErr+b.toString()).slice(-10000));
let ws;let seq=0;const pending=new Map();const exceptions=[];
function cdp(method,params={}){return new Promise((resolve,reject)=>{const id=++seq;const timer=setTimeout(()=>{pending.delete(id);reject(Error('CDP timeout '+method))},12000);pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params}))});}
async function evaluate(expression){const r=await cdp('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value;}
async function wait(expression,ms=4000){const end=Date.now()+ms;while(Date.now()<end){if(await evaluate(expression))return true;await delay(40)}throw Error('UI timeout: '+expression)}
async function check(name,expression){const value=await evaluate(expression);report.checks.push({name,passed:value===true});if(value!==true)throw Error('FAIL '+name+': '+JSON.stringify(value));}
async function nativeCheck(name,condition){const value=await condition();report.checks.push({name,passed:value===true});if(value!==true)throw Error('FAIL '+name);}
async function click(selector){await evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);await delay(80)}
async function shot(name){await evaluate('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))');await delay(400);const result=await cdp('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});fs.writeFileSync(path.join(root,name+'.png'),Buffer.from(result.data,'base64'));report.screenshots.push(name+'.png');}
async function closeStreams(){await evaluate(`document.querySelectorAll('[data-action="close"]').forEach(b=>b.click())`);await delay(350)}
const androidInfo=async()=> (await status()).sessions.find(s=>s.id==='emulator-5554')?.accessibility;
async function navigate(width,height,mobile,device='emulator-5554'){
 await cdp('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile});
 await cdp('Emulation.setTouchEmulationEnabled',{enabled:mobile});
 await cdp('Page.navigate',{url:base+'/?view='+device});
 await wait(`!!document.querySelector('.sim-panel .device-frame canvas') && document.querySelector('.panel-status').textContent === 'Live'`);
}
try{
 for(let i=0;!fs.existsSync(path.join(profile,'DevToolsActivePort'));i++){if(i>120||child.exitCode!==null)throw Error('Chrome startup '+chromeErr);await delay(100)}
 const port=fs.readFileSync(path.join(profile,'DevToolsActivePort'),'utf8').split('\n')[0];const tabs=await(await fetch(`http://127.0.0.1:${port}/json/list`)).json();
 ws=new WebSocket(tabs.find(t=>t.type==='page').webSocketDebuggerUrl);await new Promise((res,rej)=>{ws.addEventListener('open',res,{once:true});ws.addEventListener('error',rej,{once:true})});
 ws.addEventListener('message',e=>{const m=JSON.parse(e.data);if(m.id&&pending.has(m.id)){const p=pending.get(m.id);clearTimeout(p.timer);pending.delete(m.id);m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result)}else if(m.method==='Runtime.exceptionThrown')exceptions.push(m.params)});
 await cdp('Page.enable');await cdp('Runtime.enable');await cdp('Network.enable');
 await cdp('Network.setCookie',{name:'fixture',value:'paired',url:base,httpOnly:true,sameSite:'Strict'});
 await cdp('Page.addScriptToEvaluateOnNewDocument',{source:`window.__wire={settings:[],inputs:[],acks:0,sockets:[]};const Real=WebSocket;window.WebSocket=class extends Real{constructor(...args){super(...args);window.__wire.sockets.push(this)}send(data){try{const m=JSON.parse(data);if(m.type==='settings'){window.__wire.settings.push(m);if(window.__wire.settings.length>128)window.__wire.settings.shift()}else if(m.type==='frame_ack')window.__wire.acks++;else{window.__wire.inputs.push(m);if(window.__wire.inputs.length>128)window.__wire.inputs.shift()}}catch{}return super.send(data)}};`});
 await fetch(base+'/fixture/mode',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({real:false})});
 const sizes=[{name:'desktop',w:1440,h:1000,m:false},{name:'phone',w:390,h:844,m:true},{name:'small-phone',w:320,h:568,m:true},{name:'short-phone',w:375,h:500,m:true},{name:'landscape-phone',w:844,h:390,m:true}];
 for(const size of sizes){
  await navigate(size.w,size.h,size.m);
  await check(size.name+' Android button only',`document.querySelectorAll('[data-action="accessibility"]').length===1`);
  await nativeCheck(size.name+' video without pane never creates reader',async()=>Object.keys((await androidInfo()).reader).length===0);
  await check(size.name+' unopened pane has no JS/CSS load', `!document.querySelector('.accessibility-pane')&&!performance.getEntriesByType('resource').some(r=>r.name.endsWith('/js/accessibility.js')||r.name.endsWith('/css/accessibility.css'))`);
  await click('[data-action="accessibility"]');
  await wait(`document.querySelector('.a11y-speech').textContent.includes('Opens this decision support tool')`);
  await check(size.name+' speech only by default',`document.querySelector('.a11y-details').hidden && document.querySelector('.a11y-more').textContent==='More…' && document.querySelector('.a11y-speech').textContent==='ADHD. Attention-Deficit/Hyperactivity Disorder, Button, Opens this decision support tool'`);
  await check(size.name+' compact fits viewport and footer',`(()=>{const p=document.querySelector('.accessibility-pane').getBoundingClientRect(),f=document.querySelector('.device-frame').getBoundingClientRect(),b=document.querySelector('#bottom-tab-bar').getBoundingClientRect();return p.top>=f.bottom-1&&p.bottom<=b.top+1&&document.documentElement.scrollWidth<=innerWidth+1&&document.documentElement.scrollHeight<=innerHeight+1})()`);
  await check(size.name+' inspector controls and selectable text', `document.querySelector('[data-action="accessibility"]').getAttribute('aria-controls')===document.querySelector('.accessibility-pane').id&&document.querySelector('.a11y-more').getAttribute('aria-controls')===document.querySelector('.a11y-details').id&&getComputedStyle(document.querySelector('.a11y-details')).userSelect==='text'`);
  await evaluate(`window.__compact=document.querySelector('.device-frame').getBoundingClientRect().height;window.__resolution=[document.querySelector('canvas').width,document.querySelector('canvas').height]`);
  if(['desktop','phone'].includes(size.name))await shot(size.name+'-speech-compact');
  await click('.a11y-more');
  await check(size.name+' More expands BELOW and shrinks sim',`(()=>{const p=document.querySelector('.accessibility-pane').getBoundingClientRect(),f=document.querySelector('.device-frame').getBoundingClientRect();return p.top>=f.bottom-1&&f.height<window.__compact-2&&!document.querySelector('.a11y-details').hidden})()`);
  await check(size.name+' proportional refit keeps canvas resolution',`(()=>{const c=document.querySelector('canvas'),r=document.querySelector('.device-frame').getBoundingClientRect();return c.width===__resolution[0]&&c.height===__resolution[1]&&Math.abs(r.width-r.height*c.width/c.height)<=1.5})()`);
  await check(size.name+' all sample fields and no Center',`(()=>{const t=document.querySelector('.a11y-details').textContent;return t.includes('ROLE_BUTTON')&&t.includes('Screen bounds')&&t.includes('1006 × 368 px')&&t.includes('guidelines.childrensmercy.com.iguidelines')&&t.includes('ACTION_SHOW_ON_SCREEN')&&!t.includes('Center')})()`);
  await check(size.name+' expanded pane is bounded internal scroll',`(()=>{const p=document.querySelector('.accessibility-pane').getBoundingClientRect(),b=document.querySelector('#bottom-tab-bar').getBoundingClientRect(),body=document.querySelector('.a11y-body');return p.bottom<=b.top+1&&getComputedStyle(body).overflowY==='auto'&&document.documentElement.scrollWidth<=innerWidth+1})()`);
  if(['desktop','phone'].includes(size.name))await shot(size.name+'-speech-expanded');
  await click('.a11y-more');
  await check(size.name+' Less restores original sim size',`Math.abs(document.querySelector('.device-frame').getBoundingClientRect().height-__compact)<=2`);
  const before=await androidInfo();await click('.a11y-close');await delay(400);
  const after=await androidInfo();
  await nativeCheck(size.name+' close removes native child while video continues',async()=>after.reader.running===false&&after.requested===false&&(await status()).sessions.find(s=>s.id==='emulator-5554').frames>0);
  await delay(180);await nativeCheck(size.name+' closed parse/read counters unchanged',async()=>{const info=await androidInfo();return info.reader.bytes===after.reader.bytes&&info.reader.lines===after.reader.lines});
  await check(size.name+' close clears diagnostic/speech content',`document.querySelector('.accessibility-pane').hidden&&document.querySelector('.a11y-details').childElementCount===0`);
  await closeStreams();
 }
 // Pause, visibility, stale delivery and pointer mapping on a normal phone.
 await navigate(390,844,true);await click('[data-action="accessibility"]');await wait(`document.querySelector('.a11y-speech').textContent.includes('Opens this')`);
 await evaluate(`Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'))`);await delay(400);
 await nativeCheck('Hidden document stops native child',async()=>(await androidInfo()).reader.running===false);
 await evaluate(`Object.defineProperty(document,'hidden',{configurable:true,value:false});document.dispatchEvent(new Event('visibilitychange'))`);await wait(`document.querySelector('.a11y-speech').textContent.includes('Opens this') && document.querySelector('.a11y-status').textContent==='Live'`);
 await nativeCheck('Visibility return restores open pane only',async()=>(await androidInfo()).reader.running===true);
 const injection=`(()=>{const socket=window.__wire.sockets.find(s=>s.readyState===1);const gen=window.__wire.settings.at(-1).accessibility_subscription;socket.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({type:'accessibility_event',subscription:gen-1,node:{speech:'STALE SHOULD NOT SHOW'}})}));return !document.querySelector('.a11y-speech').textContent.includes('STALE')})()`;
 await check('Old subscription cannot show stale event',injection);
 await check('Device data is text, not executable HTML',`(()=>{const s=window.__wire.sockets.find(s=>s.readyState===1),gen=window.__wire.settings.at(-1).accessibility_subscription;s.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({type:'accessibility_event',subscription:gen,node:{speech:'<img src=x onerror="window.__xss=1">',label:'<script>alert(1)</script>',properties:{enabled:'true'},actions:['ACTION_CLICK']}})}));return document.querySelector('.a11y-speech').textContent.startsWith('<img')&&!document.querySelector('.accessibility-pane img')&&!window.__xss})()`);
 await click('.a11y-close');await click('[data-action="accessibility"]');await wait(`document.querySelector('.a11y-speech').textContent.includes('Opens this')`);await click('.a11y-more');
 const point=await evaluate(`(()=>{const r=document.querySelector('canvas').getBoundingClientRect();return {x:r.left+r.width*.5,y:r.top+r.height*.5}})()`);
 await cdp('Input.dispatchMouseEvent',{type:'mousePressed',x:point.x,y:point.y,button:'left',clickCount:1});await cdp('Input.dispatchMouseEvent',{type:'mouseReleased',x:point.x,y:point.y,button:'left',clickCount:1});
 await check('Shrunk sim preserves normalized pointer mapping',`window.__wire.inputs.some(m=>['touch_down','tap'].includes(m.type)&&Math.abs(m.x-.5)<.03&&Math.abs(m.y-.5)<.03)`);
 // A capture error must stop monitoring; its first recovered frame restores
 // an explicitly open pane, even though this socket's first frame is past.
 await evaluate("window.__wire.sockets.find(s=>s.readyState===1).send(JSON.stringify({type:'settings',stream_paused:true}))");await delay(150);
 await evaluate("window.__wire.sockets.find(s=>s.readyState===1).dispatchEvent(new MessageEvent('message',{data:JSON.stringify({type:'capture_error',message:'fixture window unavailable'})}))");await delay(300);
 await nativeCheck('Capture error tears down open inspector child',async()=>(await androidInfo()).reader.running===false);
 await evaluate("window.__wire.sockets.find(s=>s.readyState===1).send(JSON.stringify({type:'settings',stream_paused:false}))");
 await wait("document.querySelector('.a11y-status').textContent==='Live'&&document.querySelector('.panel-status').textContent==='Live'");
 await nativeCheck('Recovered video frame restores open inspector on same socket',async()=>(await androidInfo()).reader.running===true);
 await closeStreams();
 await navigate(1440,1000,false,'ios-fixture');await check('No iOS button or pane',`!document.querySelector('[data-action="accessibility"]')&&!document.querySelector('.accessibility-pane')`);await closeStreams();
 if(process.argv.includes('--real-adb')) {
 // Real ADB compatibility check: only after the actual frontend pane opens.
 await fetch(base+'/fixture/mode',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({real:true})});
 await navigate(390,844,true);await nativeCheck('Real ADB mode still has no reader while pane closed',async()=>Object.keys((await androidInfo()).reader).length===0);
 await click('[data-action="accessibility"]');await delay(1200);const actual=await androidInfo();
 await nativeCheck('Real ADB fresh cursor accepted and child listening',async()=>actual.reader.running===true&&actual.state==='listening');
 report.realADB={childWasRunning:actual.reader.running,linesRead:actual.reader.lines,bytesRead:actual.reader.bytes,actualSpeechObserved:await evaluate(`document.querySelector('.a11y-status').textContent==='Live'`),navigationInjected:false};
 await click('.a11y-close');await delay(400);const realOff=await androidInfo();
 await nativeCheck('Real ADB child terminated on pane close while video continues',async()=>realOff.reader.running===false);
 await delay(200);await nativeCheck('Real ADB counters frozen after close',async()=>{const r=(await androidInfo()).reader;return r.lines===realOff.reader.lines&&r.bytes===realOff.reader.bytes});
 await closeStreams();

 }
 await fetch(base+'/fixture/mode',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({real:false})});
 await navigate(1440,1000,false);
 // Event-only reconnect restores opt-in only while the real pane remains open.
 await click('[data-action="accessibility"]');await wait("document.querySelector('.a11y-status').textContent==='Live'");
 await evaluate("window.__wire.sockets.find(s=>s.readyState===1).close()");await delay(400);
 await nativeCheck('Socket disconnect tears down reader',async()=>(await status()).sessions.length===0);
 await wait("document.querySelector('.a11y-status').textContent==='Live' && document.querySelector('.panel-status').textContent==='Live'",6000);
 await nativeCheck('Open pane explicitly resubscribes after reconnect',async()=>(await androidInfo()).reader.running===true);
 await click('.a11y-close');await delay(300);
 await evaluate("window.__wire.sockets.find(s=>s.readyState===1).close()");
 await wait("document.querySelector('.panel-status').textContent==='Live'",6000);
 await nativeCheck('Closed pane reconnect never allocates reader',async()=>Object.keys((await androidInfo()).reader).length===0);
 const fps=[];
 async function sample(mode){const start=(await status()).sessions.find(s=>s.id==='emulator-5554').frames,at=performance.now();await delay(2500);const end=(await status()).sessions.find(s=>s.id==='emulator-5554').frames;fps.push({mode,fps:(end-start)*1000/(performance.now()-at)});}
 await sample('pane closed');await click('[data-action="accessibility"]');await wait("document.querySelector('.a11y-status').textContent==='Live'");await sample('pane open, event-driven idle reader');await click('.a11y-close');await sample('pane closed again');
 report.fixtureFPS=fps;
 await nativeCheck('Fixture JPEG/ACK path stays above 50 FPS',async()=>fps.every(s=>s.fps>50));
 await nativeCheck('Idle inspector does not reduce fixture FPS by 10%',async()=>fps[1].fps/fps[0].fps>.9);
 await click('[data-action="accessibility"]');await wait("document.querySelector('.a11y-status').textContent==='Live'");await click('.a11y-more');
 await evaluate("document.documentElement.dataset.theme='dark'");await shot('desktop-dark-expanded');
 await check('Dark theme inspector uses theme colors',"getComputedStyle(document.querySelector('.accessibility-pane')).backgroundColor!== 'rgb(255, 255, 255)'");
 await evaluate("window.__wire.sockets.find(s=>s.readyState===1).send(JSON.stringify({type:'settings',stream_paused:true}))");await delay(150);
 await evaluate("window.__wire.sockets.find(s=>s.readyState===1).dispatchEvent(new MessageEvent('message',{data:JSON.stringify({type:'rotated',landscape:true})}))");await delay(200);
 await check('Paused landscape presentation refits below-pane without distortion',"(()=>{const c=document.querySelector('canvas'),f=document.querySelector('.device-frame').getBoundingClientRect(),p=document.querySelector('.accessibility-pane').getBoundingClientRect();return c.width>c.height&&f.bottom<=p.top+1&&Math.abs(f.width-f.height*c.width/c.height)<=1.5})()");
 await closeStreams();
 // Desktop multi-simulator panel ownership remains independent.
 await navigate(1440,1000,false);
 await evaluate("document.querySelector('.device-item[data-udid=\"ios-fixture\"]')?.click()");
 await wait("document.querySelectorAll('.sim-panel').length===2");
 await check('Multi-device accessibility toggle belongs only to Android',"document.querySelectorAll('[data-action=\"accessibility\"]').length===1&&document.querySelectorAll('.accessibility-pane').length===0");
 await click('[data-action="accessibility"]');await wait("document.querySelector('.a11y-status').textContent==='Live'");
 await check('Android pane does not resize or cover iOS neighbor',"(()=>{const a=document.querySelector('.accessibility-pane').getBoundingClientRect(),i=document.querySelector('.sim-panel[data-udid=\"ios-fixture\"] .device-frame').getBoundingClientRect();return a.right<=i.left||a.left>=i.right})()");
 await closeStreams();
 report.browserExceptions=exceptions.length;report.passed=report.checks.every(c=>c.passed)&&exceptions.length===0;
 if(!report.passed)throw Error('Browser exception or assertion failure');
 fs.writeFileSync(path.join(root,'browser-review.json'),JSON.stringify(report,null,2)+'\n');
 console.log(`${report.checks.length} remote browser/native-demand checks passed. Real ADB ${JSON.stringify(report.realADB)}. Screenshots ${report.screenshots.join(', ')}`);
} catch(error){report.error=String(error);fs.writeFileSync(path.join(root,'browser-review-failed.json'),JSON.stringify(report,null,2)+'\n');throw error}
finally{
 try { if(ws?.readyState===1)await cdp('Browser.close') } catch{}
 if(ws)ws.close();for(const p of pending.values())clearTimeout(p.timer);
 const ended=new Promise(r=>child.once('exit',r));
 try{process.kill(-child.pid,'SIGTERM')}catch{}
 await Promise.race([ended,delay(1500)]);
 try{process.kill(-child.pid,'SIGKILL')}catch{}
 await delay(300);
 fs.rmSync(profile,{recursive:true,force:true,maxRetries:20,retryDelay:100});
}
