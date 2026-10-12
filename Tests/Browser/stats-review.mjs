import fs from 'node:fs';import path from 'node:path';import {spawn,execFileSync} from 'node:child_process';
const root=process.argv[2];const source=fs.realpathSync(process.cwd());if(!root||process.platform!=='darwin'||typeof WebSocket==='undefined')throw Error('Run on macOS with Node22 and a private output directory');
if(!fs.existsSync(source+'/Sources/Accessibility.swift'))throw Error('Run from the project root');
const report={host:execFileSync('/bin/hostname',{encoding:'utf8'}).trim(),canonical:source,fixtures:true,liveAppRestarted:false,checks:[],screenshots:[]};
const base='https://127.0.0.1:45151';const delay=ms=>new Promise(r=>setTimeout(r,ms));
const status=async()=>await(await fetch(base+'/fixture/status')).json();
const profile=path.join(root,'chrome-profile');
const publicKey=execFileSync('/usr/bin/openssl',['x509','-in',path.join(root,'tls/server.pem'),'-pubkey','-noout']);
const der=execFileSync('/usr/bin/openssl',['pkey','-pubin','-outform','DER'],{input:publicKey});
const pin=execFileSync('/usr/bin/openssl',['dgst','-sha256','-binary'],{input:der}).toString('base64');
report.videoCodec='h264';report.delayedNativeSessionSetup=true;report.tls={fixtureLeafSPKIPin:pin,trustStoreModified:false};
const child=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new',`--ignore-certificate-errors-spki-list=${pin}`,'--disable-gpu','--force-device-scale-factor=1','--remote-debugging-address=127.0.0.1','--remote-debugging-port=0',`--user-data-dir=${profile}`,'--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-sync','--disable-extensions','about:blank'],{stdio:['ignore','ignore','pipe'],detached:true});
let chromeErr='';child.stderr.on('data',b=>chromeErr=(chromeErr+b.toString()).slice(-10000));
let ws;let seq=0;const pending=new Map();const exceptions=[];
function cdp(method,params={}){return new Promise((resolve,reject)=>{const id=++seq;const timer=setTimeout(()=>{pending.delete(id);reject(Error('CDP timeout '+method))},12000);pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params}))});}
async function evaluate(expression){const r=await cdp('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value;}
async function wait(expression,ms=4000){const end=Date.now()+ms;while(Date.now()<end){if(await evaluate(expression))return true;await delay(40)}throw Error('UI timeout: '+expression)}
async function check(name,expression){const value=await evaluate(expression);report.checks.push({name,passed:value===true});if(value!==true)throw Error('FAIL '+name+': '+JSON.stringify(value));}
async function nativeCheck(name,condition){const value=await condition();report.checks.push({name,passed:value===true});if(value!==true)throw Error('FAIL '+name);}
async function click(selector){await evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);await delay(80)}
async function pointerClick(selector){
 const p=await evaluate("(()=>{const e=document.querySelector("+JSON.stringify(selector)+"),r=e.getBoundingClientRect(),x=r.left+r.width/2,y=r.top+r.height/2;return {x,y,hit:x>=0&&x<innerWidth&&y>=0&&y<innerHeight&&e.contains(document.elementFromPoint(x,y))&&!e.disabled}})()");
 if(!p.hit)throw Error('Button is not interactable: '+selector);
 await cdp('Input.dispatchMouseEvent',{type:'mousePressed',x:p.x,y:p.y,button:'left',buttons:1,clickCount:1});
 await cdp('Input.dispatchMouseEvent',{type:'mouseReleased',x:p.x,y:p.y,button:'left',clickCount:1});await delay(100);
}
async function showSidebar(){if(await evaluate("document.querySelector('#sidebar').inert"))await pointerClick('#mobile-menu-btn');await delay(350)}
async function sidebarTerminal(){await showSidebar();await evaluate("document.querySelector('#btn-terminal').scrollIntoView({block:'nearest'})");await pointerClick('#btn-terminal')}
async function shot(name){await evaluate('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))');await delay(400);const result=await cdp('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});fs.writeFileSync(path.join(root,name+'.png'),Buffer.from(result.data,'base64'));report.screenshots.push(name+'.png');}
async function closeStreams(){await evaluate(`document.querySelectorAll('[data-action="close"]').forEach(b=>b.click())`);await delay(350)}

// Test-only callback access via an isolated fixture response; canonical stream.js
// and its decoding/scheduling behavior remain unchanged. No production URL is used.
async function navigateStats(width,height,touch=false){
 await cdp('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:touch});
 await cdp('Emulation.setTouchEmulationEnabled',{enabled:touch});
 await cdp('Page.navigate',{url:base+'/?view=emulator-5554'});
 await wait("!!document.querySelector('.sim-panel canvas')&&document.querySelector('.panel-status').textContent==='Live'");
}
async function tap(selector){
 const p=await evaluate("(()=>{const e=document.querySelector("+JSON.stringify(selector)+"),r=e.getBoundingClientRect(),x=r.left+r.width/2,y=r.top+r.height/2;return {x,y,hit:e.contains(document.elementFromPoint(x,y))}})()");
 if(!p.hit)throw Error('Not touch accessible '+selector);
 await cdp('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x:p.x,y:p.y,id:1}]});
 await cdp('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});await delay(120);
}
async function key(key,code=key,vk){
 await cdp('Input.dispatchKeyEvent',{type:'keyDown',key,code,...(vk?{windowsVirtualKeyCode:vk}:{}),...(key==='Enter'?{text:'\r'}:key===' '?{text:' '}:{})});
 await cdp('Input.dispatchKeyEvent',{type:'keyUp',key,code,...(vk?{windowsVirtualKeyCode:vk}:{})});await delay(80);
}
async function sample(id,patch={}){
 const value={fps:40,bps:102400,avgFrame:2560,dropped:100,serverFps:60,serverQuality:20,codec:'h264',...patch};
 await evaluate("(()=>{window.__statsTest.manual=true;window.__statsTest.previousAt=window.__statsTest.lastAt;window.__statsTest.lastAt=performance.now();window.__statsTest.callbacks.get("+JSON.stringify(id)+").stats("+JSON.stringify(value)+")})()");
}
const popoverVisible="!!document.querySelector('#stream-stats-popover')";
const closed="!document.querySelector('.stats-popover')&&[...document.querySelectorAll('.stream-stats')].every(e=>e.getAttribute('aria-expanded')==='false'&&!e.hasAttribute('aria-controls'))";
const bounded="(()=>{const e=document.querySelector('.stats-popover'),r=e.getBoundingClientRect(),v=visualViewport;return r.left>=v.offsetLeft+11&&r.top>=v.offsetTop+11&&r.right<=v.offsetLeft+v.width-11&&r.bottom<=v.offsetTop+v.height-11&&e.scrollWidth<=e.clientWidth+1&&document.documentElement.scrollWidth<=innerWidth+1})()";
async function statsListeners(){let count=0;for(const expression of ['document','window','visualViewport']){const value=await cdp('Runtime.evaluate',{expression});const listeners=await cdp('DOMDebugger.getEventListeners',{objectId:value.result.objectId});count+=listeners.listeners.filter(l=>/dismissStatsPopover|statsPopoverKeydown|positionStatsPopover|statsPopoverVisibility/.test(l.originalHandler?.description??l.handler?.description??'')).length}return count}

try{
 for(let i=0;!fs.existsSync(path.join(profile,'DevToolsActivePort'));i++){if(i>120||child.exitCode!==null)throw Error('Chrome startup '+chromeErr);await delay(100)}
 const port=fs.readFileSync(path.join(profile,'DevToolsActivePort'),'utf8').split('\n')[0];const tabs=await(await fetch(`http://127.0.0.1:${port}/json/list`)).json();
 ws=new WebSocket(tabs.find(t=>t.type==='page').webSocketDebuggerUrl);await new Promise((res,rej)=>{ws.addEventListener('open',res,{once:true});ws.addEventListener('error',rej,{once:true})});
 ws.addEventListener('message',e=>{const m=JSON.parse(e.data);if(m.id&&pending.has(m.id)){const p=pending.get(m.id);clearTimeout(p.timer);pending.delete(m.id);m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result)}else if(m.method==='Runtime.exceptionThrown')exceptions.push(m.params)});
 await cdp('Page.enable');await cdp('Runtime.enable');await cdp('Network.enable');
 await cdp('Network.setCookie',{name:'fixture',value:'paired',url:base,httpOnly:true,sameSite:'Strict',secure:true});
 await cdp('Page.addScriptToEvaluateOnNewDocument',{source:`window.__video={created:0,closed:0,outputs:0,frameCloses:0,live:0,maxQueue:0,ackBeforeClose:false,packets:0,deltas:0};const RealDecoder=VideoDecoder;window.VideoDecoder=class extends RealDecoder{constructor(init){super({...init,output:f=>{window.__video.outputs++;window.__video.live++;init.output(f)}});window.__video.created++}decode(chunk){super.decode(chunk);window.__video.maxQueue=Math.max(window.__video.maxQueue,this.decodeQueueSize)}close(){window.__video.closed++;super.close()}};const closeFrame=VideoFrame.prototype.close;VideoFrame.prototype.close=function(){window.__video.live--;window.__video.frameCloses++;return closeFrame.call(this)};window.__wire={settings:[],inputs:[],acks:0,feedbacks:0,sockets:[]};window.__feedbackDelay=0;const Real=WebSocket;window.WebSocket=class extends Real{constructor(...args){super(...args);window.__wire.sockets.push(this);this.addEventListener('message',e=>{if(e.data instanceof ArrayBuffer&&e.data.byteLength>=24){const v=new DataView(e.data);if(v.getUint32(0)===0x53575631){window.__video.packets++;if(v.getUint8(4)===0)window.__video.deltas++}}})}send(data){try{const m=JSON.parse(data);if(m.type==='settings'){window.__wire.settings.push(m);if(window.__wire.settings.length>128)window.__wire.settings.shift()}else if(m.type==='frame_ack'){window.__wire.acks++}else if(m.type==='video_feedback'){window.__wire.feedbacks++;if(window.__feedbackDelay){setTimeout(()=>{if(this.readyState===1)Real.prototype.send.call(this,data)},window.__feedbackDelay);return}}else if(!['video_ready','video_keyframe'].includes(m.type)){window.__wire.inputs.push(m);if(window.__wire.inputs.length>128)window.__wire.inputs.shift()}}catch{}return super.send(data)}};`});
 await fetch(base+'/fixture/mode',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({real:false})});
 report.scope='Synthetic H.264 fixture + test-only callback injection; not Safari/iPad performance certification';
 const streamSource=fs.readFileSync(source+'/Resources/Web/js/stream.js','utf8');
 if(streamSource.split('export class SimStream {').length!==2)throw Error('Stream export changed');
 const injected=streamSource.replace('export class SimStream {','class FixtureOriginalSimStream {')+`
window.__statsTest={manual:false,callbacks:new Map(),real:new Map()};
export class SimStream extends FixtureOriginalSimStream {
 constructor(id,canvas,options){
  super(id,canvas,{...options,onStats:stats=>{window.__statsTest.real.set(id,stats);if(!window.__statsTest.manual)options.onStats(stats)}});
  window.__statsTest.callbacks.set(id,{stats:options.onStats,status:options.onStatus,firstFrame:options.onFirstFrame});
 }
}`;
 ws.addEventListener('message',async event=>{const m=JSON.parse(event.data);if(m.method!=='Fetch.requestPaused')return;try{await cdp('Fetch.fulfillRequest',{requestId:m.params.requestId,responseCode:200,responseHeaders:[{name:'Content-Type',value:'text/javascript'}],body:Buffer.from(injected).toString('base64')})}catch(error){exceptions.push({fixtureHook:String(error)})}});
 await cdp('Fetch.enable',{patterns:[{urlPattern:base+'/js/stream.js'}]});
 const sizes=[{name:'desktop',w:1440,h:1000,t:false},{name:'ipad',w:1024,h:768,t:true},{name:'phone',w:390,h:844,t:true},{name:'small-phone',w:320,h:568,t:true},{name:'short-phone',w:375,h:500,t:true},{name:'landscape',w:844,h:390,t:true},{name:'keyboard-height',w:375,h:280,t:true}];
 for(const size of sizes){
  await navigateStats(size.w,size.h,size.t);
  await check(size.name+' secure real H.264 output remains active',"isSecureContext&&window.__video.outputs>0&&window.__wire.sockets[0].url.startsWith('wss:')&&window.__wire.acks===0");
  await check(size.name+' stats is named native button with dialog semantics',"(()=>{const b=document.querySelector('.stream-stats');return b.tagName==='BUTTON'&&b.type==='button'&&b.getAttribute('aria-haspopup')==='dialog'&&b.getAttribute('aria-label')==='Pixel 6 API 36 stream debug info'&&b.getAttribute('aria-expanded')==='false'&&b.getBoundingClientRect().height>=32})()");
  await check(size.name+' popup starts lazy/absent',closed);
  await nativeCheck(size.name+' unopened debugger creates no reader',async()=>(await status()).sessions.every(s=>Object.keys(s.accessibility.reader).length===0));
  await evaluate("window.__frameBefore=document.querySelector('.device-frame').getBoundingClientRect().toJSON();window.__inputsBefore=__wire.inputs.length;window.__settingsBefore=__wire.settings.length;window.__socketsBefore=__wire.sockets.length");
  if(size.t)await tap('.stream-stats');else await pointerClick('.stream-stats');
  await check(size.name+' touch/click opens one non-modal named dialog',popoverVisible+"&&document.querySelectorAll('.stats-popover').length===1&&document.querySelector('.stats-popover').getAttribute('role')==='dialog'&&document.querySelector('.stats-popover').getAttribute('aria-labelledby')==='stream-stats-heading'&&document.querySelector('.stream-stats').getAttribute('aria-expanded')==='true'");
  await check(size.name+' popup is viewport bounded and not clipped by panel',bounded+"&&document.querySelector('.stats-popover').parentNode===document.body");
  await check(size.name+' debug popup keeps its trigger uncovered',"(()=>{const p=document.querySelector('.stats-popover').getBoundingClientRect(),b=document.querySelector('.stream-stats').getBoundingClientRect();return p.bottom<=b.top-7||p.top>=b.bottom+7})()");
  await check(size.name+' opening debugger leaves device geometry/input/settings unchanged',"(()=>{const r=document.querySelector('.device-frame').getBoundingClientRect();return ['x','y','width','height'].every(k=>Math.abs(r[k]-__frameBefore[k])<1)&&__wire.inputs.length===__inputsBefore&&__wire.settings.length===__settingsBefore&&__wire.sockets.length===__socketsBefore&&!document.querySelector('.accessibility-pane')})()");
  await check(size.name+' close receives accessible focus',"document.activeElement.classList.contains('stats-popover-close')&&!!document.querySelector('#stream-stats-note')");
  // No native server_stats message in this fixture: never substitute the slider
  // for an unknown server measurement in the debug dialog.
  await check(size.name+' unknown server target remains unknown',"document.querySelector('[data-stat=target]').textContent==='—'");
  await sample('emulator-5554');
  await check(size.name+' separate rendered40/requested60/server60 values',"document.querySelector('[data-stat=rendered]').textContent==='40 fps'&&document.querySelector('[data-stat=requested]').textContent==='60 fps'&&document.querySelector('[data-stat=target]').textContent==='60 fps'");
  await check(size.name+' existing bandwidth/quality/drops/bytes shown accurately',"document.querySelector('[data-stat=bandwidth]').textContent==='100 KB/s'&&document.querySelector('[data-stat=quality]').textContent==='20'&&document.querySelector('[data-stat=dropped]').textContent==='100'&&document.querySelector('[data-stat=average]').textContent==='2.5 KB'");
  await evaluate("window.__originalPopover=document.querySelector('.stats-popover');window.__originalValue=document.querySelector('[data-stat=dropped]')");
  await delay(500);await sample('emulator-5554',{fps:41,dropped:110,bps:1048576,serverQuality:18});
  await check(size.name+' live update reuses popup and values without re-opening',"document.querySelector('.stats-popover')===__originalPopover&&document.querySelector('[data-stat=dropped]')===__originalValue&&__originalValue.textContent==='110'&&document.querySelector('[data-stat=rendered]').textContent==='41 fps'&&document.querySelector('[data-stat=bandwidth]').textContent==='1.0 MB/s'");
  await check(size.name+' dropped rate uses actual elapsed monotonic time',"Math.abs(parseFloat(document.querySelector('[data-stat=dropRate]').textContent)-10000/(__statsTest.lastAt-__statsTest.previousAt))<.2");
  await delay(60);await sample('emulator-5554',{dropped:110});
  await check(size.name+' zero drops reports zero rate',"document.querySelector('[data-stat=dropRate]').textContent==='0.0 /s'");
  await sample('emulator-5554',{dropped:1,serverFps:null,serverQuality:null});
  await check(size.name+' count reset/unknown values never show negative rate or fabricated target',"document.querySelector('[data-stat=dropRate]').textContent==='—'&&document.querySelector('[data-stat=target]').textContent==='—'&&document.querySelector('[data-stat=quality]').textContent==='—'");
  await sample('emulator-5554',{dropped:150});
  await evaluate("__statsTest.callbacks.get('emulator-5554').status('reconnecting')");
  await check(size.name+' connection state updates while popup is open',"document.querySelector('[data-stat=status]').textContent==='Reconnecting'");
  await evaluate("__statsTest.callbacks.get('emulator-5554').status('streaming');__statsTest.callbacks.get('emulator-5554').firstFrame()");
  await check(size.name+' status recovery stays live',"document.querySelector('[data-stat=status]').textContent==='Live'");
  await evaluate("document.querySelector('.stats-popover-device').dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));document.querySelector('.stats-popover').scrollTop=20");
  await check(size.name+' selecting/scrolling popup content does not dismiss',popoverVisible);
  if(['desktop','ipad','phone','small-phone','landscape'].includes(size.name)){
   await click('.stats-popover-close');await click('[data-theme-choice=light]');await pointerClick('.stream-stats');await sample('emulator-5554',{dropped:150});await delay(750);await sample('emulator-5554',{dropped:165});
   await check(size.name+' actual light theme applies',"document.documentElement.dataset.theme==='light'&&getComputedStyle(document.querySelector('.stats-popover')).backgroundColor==='rgb(255, 255, 255)'");
   await shot(size.name+'-light-stream-debug');
   await click('.stats-popover-close');await click('[data-theme-choice=dark]');await pointerClick('.stream-stats');
   await check(size.name+' actual dark theme applies',"document.documentElement.dataset.theme==='dark'&&getComputedStyle(document.querySelector('.stats-popover')).backgroundColor==='rgb(32, 36, 31)'");
   if(['ipad','phone'].includes(size.name))await shot(size.name+'-dark-stream-debug');
   await click('.stats-popover-close');await click('[data-theme-choice=light]');await pointerClick('.stream-stats');
  }
  await key('Escape','Escape',27);
  await check(size.name+' Escape closes and restores focus',closed+"&&document.activeElement.classList.contains('stream-stats')");
  await key('Enter','Enter',13);await check(size.name+' keyboard Enter opens debugger',popoverVisible);
  await pointerClick('.stats-popover-close');await check(size.name+' close button dismisses with focus restored',closed+"&&document.activeElement.classList.contains('stream-stats')");
  await key(' ','Space',32);await check(size.name+' keyboard Space opens debugger',popoverVisible);
  if(size.t)await tap('.stream-stats');else await pointerClick('.stream-stats');
  await check(size.name+' tapping same counter toggles closed',closed);
  await pointerClick('.stream-stats');await pointerClick('.panel-status');
  await check(size.name+' outside click closes without stream inputs',closed+"&&__wire.inputs.length===__inputsBefore");
  await pointerClick('.stream-stats');await evaluate("document.querySelector('[data-action=home]').focus()");
  await check(size.name+' non-modal focus can leave and dismiss without trapping',closed);
  await nativeCheck(size.name+' debugger never creates real/fixture accessibility reader',async()=>(await status()).real_adb===false&&(await status()).sessions.every(s=>Object.keys(s.accessibility.reader).length===0));
  await nativeCheck(size.name+' no debugger-generated simulator input',async()=>(await status()).sessions.every(s=>s.inputs===0&&!s.paused));
  await nativeCheck(size.name+' closed debugger removes all global listeners',async()=>await statsListeners()===0);
  await closeStreams();
 }
 await navigateStats(1440,1000,false);
 await wait("__statsTest.real.has('emulator-5554')");
 await pointerClick('.stream-stats');
 await check('unmodified existing stats callback drives live debugger',"document.querySelector('[data-stat=rendered]').textContent===__statsTest.real.get('emulator-5554').fps+' fps'&&document.querySelector('[data-stat=dropped]').textContent===String(__statsTest.real.get('emulator-5554').dropped)");
 await evaluate("[...document.querySelectorAll('.device-item')].find(e=>e.textContent.includes('iPhone 11')).click()");
 await wait("document.querySelectorAll('.sim-panel').length===2&&__statsTest.callbacks.has('ios-fixture')&&[...document.querySelectorAll('.panel-status')].every(e=>e.textContent==='Live')");
 await sample('emulator-5554',{dropped:300});await sample('ios-fixture',{fps:55,dropped:3});
 await click('.stats-popover-close');await pointerClick('.sim-panel[data-udid="emulator-5554"] .stream-stats');
 await check('multi-device Android debugger only has Android values',"document.querySelector('.stats-popover-device').textContent==='Pixel 6 API 36'&&document.querySelector('[data-stat=dropped]').textContent==='300'");
 await pointerClick('.sim-panel[data-udid="ios-fixture"] .stream-stats');
 await check('switching counter replaces singleton and preserves per-device stats',"document.querySelectorAll('.stats-popover').length===1&&document.querySelector('.stats-popover-device').textContent==='iPhone 11'&&document.querySelector('[data-stat=dropped]').textContent==='3'&&document.querySelector('[data-stat=rendered]').textContent==='55 fps'&&document.querySelector('.sim-panel[data-udid="+JSON.stringify('emulator-5554')+"] .stream-stats').getAttribute('aria-expanded')==='false'");
 await sample('emulator-5554',{fps:10,dropped:500});
 await check('other device callback cannot overwrite open debugger',"document.querySelector('[data-stat=rendered]').textContent==='55 fps'&&document.querySelector('[data-stat=dropped]').textContent==='3'");
 await evaluate("document.querySelector('.sim-panel[data-udid=ios-fixture] [data-action=close]').click()");
 await check('panel removal cleans debugger and references',closed);
 for(let i=0;i<12;i++){await evaluate("document.querySelector('.stream-stats').click();document.querySelector('.stats-popover-close').click()")}
 await nativeCheck('repeated opens/closes leak no document/window/viewport listeners',async()=>await statsListeners()===0);
 await check('repeated opens/closes leak no DOM',closed);
 await pointerClick('.stream-stats');await cdp('Emulation.setDeviceMetricsOverride',{width:375,height:500,deviceScaleFactor:1,mobile:true});await delay(150);
 await check('already-open debugger repositions on viewport resize',bounded);
 await pointerClick('[data-action=home]');
 await nativeCheck('existing Home control still routes exactly one input after debug closes',async()=>{const s=(await status()).sessions.find(s=>s.id==='emulator-5554');return s.inputs===1&&s.last_inputs.at(-1).type==='home'});
 await check('controls remain separate from debug trigger',closed);
 await pointerClick('.stream-stats');await evaluate("window.dispatchEvent(new PageTransitionEvent('pagehide'))");
 await check('pagehide removes debugger before stream teardown',closed);
 await nativeCheck('pagehide releases debugger global listeners',async()=>await statsListeners()===0);
 await delay(250);
 await nativeCheck('pagehide terminates only fixture streams, never real devices',async()=>(await status()).sessions.length===0&&(await status()).real_adb===false);
 report.browserExceptions=exceptions.length;report.passed=report.checks.every(c=>c.passed)&&exceptions.length===0;
 if(!report.passed)throw Error('Browser exception or assertion failure');
 fs.writeFileSync(path.join(root,'browser-review-stats.json'),JSON.stringify(report,null,2)+'\n');
 console.log(report.checks.length+' canonical-Mac isolated stream-debug browser checks passed; zero browser exceptions. '+report.screenshots.join(', '));
} catch(error){report.error=String(error);fs.writeFileSync(path.join(root,'browser-review-stats-failed.json'),JSON.stringify(report,null,2)+'\n');throw error}
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
