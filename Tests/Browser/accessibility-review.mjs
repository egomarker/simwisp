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

const sizeKey='simwispAccessibilitySize.v1.emulator-5554';
async function geometry(){return evaluate("(()=>{const p=document.querySelector('.accessibility-pane'),b=document.querySelector('.a11y-body'),e=document.querySelector('.a11y-eyebrow'),f=document.querySelector('.device-frame'),c=document.querySelector('canvas'),bs=getComputedStyle(b);return {pane:p.getBoundingClientRect().height,frame:f.getBoundingClientRect().height,frameW:f.getBoundingClientRect().width,lines:(b.clientHeight-parseFloat(bs.paddingTop)-parseFloat(bs.paddingBottom)-e.getBoundingClientRect().height-parseFloat(getComputedStyle(e).marginBottom))/parseFloat(getComputedStyle(document.querySelector('.a11y-speech')).lineHeight),cw:c.width,ch:c.height,inputs:window.__wire.inputs.length,subscription:window.__wire.settings.at(-1).accessibility_subscription}})()")}
async function speech(value,source='speak'){
 const node={speech:value,speech_source:source,observed_at:new Date().toISOString(),label:'ADHD. Attention-Deficit/Hyperactivity Disorder',role:'ROLE_BUTTON',tooltip:'Opens this decision support tool',package:'guidelines.childrensmercy.com.iguidelines',class:'android.widget.Button',bounds:{left:37,top:451,right:1043,bottom:819,width:1006,height:368},properties:{enabled:'true'},actions:['ACTION_SHOW_ON_SCREEN']};
 await evaluate("(()=>{const socket=window.__wire.sockets.find(s=>s.readyState===1),subscription=window.__wire.settings.at(-1).accessibility_subscription;socket.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({type:'accessibility_event',subscription,node:"+JSON.stringify(node)+"})}))})()");await delay(50);
}
async function resizeKey(key,shift=false){await cdp('Input.dispatchKeyEvent',{type:'keyDown',key,code:key,modifiers:shift?8:0});await cdp('Input.dispatchKeyEvent',{type:'keyUp',key,code:key,modifiers:shift?8:0});await delay(80)}
async function gripPoint(){return evaluate("(()=>{const r=document.querySelector('.a11y-resize-handle').getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+9}})()")}
async function mouseResize(delta){const p=await gripPoint();await cdp('Input.dispatchMouseEvent',{type:'mousePressed',x:p.x,y:p.y,button:'left',buttons:1,clickCount:1});await cdp('Input.dispatchMouseEvent',{type:'mouseMoved',x:p.x,y:p.y-delta,button:'left',buttons:1});await cdp('Input.dispatchMouseEvent',{type:'mouseReleased',x:p.x,y:p.y-delta,button:'left',clickCount:1});await delay(100)}
async function touchResize(delta,cancel=false){const p=await gripPoint(),point={x:p.x,y:p.y,id:11,radiusX:4,radiusY:4};await cdp('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[point]});await cdp('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{...point,y:p.y-delta}]});await cdp('Input.dispatchTouchEvent',{type:cancel?'touchCancel':'touchEnd',touchPoints:[]});await delay(100)}

const androidInfo=async()=> (await status()).sessions.find(s=>s.id==='emulator-5554')?.accessibility;
async function appearanceSpacing(){return evaluate("(()=>{const footer=document.querySelector('.sidebar-footer'),picker=document.querySelector('.theme-picker'),sidebar=document.querySelector('#sidebar'),prior=footer.scrollTop,probe=document.createElement('div');probe.style.cssText='position:fixed;visibility:hidden;pointer-events:none;padding-bottom:env(safe-area-inset-bottom,0px)';document.body.append(probe);const safe=parseFloat(getComputedStyle(probe).paddingBottom)||0;probe.remove();footer.scrollTop=footer.scrollHeight;const f=footer.getBoundingClientRect(),p=picker.getBoundingClientRect(),s=sidebar.getBoundingClientRect(),c=getComputedStyle(footer);const m={left:parseFloat(c.paddingLeft),bottom:parseFloat(c.paddingBottom)-safe,measuredLeft:p.left-s.left-parseFloat(getComputedStyle(sidebar).paddingLeft),measuredBottom:f.bottom-p.bottom-safe,pickerVisible:p.top>=f.top&&p.bottom<=f.bottom-safe+1};footer.scrollTop=prior;return m})()")}
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

  await check(size.name+' logo tagline removed',"!document.querySelector('.brand-caption')&&!document.querySelector('.sidebar-logo').textContent.includes('A little closer to your app')");
  await check(size.name+' no bottom bar or Controlling label',"!document.querySelector('#focus-summary')&&!document.querySelector('#bottom-tab-bar')&&!document.querySelector('#tab-terminal')");
  await check(size.name+' sole styled terminal button is below Refresh in sidebar',"document.querySelectorAll('#btn-terminal').length===1&&document.querySelector('#sidebar #btn-terminal').classList.contains('sidebar-btn')&&document.querySelector('#btn-terminal').previousElementSibling.id==='btn-refresh'&&document.querySelector('#btn-terminal').textContent.trim()==='Terminal'&&!!document.querySelector('#btn-terminal svg[aria-hidden=true]')");
  await check(size.name+' Terminal shares Refresh button style and width',"(()=>{const a=document.querySelector('#btn-terminal'),b=document.querySelector('#btn-refresh'),x=getComputedStyle(a),y=getComputedStyle(b);return ['display','padding','borderRadius','fontSize','fontFamily','fontWeight','minHeight'].every(p=>x[p]===y[p])&&Math.abs(a.getBoundingClientRect().width-b.getBoundingClientRect().width)<1})()");
  await check(size.name+' sidebar respects disabled terminal capability',"document.querySelector('#btn-terminal').disabled&&document.querySelector('#btn-terminal').getAttribute('aria-controls')==='terminal-panel'&&document.querySelector('#btn-terminal').getAttribute('aria-expanded')==='false'&&!performance.getEntriesByType('resource').some(r=>r.name.endsWith('/js/terminal.js'))");
  await check(size.name+' crisp device-wisp logo, not steam',"(()=>{const s=document.querySelector('.brand-mark svg'),b=s.getBBox();return s.getAttribute('viewBox')==='0 0 24 24'&&s.querySelectorAll('path').length===2&&b.x>=0&&b.y>=0&&b.x+b.width<=24&&b.y+b.height<=24&&!s.innerHTML.includes('M6 15c-5-4')&&document.querySelector('.brand-mark').getAttribute('aria-hidden')==='true'})()");
  await check(size.name+' Data saver unchanged without extra separator',"document.querySelector('#ds-btn').textContent.trim()==='Data saver'&&document.querySelector('#ds-btn').closest('.sidebar-settings').nextElementSibling.id==='btn-refresh'&&!document.querySelector('.sidebar-separator')");
  await nativeCheck(size.name+' Appearance bottom and left margins match',async()=>{const m=await appearanceSpacing();return Math.abs(m.left-m.bottom)<.1&&Math.abs(m.measuredLeft-m.measuredBottom)<1.1&&m.pickerVisible});
  await check(size.name+' focused keyboard placeholder preserved',"document.querySelector('#kbd-input').placeholder==='Send text to Pixel 6 API 36…'");
  await check(size.name+' Android has no iOS Shake control',"!document.querySelector('[data-action=shake]')");
  await check(size.name+' Android controls have the requested order',"[...document.querySelectorAll('.panel-actions button')].map(b=>b.dataset.action).join(',')==='rotate,home,back,app-switcher,menu,appear,two-finger,accessibility,kbd,close'");
  await check(size.name+' Android controls fit and remain pointer accessible',"(()=>{const p=document.querySelector('.sim-panel').getBoundingClientRect(),a=document.querySelector('.panel-actions').getBoundingClientRect();return a.left>=p.left&&a.right<=p.right&&a.bottom<=innerHeight&&[...document.querySelectorAll('.pill-btn')].every(b=>{const r=b.getBoundingClientRect();return r.width>=32&&r.height>=32&&r.left>=a.left&&r.right<=a.right&&b.contains(document.elementFromPoint(r.left+r.width/2,r.top+r.height/2))})&&document.documentElement.scrollWidth<=innerWidth+1})()");
  await nativeCheck(size.name+' Android navigation is never sent on startup',async()=>(await status()).sessions.find(s=>s.id==='emulator-5554').inputs===0);
  for(const [action,type,title] of [['back','back','Back'],['app-switcher','app_switcher','App switcher'],['menu','menu','Menu']]){
   const selector='[data-action='+action+']',before=(await status()).sessions.find(s=>s.id==='emulator-5554');
   await check(size.name+' '+action+' icon is bounded, decorative and named',"(()=>{const b=document.querySelector("+JSON.stringify(selector)+"),s=b.querySelector('svg'),r=s.getBBox();return b.title==="+JSON.stringify(title)+"&&b.getAttribute('aria-label')===b.title&&s.getAttribute('aria-hidden')==='true'&&s.getAttribute('viewBox')==='0 0 20 20'&&r.x>=.8&&r.y>=.8&&r.x+r.width<=19.2&&r.y+r.height<=19.2})()");
   await pointerClick(selector+' svg');
   await nativeCheck(size.name+' nested '+action+' icon pointer sends exactly one message on Android socket',async()=>{const s=(await status()).sessions.find(s=>s.id==='emulator-5554');return s.inputs===before.inputs+1&&JSON.stringify(s.last_inputs.at(-1))===JSON.stringify({type})});
   await check(size.name+' '+action+' does not open keyboard or inspector',"document.querySelector('.sim-panel').classList.contains('focused')&&!document.querySelector('#kbd-bar').classList.contains('visible')&&!document.querySelector('.accessibility-pane')&&!performance.getEntriesByType('resource').some(r=>r.name.endsWith('/js/accessibility.js'))");
   await nativeCheck(size.name+' '+action+' leaves capture and inspector demand unchanged',async()=>{const s=(await status()).sessions.find(s=>s.id==='emulator-5554');return !s.paused&&s.frames>before.frames&&Object.keys(s.accessibility.reader).length===0&&s.accessibility.requested===false});
   await evaluate('document.querySelector('+JSON.stringify(selector)+').focus()');
   await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13,text:'\r'});
   await cdp('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});await delay(100);
   await nativeCheck(size.name+' keyboard Enter activates '+action+' exactly once',async()=>{const s=(await status()).sessions.find(s=>s.id==='emulator-5554');return s.inputs===before.inputs+2&&s.last_inputs.at(-1).type===type});
   await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:' ',code:'Space',windowsVirtualKeyCode:32,text:' '});
   await cdp('Input.dispatchKeyEvent',{type:'keyUp',key:' ',code:'Space',windowsVirtualKeyCode:32});await delay(100);
   await nativeCheck(size.name+' keyboard Space activates '+action+' exactly once',async()=>{const s=(await status()).sessions.find(s=>s.id==='emulator-5554');return s.inputs===before.inputs+3&&s.last_inputs.at(-1).type===type});
   await evaluate('document.activeElement.blur()');
  }
  await click('[data-theme-choice="light"]');await wait("document.documentElement.dataset.theme==='light'");
  await check(size.name+' Android icons inherit actual light toolbar color',"(()=>{return ['back','app-switcher','menu'].every(a=>{const b=document.querySelector('[data-action='+a+']');return getComputedStyle(b).color===getComputedStyle(b.querySelector('svg')).color})&&document.querySelector('[data-theme-choice=light]').getAttribute('aria-pressed')==='true'&&getComputedStyle(document.body).backgroundColor.match(/[0-9]+/g).slice(0,3).reduce((a,v)=>a+Number(v),0)>600})()");
  if(['desktop','phone','small-phone','landscape-phone'].includes(size.name))await shot(size.name+'-light-android-controls');
  if(['desktop','phone'].includes(size.name)){
   await click('[data-theme-choice="dark"]');await wait("document.documentElement.dataset.theme==='dark'");
   await check(size.name+' Android icons inherit actual dark toolbar color',"(()=>{return ['back','app-switcher','menu'].every(a=>{const b=document.querySelector('[data-action='+a+']');return getComputedStyle(b).color===getComputedStyle(b.querySelector('svg')).color})&&document.querySelector('[data-theme-choice=dark]').getAttribute('aria-pressed')==='true'&&getComputedStyle(document.body).backgroundColor.match(/[0-9]+/g).slice(0,3).reduce((a,v)=>a+Number(v),0)<300})()");
   await shot(size.name+'-dark-android-controls');await click('[data-theme-choice="light"]');await wait("document.documentElement.dataset.theme==='light'");
  }

  await check(size.name+' Android button only',`document.querySelectorAll('[data-action="accessibility"]').length===1`);
  await nativeCheck(size.name+' video without pane never creates reader',async()=>Object.keys((await androidInfo()).reader).length===0);
  await check(size.name+' unopened pane has no JS/CSS load', `!document.querySelector('.accessibility-pane')&&!performance.getEntriesByType('resource').some(r=>r.name.endsWith('/js/accessibility.js')||r.name.endsWith('/css/accessibility.css'))`);
  await click('[data-action="accessibility"]');
  await wait(`document.querySelector('.a11y-speech').textContent.includes('Opens this decision support tool')`);
  await check(size.name+' speech only by default',`document.querySelector('.a11y-details').hidden && document.querySelector('.a11y-more').textContent==='More…' && document.querySelector('.a11y-speech').textContent==='ADHD. Attention-Deficit/Hyperactivity Disorder, Button, Opens this decision support tool'`);
  await check(size.name+' compact fits full viewport without footer',`(()=>{const p=document.querySelector('.accessibility-pane').getBoundingClientRect(),f=document.querySelector('.device-frame').getBoundingClientRect(),b=document.querySelector('#viewport-area').getBoundingClientRect();return p.top>=f.bottom-1&&p.bottom<=b.bottom+1&&document.documentElement.scrollWidth<=innerWidth+1&&document.documentElement.scrollHeight<=innerHeight+1})()`);
  await check(size.name+' inspector controls and selectable text', `document.querySelector('[data-action="accessibility"]').getAttribute('aria-controls')===document.querySelector('.accessibility-pane').id&&document.querySelector('.a11y-more').getAttribute('aria-controls')===document.querySelector('.a11y-details').id&&getComputedStyle(document.querySelector('.a11y-details')).userSelect==='text'`);

  await check(size.name+' default speech viewport is three lines',"(()=>{const b=document.querySelector('.a11y-body'),e=document.querySelector('.a11y-eyebrow'),s=getComputedStyle(b),h=b.clientHeight-parseFloat(s.paddingTop)-parseFloat(s.paddingBottom)-e.getBoundingClientRect().height-parseFloat(getComputedStyle(e).marginBottom),line=parseFloat(getComputedStyle(document.querySelector('.a11y-speech')).lineHeight);return Math.abs(h-3*line)<1.1})()");
  await check(size.name+' resize handle is inside top with no layout space',"(()=>{const p=document.querySelector('.accessibility-pane').getBoundingClientRect(),h=document.querySelector('.a11y-resize-handle'),r=h.getBoundingClientRect();return getComputedStyle(h).position==='absolute'&&r.top>=p.top&&r.top<=p.top+2&&r.bottom<p.bottom&&r.left>=p.left&&r.right<=p.right&&h.getAttribute('role')==='separator'&&h.getAttribute('aria-controls')===document.querySelector('.accessibility-pane').id})()");
  const stable=await geometry();let remainsStable=true;
  for(const text of ['Short.','One\nTwo\nThree','Long speech wraps without resizing. '.repeat(35)]){await speech(text);const g=await geometry();remainsStable&&=Math.abs(g.pane-stable.pane)<1&&Math.abs(g.frame-stable.frame)<1&&Math.abs(g.frameW-stable.frameW)<1&&g.cw===stable.cw&&g.ch===stable.ch}
  await nativeCheck(size.name+' one/three/many lines never resize pane or simulator',async()=>remainsStable);
  await check(size.name+' long speech scrolls without truncation',"(()=>{const b=document.querySelector('.a11y-body');b.scrollTop=b.scrollHeight;return b.scrollHeight>b.clientHeight+10&&b.scrollTop>0&&document.querySelector('.a11y-speech').textContent.length>1000})()");
  await speech('Composed fallback that continues across several lines. '.repeat(8),'composed');
  await nativeCheck(size.name+' variable note does not alter pane size',async()=>Math.abs((await geometry()).pane-stable.pane)<1);
  await check(size.name+' new utterance starts at top',"document.querySelector('.a11y-body').scrollTop===0");
  if(size.name==='phone')await shot('phone-fixed-three-lines-long-speech');
  await speech('ADHD. Attention-Deficit/Hyperactivity Disorder, Button, Opens this decision support tool');
  await evaluate(`window.__compact=document.querySelector('.device-frame').getBoundingClientRect().height;window.__resolution=[document.querySelector('canvas').width,document.querySelector('canvas').height]`);
  if(['desktop','phone'].includes(size.name))await shot(size.name+'-speech-compact');
  await click('.a11y-more');
  await check(size.name+' More expands BELOW and shrinks sim',`(()=>{const p=document.querySelector('.accessibility-pane').getBoundingClientRect(),f=document.querySelector('.device-frame').getBoundingClientRect();return p.top>=f.bottom-1&&f.height<window.__compact-2&&!document.querySelector('.a11y-details').hidden})()`);
  await check(size.name+' proportional refit keeps canvas resolution',`(()=>{const c=document.querySelector('canvas'),r=document.querySelector('.device-frame').getBoundingClientRect();return c.width===__resolution[0]&&c.height===__resolution[1]&&Math.abs(r.width-r.height*c.width/c.height)<=1.5})()`);
  await check(size.name+' all sample fields and no Center',`(()=>{const t=document.querySelector('.a11y-details').textContent;return t.includes('ROLE_BUTTON')&&t.includes('Screen bounds')&&t.includes('1006 × 368 px')&&t.includes('guidelines.childrensmercy.com.iguidelines')&&t.includes('ACTION_SHOW_ON_SCREEN')&&!t.includes('Center')})()`);
  await check(size.name+' expanded pane is bounded internal scroll',`(()=>{const p=document.querySelector('.accessibility-pane').getBoundingClientRect(),b=document.querySelector('#viewport-area').getBoundingClientRect(),body=document.querySelector('.a11y-body');return p.bottom<=b.bottom+1&&getComputedStyle(body).overflowY==='auto'&&document.documentElement.scrollWidth<=innerWidth+1})()`);
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

 // User sizing preferences are local to this private test browser/device.
 await navigate(1440,1000,false);await click('[data-action="accessibility"]');await wait("document.querySelector('.a11y-status').textContent==='Live'");
 const original=await geometry(),readerBefore=await androidInfo();
 await mouseResize(70);const resized=await geometry();
 await nativeCheck('Mouse grip grows pane and proportionally refits simulator',async()=>Math.abs(resized.pane-original.pane-70)<=2&&resized.frame<original.frame-2&&resized.cw===original.cw&&resized.ch===original.ch&&Math.abs(resized.frameW-resized.frame*resized.cw/resized.ch)<1.5);
 await nativeCheck('Grip never sends simulator input or changes subscription',async()=>resized.inputs===original.inputs&&resized.subscription===original.subscription);
 await nativeCheck('Resizing does not restart or interrupt reader',async()=>{const a=await androidInfo();return a.reader.running===true&&a.reader.starts===readerBefore.reader.starts});
 await resizeKey('ArrowUp');await nativeCheck('Keyboard ArrowUp grows pane',async()=>Math.abs((await geometry()).pane-resized.pane-16)<2);
 await resizeKey('ArrowDown');await nativeCheck('Keyboard ArrowDown restores size',async()=>Math.abs((await geometry()).pane-resized.pane)<2);
 await resizeKey('Home');await check('Keyboard Home safely reaches minimum',"document.querySelector('.a11y-resize-handle').getAttribute('aria-valuenow')===document.querySelector('.a11y-resize-handle').getAttribute('aria-valuemin')");
 await resizeKey('End');await check('Keyboard End keeps simulator and workspace bottom visible',"(()=>{const p=document.querySelector('.accessibility-pane').getBoundingClientRect(),f=document.querySelector('.device-frame').getBoundingClientRect(),stage=document.querySelector('.sim-stage');return stage.clientHeight>=47&&f.height>0&&f.bottom<=p.top+1&&p.bottom<=document.querySelector('#viewport-area').getBoundingClientRect().bottom+1})()");
 await resizeKey('Enter');await nativeCheck('Keyboard reset restores exact three-line default',async()=>Math.abs((await geometry()).pane-original.pane)<2);
 await mouseResize(70);
 await click('.a11y-more');const expanded=await geometry();await mouseResize(40);const customExpanded=await geometry();
 await nativeCheck('Expanded mode supports manual resizing',async()=>Math.abs(customExpanded.pane-expanded.pane-40)<2);
 await click('.a11y-more');await nativeCheck('Less restores chosen compact height',async()=>Math.abs((await geometry()).pane-resized.pane)<2);
 await click('.a11y-close');await click('[data-action="accessibility"]');await wait("document.querySelector('.a11y-status').textContent==='Live'");
 await nativeCheck('Close/reopen remembers compact preference',async()=>Math.abs((await geometry()).pane-resized.pane)<2);
 await closeStreams();await navigate(1440,1000,false);await click('[data-action="accessibility"]');await wait("document.querySelector('.a11y-status').textContent==='Live'");
 await nativeCheck('Reload restores saved compact height per device',async()=>Math.abs((await geometry()).pane-resized.pane)<2);
 await click('.a11y-more');await nativeCheck('Reload restores independent expanded height',async()=>Math.abs((await geometry()).pane-customExpanded.pane)<2);
 await cdp('Emulation.setDeviceMetricsOverride',{width:375,height:420,deviceScaleFactor:1,mobile:true});await delay(200);
 await check('Short viewport clamps remembered size without covering stream/workspace',"(()=>{const p=document.querySelector('.accessibility-pane').getBoundingClientRect(),f=document.querySelector('.device-frame').getBoundingClientRect();return f.height>0&&f.bottom<=p.top+1&&p.bottom<=document.querySelector('#viewport-area').getBoundingClientRect().bottom+1})()");
 await cdp('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});await delay(200);
 await nativeCheck('Viewport clamp never overwrites saved preferred height',async()=>Math.abs((await geometry()).pane-customExpanded.pane)<2);
 await click('.a11y-more');await shot('desktop-user-resized-pane');
 await closeStreams();await evaluate('localStorage.removeItem('+JSON.stringify(sizeKey)+')');
 await navigate(390,844,true);await click('[data-action="accessibility"]');await wait("document.querySelector('.a11y-status').textContent==='Live'");
 const phoneDefault=await geometry();await touchResize(55);const phoneCustom=await geometry();
 await nativeCheck('Touch grip resizes without scrolling workspace or sending input',async()=>Math.abs(phoneCustom.pane-phoneDefault.pane-55)<3&&phoneCustom.inputs===phoneDefault.inputs);
 await touchResize(35,true);await nativeCheck('Cancelled touch restores size and releases drag',async()=>Math.abs((await geometry()).pane-phoneCustom.pane)<2);
 await touchResize(10);await nativeCheck('New touch works after cancellation',async()=>Math.abs((await geometry()).pane-phoneCustom.pane-10)<3);
 const grip=await gripPoint();await cdp('Input.dispatchMouseEvent',{type:'mousePressed',x:grip.x,y:grip.y,button:'left',clickCount:2});await cdp('Input.dispatchMouseEvent',{type:'mouseReleased',x:grip.x,y:grip.y,button:'left',clickCount:2});await delay(100);
 await nativeCheck('Double-click grip resets chosen compact size',async()=>Math.abs((await geometry()).pane-phoneDefault.pane)<2);
 await shot('phone-fixed-three-lines-grip');
 await closeStreams();await evaluate('localStorage.setItem('+JSON.stringify(sizeKey)+','+JSON.stringify('{"compact":-1,"expanded":999999}')+')');
 await navigate(390,844,true);await click('[data-action="accessibility"]');await wait("document.querySelector('.a11y-status').textContent==='Live'");
 await nativeCheck('Invalid stored sizes fall back to default',async()=>Math.abs((await geometry()).pane-phoneDefault.pane)<2);
 await evaluate('(()=>{const original=Storage.prototype.setItem;Storage.prototype.setItem=function(k,v){if(k==='+JSON.stringify(sizeKey)+')throw new Error("fixture blocked storage");return original.call(this,k,v)}})()');
 await touchResize(30);await nativeCheck('Blocked storage does not break resizing',async()=>Math.abs((await geometry()).pane-phoneDefault.pane-30)<3);
 await closeStreams();await evaluate('localStorage.removeItem('+JSON.stringify(sizeKey)+')');

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
 // iOS shortcuts use their selected stream, never browser keyboard forwarding or Android.
 const iosInfo=async()=> (await status()).sessions.find(s=>s.id==='ios-fixture');
 for(const size of [...sizes,{name:'tablet',w:768,h:1024,m:true}]){
  await navigate(size.w,size.h,size.m,'ios-fixture');
  await click('[data-theme-choice="light"]');await wait("document.documentElement.dataset.theme==='light'");
  await check(size.name+' iOS controls are reviewed in actual light workspace',"document.querySelector('[data-theme-choice=light]').getAttribute('aria-pressed')==='true'&&getComputedStyle(document.body).backgroundColor.match(/[0-9]+/g).slice(0,3).reduce((a,v)=>a+Number(v),0)>600");
  await check(size.name+' Back and Menu stay absent on iOS',"!document.querySelector('[data-action=back]')&&!document.querySelector('[data-action=menu]')");
  await check(size.name+' Shake immediately follows Home only on iOS',"(()=>{const b=document.querySelector('[data-action=shake]');return document.querySelectorAll('[data-action=shake]').length===1&&b.previousElementSibling.dataset.action==='home'&&b.nextElementSibling.dataset.action==='app-switcher'&&!document.querySelector('[data-action=accessibility]')})()");
  await check(size.name+' Shake icon is bounded, decorative and named',"(()=>{const b=document.querySelector('[data-action=shake]'),s=b.querySelector('svg'),r=s.getBBox();return b.title==='Shake (Control–Command–Z)'&&b.getAttribute('aria-label')===b.title&&s.getAttribute('aria-hidden')==='true'&&s.getAttribute('viewBox')==='0 0 20 20'&&r.x>=.8&&r.y>=.8&&r.x+r.width<=19.2&&r.y+r.height<=19.2})()");
  await check(size.name+' all bottom buttons fit and accept pointer input',"(()=>{const p=document.querySelector('.sim-panel').getBoundingClientRect(),a=document.querySelector('.panel-actions').getBoundingClientRect();return a.left>=p.left&&a.right<=p.right&&a.bottom<=innerHeight&&[...document.querySelectorAll('.pill-btn')].every(b=>{const r=b.getBoundingClientRect();return r.width>=32&&r.height>=32&&r.left>=a.left&&r.right<=a.right&&b.contains(document.elementFromPoint(r.left+r.width/2,r.top+r.height/2))})&&document.documentElement.scrollWidth<=innerWidth+1})()");
  await check(size.name+' existing iOS controls retain their order',"[...document.querySelectorAll('.panel-actions button')].map(b=>b.dataset.action).join(',')==='rotate,home,shake,app-switcher,appear,kbd,close'");
  await nativeCheck(size.name+' Shake is never sent on startup',async()=>(await iosInfo()).inputs===0);
  const before=await iosInfo();await pointerClick('[data-action=shake]');
  await nativeCheck(size.name+' pointer sends exactly one Shake on the iOS socket',async()=>{const s=await iosInfo();return s.inputs===before.inputs+1&&JSON.stringify(s.last_inputs.at(-1))==='{"type":"shake"}'});
  await check(size.name+' Shake selects the panel without opening keyboard or inspector',"document.querySelector('.sim-panel').classList.contains('focused')&&document.querySelector('#kbd-input').placeholder==='Send text to iPhone 11…'&&!document.querySelector('#kbd-bar').classList.contains('visible')&&!document.querySelector('.accessibility-pane')");
  await nativeCheck(size.name+' Shake leaves capture and inspector demand unchanged',async()=>{const s=await iosInfo();return !s.paused&&s.frames>before.frames&&Object.keys(s.accessibility.reader).length===0&&s.accessibility.requested===false});
  await evaluate("document.querySelector('[data-action=shake]').focus()");
  await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13,text:'\r'});
  await cdp('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});await delay(100);
  await nativeCheck(size.name+' keyboard Enter activates Shake once',async()=>(await iosInfo()).inputs===before.inputs+2&&(await iosInfo()).last_inputs.at(-1).type==='shake');
  await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:' ',code:'Space',windowsVirtualKeyCode:32,text:' '});
  await cdp('Input.dispatchKeyEvent',{type:'keyUp',key:' ',code:'Space',windowsVirtualKeyCode:32});await delay(100);
  await nativeCheck(size.name+' keyboard Space activates Shake once',async()=>(await iosInfo()).inputs===before.inputs+3&&(await iosInfo()).last_inputs.at(-1).type==='shake');
  await evaluate('document.activeElement.blur()');
  await check(size.name+' App switcher immediately follows Shake only on iOS',"(()=>{const b=document.querySelector('[data-action=app-switcher]');return document.querySelectorAll('[data-action=app-switcher]').length===1&&b.previousElementSibling.dataset.action==='shake'&&b.nextElementSibling.dataset.action==='appear'&&!document.querySelector('[data-action=accessibility]')})()");
  await check(size.name+' custom App switcher icon is bounded, decorative and named',"(()=>{const b=document.querySelector('[data-action=app-switcher]'),s=b.querySelector('svg'),r=s.getBBox();return b.title==='App switcher (Shift–Command–H–H)'&&b.getAttribute('aria-label')===b.title&&s.getAttribute('aria-hidden')==='true'&&s.getAttribute('viewBox')==='0 0 20 20'&&s.querySelectorAll('rect').length===1&&s.querySelectorAll('path').length===2&&r.x>=.8&&r.y>=.8&&r.x+r.width<=19.2&&r.y+r.height<=19.2})()");
  const switcherBefore=await iosInfo();await pointerClick('[data-action=app-switcher]');
  await nativeCheck(size.name+' pointer sends exactly one App switcher request on the iOS socket',async()=>{const s=await iosInfo();return s.inputs===switcherBefore.inputs+1&&JSON.stringify(s.last_inputs.at(-1))==='{"type":"app_switcher"}'});
  await check(size.name+' App switcher keeps selected panel without opening keyboard or inspector',"document.querySelector('.sim-panel').classList.contains('focused')&&document.querySelector('#kbd-input').placeholder==='Send text to iPhone 11…'&&!document.querySelector('#kbd-bar').classList.contains('visible')&&!document.querySelector('.accessibility-pane')");
  await nativeCheck(size.name+' App switcher leaves capture and inspector demand unchanged',async()=>{const s=await iosInfo();return !s.paused&&s.frames>switcherBefore.frames&&Object.keys(s.accessibility.reader).length===0&&s.accessibility.requested===false});
  await evaluate("document.querySelector('[data-action=app-switcher]').focus()");
  await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13,text:'\r'});
  await cdp('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});await delay(100);
  await nativeCheck(size.name+' keyboard Enter activates App switcher once',async()=>(await iosInfo()).inputs===switcherBefore.inputs+2&&(await iosInfo()).last_inputs.at(-1).type==='app_switcher');
  await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:' ',code:'Space',windowsVirtualKeyCode:32,text:' '});
  await cdp('Input.dispatchKeyEvent',{type:'keyUp',key:' ',code:'Space',windowsVirtualKeyCode:32});await delay(100);
  await nativeCheck(size.name+' keyboard Space activates App switcher once',async()=>(await iosInfo()).inputs===switcherBefore.inputs+3&&(await iosInfo()).last_inputs.at(-1).type==='app_switcher');
  await evaluate('document.activeElement.blur()');
  if(['desktop','phone','small-phone','landscape-phone'].includes(size.name))await shot(size.name+'-ios-app-switcher');
  if(['desktop','phone'].includes(size.name)){
   await click('[data-theme-choice="dark"]');await wait("document.documentElement.dataset.theme==='dark'");
   await check(size.name+' App switcher dark icon inherits toolbar color in actual dark workspace',"(()=>{const b=document.querySelector('[data-action=app-switcher]');return getComputedStyle(b).color===getComputedStyle(b.querySelector('svg')).color&&document.querySelector('[data-theme-choice=dark]').getAttribute('aria-pressed')==='true'&&getComputedStyle(document.body).backgroundColor.match(/[0-9]+/g).slice(0,3).reduce((a,v)=>a+Number(v),0)<300})()");
   await shot(size.name+'-dark-ios-app-switcher');await click('[data-theme-choice="light"]');await wait("document.documentElement.dataset.theme==='light'");
   await check(size.name+' App switcher light icon inherits toolbar color in actual light workspace',"(()=>{const b=document.querySelector('[data-action=app-switcher]');return getComputedStyle(b).color===getComputedStyle(b.querySelector('svg')).color&&document.querySelector('[data-theme-choice=light]').getAttribute('aria-pressed')==='true'&&getComputedStyle(document.body).backgroundColor.match(/[0-9]+/g).slice(0,3).reduce((a,v)=>a+Number(v),0)>600})()");
   await shot(size.name+'-light-ios-app-switcher');
  }
  await pointerClick('[data-action=home]');await nativeCheck(size.name+' Home still sends its original message',async()=>(await iosInfo()).last_inputs.at(-1).type==='home');
  await pointerClick('[data-action=appear]');await nativeCheck(size.name+' appearance still sends its original mode',async()=>{const m=(await iosInfo()).last_inputs.at(-1);return m.type==='appearance'&&m.mode==='light'});
  await pointerClick('[data-action=kbd]');await check(size.name+' keyboard toggle still opens and focuses text input',"document.querySelector('#kbd-bar').classList.contains('visible')&&document.activeElement.id==='kbd-input'");
  await evaluate("document.querySelector('#kbd-input').value='Shake regression'");await click('#kbd-send');
  await nativeCheck(size.name+' keyboard text is still a text command',async()=>{const m=(await iosInfo()).last_inputs.at(-1);return m.type==='text'&&m.text==='Shake regression'});
  await pointerClick('[data-action=kbd]');
  await closeStreams();await nativeCheck(size.name+' panel close tears down its stream',async()=>(await status()).sessions.length===0);
 }
 // Different desktop panels must not route via the previously focused device.
 await navigate(1440,1000,false);
 await click('.device-item[data-udid="ios-fixture"]');await wait("document.querySelectorAll('.sim-panel').length===2&&document.querySelector('.sim-panel[data-udid=ios-fixture] .panel-status').textContent==='Live'");
 await pointerClick('.sim-panel[data-udid="emulator-5554"] [data-action=home]');
 const mixedBefore=await status(),androidBefore=mixedBefore.sessions.find(s=>s.id==='emulator-5554');
 await pointerClick('.sim-panel[data-udid="ios-fixture"] [data-action=shake]');
 await nativeCheck('Mixed panels send Shake only to iOS despite prior Android focus',async()=>{const s=await status(),a=s.sessions.find(p=>p.id==='emulator-5554'),i=s.sessions.find(p=>p.id==='ios-fixture');return a.inputs===androidBefore.inputs&&i.inputs===1&&i.last_inputs[0].type==='shake'});
 await check('Mixed panels keep Android controls separate and focus iOS on Shake',"!document.querySelector('.sim-panel[data-udid=\"emulator-5554\"] [data-action=shake]')&&document.querySelector('.sim-panel[data-udid=ios-fixture]').classList.contains('focused')&&!!document.querySelector('.sim-panel[data-udid=\"emulator-5554\"] [data-action=accessibility]')");
 // Even a forged frontend button cannot bypass the per-panel iOS gate.
 await evaluate("(()=>{const b=document.createElement('button');b.dataset.action='shake';document.querySelector('.sim-panel[data-udid=\"emulator-5554\"] .panel-actions').append(b);b.click();b.remove()})()");
 await nativeCheck('Forged Android Shake button sends nothing',async()=>(await status()).sessions.find(s=>s.id==='emulator-5554').inputs===androidBefore.inputs);
 await pointerClick('.sim-panel[data-udid="emulator-5554"] [data-action=home]');
 const switcherMixedBefore=await status(),switcherAndroidBefore=switcherMixedBefore.sessions.find(s=>s.id==='emulator-5554'),switcherIOSBefore=switcherMixedBefore.sessions.find(s=>s.id==='ios-fixture');
 await pointerClick('.sim-panel[data-udid="ios-fixture"] [data-action=app-switcher]');
 await nativeCheck('Mixed panels send App switcher only to iOS despite prior Android focus',async()=>{const s=await status(),a=s.sessions.find(p=>p.id==='emulator-5554'),i=s.sessions.find(p=>p.id==='ios-fixture');return a.inputs===switcherAndroidBefore.inputs&&i.inputs===switcherIOSBefore.inputs+1&&i.last_inputs.at(-1).type==='app_switcher'});
 await check('Mixed panels keep both App switcher controls and focus selected iOS',"!!document.querySelector('.sim-panel[data-udid=\"emulator-5554\"] [data-action=app-switcher]')&&document.querySelector('.sim-panel[data-udid=ios-fixture]').classList.contains('focused')");
 // The legitimate Android App switcher uses ADB routing, not the iOS shortcut.
 await pointerClick('.sim-panel[data-udid="emulator-5554"] [data-action=app-switcher]');
 await nativeCheck('Mixed panels send Android App switcher only to Android despite prior iOS focus',async()=>{const s=await status(),a=s.sessions.find(p=>p.id==='emulator-5554'),i=s.sessions.find(p=>p.id==='ios-fixture');return a.inputs===switcherAndroidBefore.inputs+1&&i.inputs===switcherIOSBefore.inputs+1&&JSON.stringify(a.last_inputs.at(-1))==='{"type":"app_switcher"}'});
 await shot('desktop-mixed-ios-app-switcher');
 // All Android navigation controls use their own panel, never prior focus.
 for(const [action,type]of [['back','back'],['app-switcher','app_switcher'],['menu','menu']]){
  await pointerClick('.sim-panel[data-udid="ios-fixture"] [data-action=home]');
  const before=await status(),aBefore=before.sessions.find(s=>s.id==='emulator-5554'),iBefore=before.sessions.find(s=>s.id==='ios-fixture');
  await pointerClick('.sim-panel[data-udid="emulator-5554"] [data-action='+action+']');
  await nativeCheck('Mixed panels '+action+' targets Android despite prior iOS focus',async()=>{const s=await status(),a=s.sessions.find(p=>p.id==='emulator-5554'),i=s.sessions.find(p=>p.id==='ios-fixture');return a.inputs===aBefore.inputs+1&&JSON.stringify(a.last_inputs.at(-1))===JSON.stringify({type})&&i.inputs===iBefore.inputs});
 }
 await check('App switcher reuses exactly the iOS icon, with platform-specific titles',"(()=>{const a=document.querySelector('.sim-panel[data-udid=\"emulator-5554\"] [data-action=app-switcher]'),i=document.querySelector('.sim-panel[data-udid=ios-fixture] [data-action=app-switcher]');return a.querySelector('svg').outerHTML===i.querySelector('svg').outerHTML&&a.title==='App switcher'&&i.title==='App switcher (Shift–Command–H–H)'})()");
 for(const action of ['back','menu']){
  const before=(await status()).sessions.find(s=>s.id==='ios-fixture').inputs;
  await evaluate("(()=>{const b=document.createElement('button');b.dataset.action="+JSON.stringify(action)+";document.querySelector('.sim-panel[data-udid=ios-fixture] .panel-actions').append(b);b.click();b.remove()})()");
  await nativeCheck('Forged iOS '+action+' button sends nothing',async()=>(await status()).sessions.find(s=>s.id==='ios-fixture').inputs===before);
 }
 await shot('desktop-mixed-android-controls');await closeStreams();
 await navigate(1440,1000,false);await click('.device-item[data-udid="emulator-5556"]');
 await wait("document.querySelectorAll('.sim-panel').length===2&&document.querySelector('.sim-panel[data-udid=\"emulator-5556\"] .panel-status').textContent==='Live'");
 for(const [target,other]of [['emulator-5556','emulator-5554'],['emulator-5554','emulator-5556']]){
  for(const [action,type]of [['back','back'],['app-switcher','app_switcher'],['menu','menu']]){
   await pointerClick('.sim-panel[data-udid="'+other+'"] [data-action=home]');
   const before=await status(),targetBefore=before.sessions.find(s=>s.id===target),otherBefore=before.sessions.find(s=>s.id===other);
   await pointerClick('.sim-panel[data-udid="'+target+'"] [data-action='+action+']');
   await nativeCheck('Two Android panels '+action+' targets '+target+', not focused '+other,async()=>{const s=await status(),a=s.sessions.find(p=>p.id===target),b=s.sessions.find(p=>p.id===other);return a.inputs===targetBefore.inputs+1&&b.inputs===otherBefore.inputs&&JSON.stringify(a.last_inputs.at(-1))===JSON.stringify({type})});
  }
 }
 await nativeCheck('Navigation never opens either Android inspector',async()=>(await status()).sessions.every(s=>!s.paused&&s.accessibility.requested===false&&Object.keys(s.accessibility.reader).length===0));
 await shot('desktop-two-android-controls');await closeStreams();
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

 // Exercise sidebar-only entry and unchanged automatic reload restoration,
 // with bundled xterm and synthetic sockets. Never create or touch a Mac shell.
 const modeResponse=await fetch(base+'/fixture/mode',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({terminal:true})});
 if(!modeResponse.ok)throw Error('Could not enable fixture terminal');
 for(const size of [{name:'desktop',w:1440,h:1000,m:false},{name:'phone',w:390,h:844,m:true}]){
  await navigate(size.w,size.h,size.m);await wait("!document.querySelector('#btn-terminal').disabled");
  const terminalBefore=(await status()).terminal;
  await check(size.name+' sidebar enabled without eager terminal assets',"document.querySelector('#btn-terminal').title==='Open a Mac terminal'&&!document.querySelector('#tab-terminal')&&!performance.getEntriesByType('resource').some(r=>r.name.endsWith('/js/terminal.js'))");
  await check(size.name+' full workspace has no reserved footer strip',"!document.querySelector('#bottom-tab-bar')&&parseFloat(getComputedStyle(document.querySelector('#viewport-area')).paddingBottom)===0&&Math.abs(document.querySelector('#viewport-area').getBoundingClientRect().bottom-document.querySelector('#content').getBoundingClientRect().bottom)<=1");
  await showSidebar();await shot(size.name+'-sidebar-terminal');
  if(!size.m){await click('[data-theme-choice="dark"]');await shot('desktop-dark-sidebar-terminal');await click('[data-theme-choice="light"]')}
  await sidebarTerminal();
  await wait("!document.querySelector('#terminal-panel').hidden&&document.querySelector('#term-status-dot').title==='connected'&&document.querySelector('.xterm-rows').textContent.includes('Fixture terminal output')");
  await check(size.name+' sidebar pointer opens terminal with correct ARIA',"document.querySelector('#btn-terminal').classList.contains('active')&&document.querySelector('#btn-terminal').getAttribute('aria-expanded')==='true'&&document.querySelectorAll('.term-tab').length===1");
  await check(size.name+' local xterm lazily renders synthetic output',"performance.getEntriesByType('resource').some(r=>r.name.endsWith('/js/vendor/xterm.js'))&&performance.getEntriesByType('resource').some(r=>r.name.endsWith('/css/terminal.css'))&&[...performance.getEntriesByType('resource')].every(r=>new URL(r.name).origin===location.origin)");
  await nativeCheck(size.name+' terminal socket is ACKed and never starts logcat',async()=>{const s=await status();return s.terminal.active===1&&s.terminal.starts===terminalBefore.starts+1&&s.terminal.output_acks>terminalBefore.output_acks&&Object.keys(s.sessions.find(p=>p.id==='emulator-5554').accessibility.reader).length===0});
  await click('#btn-close-term');
  await check(size.name+' collapse restores workspace, not a bottom bar',"document.querySelector('#terminal-panel').hidden&&!document.querySelector('#bottom-tab-bar')&&document.querySelector('#btn-terminal').getAttribute('aria-expanded')==='false'&&!document.querySelector('#content').classList.contains('pinned-right')");
  await sidebarTerminal();await wait("!document.querySelector('#terminal-panel').hidden");
  await nativeCheck(size.name+' sidebar reopens existing tab without extra socket',async()=>{const s=await status();return s.terminal.active===1&&s.terminal.starts===terminalBefore.starts+1});
  if(!size.m)await click('#btn-pin-term');
  const savedID=await evaluate("JSON.parse(sessionStorage.getItem('simwispTerminalTabs'))[0].sessionId");
  await cdp('Page.navigate',{url:base+'/'});
  await wait("!!document.querySelector('.sim-panel')&&!document.querySelector('#terminal-panel').hidden&&document.querySelector('#term-status-dot').title==='connected'&&document.querySelector('.xterm-rows').textContent.includes('Fixture terminal output')");
  await check(size.name+' reload automatically restores open terminal and saved session',"document.querySelector('#btn-terminal').getAttribute('aria-expanded')==='true'&&document.querySelectorAll('.term-tab').length===1&&window.__wire.sockets.some(s=>s.url.includes('/ws/pty')&&s.url.includes("+JSON.stringify(savedID)+"))");
  await check(size.name+' reload preserves pin preference',"document.querySelector('#content').classList.contains('pinned-right')==="+(!size.m));
  await nativeCheck(size.name+' automatic restore remains terminal-only demand',async()=>{const s=await status();return s.terminal.active===1&&s.terminal.starts===terminalBefore.starts+2&&Object.keys(s.sessions[0].accessibility.reader).length===0});
  await shot(size.name+'-terminal-reloaded');
  await click('#btn-close-term');
  const collapsedID=await evaluate("JSON.parse(sessionStorage.getItem('simwispTerminalTabs'))[0].sessionId");
  await cdp('Page.navigate',{url:base+'/'});await wait("!!document.querySelector('.sim-panel canvas')&&document.querySelector('.panel-status').textContent==='Live'&&!document.querySelector('#btn-terminal').disabled");await delay(200);
  await check(size.name+' reload of collapsed terminal stays lazy and hidden',"document.querySelector('#terminal-panel').hidden&&document.querySelector('#terminal-panel').inert&&document.querySelector('#btn-terminal').getAttribute('aria-expanded')==='false'&&!performance.getEntriesByType('resource').some(r=>r.name.endsWith('/js/terminal.js'))&&!window.__wire.sockets.some(s=>s.url.includes('/ws/pty'))");
  await nativeCheck(size.name+' collapsed reload creates no terminal socket',async()=>{const s=await status();return s.terminal.active===0&&s.terminal.starts===terminalBefore.starts+2});
  await sidebarTerminal();await wait("document.querySelector('#term-status-dot').title==='connected'");
  await check(size.name+' sidebar resumes retained tab after collapsed reload',"window.__wire.sockets.some(s=>s.url.includes('/ws/pty')&&s.url.includes("+JSON.stringify(collapsedID)+"))&&document.querySelectorAll('.term-tab').length===1");
  await click('.term-tab-close');
  await check(size.name+' last tab close restores enabled sidebar toggle',"document.querySelector('#terminal-panel').hidden&&!document.querySelector('#btn-terminal').disabled&&document.querySelector('#btn-terminal').getAttribute('aria-expanded')==='false'&&document.querySelectorAll('.term-tab').length===0");
  await nativeCheck(size.name+' test terminal socket closes without shell activity',async()=>(await status()).terminal.active===0);
  await closeStreams();
 }
 await fetch(base+'/fixture/mode',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({terminal:false})});

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
