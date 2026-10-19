import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {spawn} from 'node:child_process';

// Component-only Chrome regression: no app service, capture, ADB or simulator.
if(process.platform!=='darwin'||typeof WebSocket==='undefined')throw Error('Requires macOS, Chrome and Node22');
const root=process.cwd(),scratch=fs.mkdtempSync(path.join(os.tmpdir(),'simwisp-backend-ui-'));
const checks=[],exceptions=[],pending=new Map();let chrome,ws,sequence=0;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const files=new Map(['/js/ios-capture.js','/js/android-backends.js','/css/tokens.css','/css/layout.css','/css/components.css'].map(p=>[p,root+'/Resources/Web'+p]));
files.set('/app-source.txt',root+'/Resources/Web/js/app.js');
const server=http.createServer((req,res)=>{
 const p=new URL(req.url,'http://localhost').pathname;
 if(p==='/'){res.setHeader('Content-Type','text/html');res.end('<!doctype html><meta charset="utf-8"><link rel="stylesheet" href="/css/tokens.css"><link rel="stylesheet" href="/css/layout.css"><link rel="stylesheet" href="/css/components.css"><body style="display:block;padding:12px;margin:0"></body>');return}
 if(!files.has(p)){res.writeHead(404);res.end();return}
 res.setHeader('Content-Type',p.endsWith('.css')?'text/css':p.endsWith('.js')?'text/javascript':'text/plain');res.end(fs.readFileSync(files.get(p)));
});
const cdp=(method,params={})=>new Promise((resolve,reject)=>{const id=++sequence,timer=setTimeout(()=>{pending.delete(id);reject(Error('CDP timeout '+method))},10000);pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params}))});
async function ev(expression){const r=await cdp('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value}
async function until(name,fn){for(let i=0;i<100;i++){if(await fn())return;await sleep(50)}throw Error('Timeout '+name)}
async function check(name,expression){const passed=await ev(expression)===true;checks.push({name,passed});if(!passed)throw Error(name)}
let passed=false,error;
try{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 chrome=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new','--disable-gpu','--remote-debugging-address=127.0.0.1','--remote-debugging-port=0','--user-data-dir='+scratch,'--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-sync','--disable-extensions','about:blank'],{stdio:['ignore','ignore','ignore'],detached:true});
 await until('owned Chrome',()=>fs.existsSync(scratch+'/DevToolsActivePort'));
 const port=fs.readFileSync(scratch+'/DevToolsActivePort','utf8').split('\n')[0],tabs=await(await fetch('http://127.0.0.1:'+port+'/json/list')).json();
 ws=new WebSocket(tabs.find(t=>t.type==='page').webSocketDebuggerUrl);await new Promise((r,j)=>{ws.addEventListener('open',r,{once:true});ws.addEventListener('error',j,{once:true})});
 ws.addEventListener('message',e=>{const m=JSON.parse(e.data);if(m.id&&pending.has(m.id)){const p=pending.get(m.id);pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result)}else if(m.method==='Runtime.exceptionThrown')exceptions.push(m.params)});
 await cdp('Runtime.enable');await cdp('Page.enable');await cdp('Emulation.setDeviceMetricsOverride',{width:1280,height:900,deviceScaleFactor:1,mobile:false});await cdp('Page.navigate',{url:'http://127.0.0.1:'+server.address().port});await until('page',()=>ev("document.readyState==='complete'"));
 await ev(`(async()=>{
  const {IOSCapture}=await import('/js/ios-capture.js'),{AndroidBackends,backendIcon}=await import('/js/android-backends.js');
  const source=await(await fetch('/app-source.txt')).text(),start=source.indexOf('function createPill('),end=source.indexOf(String.fromCharCode(10)+'  return pill;'+String.fromCharCode(10)+'}',start)+17;
  if(start<0)throw Error('Production pill renderer missing');
  const createPill=new Function('backendIcon','esc',source.slice(start,end<0?undefined:end)+';return createPill;')(backendIcon,s=>s);
  localStorage.clear();window.changes={ios:[],android:[],phone:[]};window.unexpectedSockets=0;window.WebSocket=class{constructor(){unexpectedSockets++;throw Error('UI test must not open a product socket')}};
  window.make=(kind,id)=>{const physical=kind==='phone',platform=kind==='ios'?'ios':'android',pill=createPill(id,'Synthetic',platform,physical);pill.style.cssText='position:static;width:min(360px,100%);margin-bottom:12px';document.body.append(pill);const trigger=pill.querySelector('.backend-trigger'),ui=kind==='ios'?new IOSCapture(trigger,'Synthetic',id,v=>changes.ios.push(v)):new AndroidBackends(trigger,'Synthetic',id,v=>changes[kind].push(v),{physical});return{ui,pill,trigger,menu:document.getElementById(trigger.getAttribute('aria-controls'))}};
  window.ios=make('ios','copy-ios');window.android=make('android','copy-emulator');window.phone=make('phone','copy-phone');return true;
 })()`);
 await check('iOS footer trigger says Backends',"ios.trigger.textContent.trim()==='Backends'");
 await check('iOS trigger accessible label and tooltip say backends',"ios.trigger.title==='iOS backends'&&ios.trigger.getAttribute('aria-label')==='iOS backends'");
 await check('Android trigger remains Backends',"android.trigger.textContent.trim()==='Backends'&&android.trigger.getAttribute('aria-label')==='Android backends'");
 await check('iOS popup heading and dialog accessibility say backends',"ios.menu.querySelector('h2').textContent==='iOS backends'&&ios.menu.getAttribute('aria-label')==='iOS backends'&&ios.menu.querySelector('.backend-close').getAttribute('aria-label')==='Close iOS backends'");
 await check('iOS default explanation paragraph removed',"!ios.menu.querySelector('.backend-explainer')&&!ios.menu.textContent.includes('Mac window is the default')");
 await check('iOS capture choices and default unchanged',"JSON.stringify([...ios.menu.querySelectorAll('[data-kind=capture]')].map(b=>b.dataset.choice))==='[\"current\",\"native\"]'&&JSON.stringify(ios.ui.choices)===JSON.stringify({capture:'current',input:'current',nativeScaling:'1'})");
 await ev("ios.trigger.click();ios.menu.querySelector('[data-choice=native]').click();ios.ui.receive({type:'ios_capture',capture:'native',native_scale:'1',effective_capture:'native'})");
 await check('iOS live tooltip keeps the Backends name',"ios.trigger.title==='iOS backends — capture: native, input: current'&&ios.menu.querySelector('[data-effective=capture]').textContent==='Using Native → H.264'");
 await ev("ios.menu.querySelector('[data-kind=scaling][data-choice=\"0.5\"]').click()");
 await check('Native selection and scaling callbacks unchanged',"changes.ios.length===2&&ios.ui.choices.capture==='native'&&ios.ui.choices.input==='current'&&ios.ui.choices.nativeScaling==='0.5'");
 await ev("ios.menu.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))");
 await check('iOS Escape closes popup and restores focus',"ios.menu.hidden&&document.activeElement===ios.trigger");
 await check('Android Auto explanation paragraph removed',"!android.menu.querySelector('.backend-explainer')&&!android.menu.textContent.includes('Auto prefers scrcpy')");
 await check('Android emulator modes and defaults unchanged',"JSON.stringify([...android.menu.querySelectorAll('[data-kind=capture]')].map(b=>b.dataset.choice))==='[\"auto\",\"scrcpy\",\"current\",\"jpeg\",\"raw\"]'&&JSON.stringify(android.ui.choices)===JSON.stringify({capture:'auto',input:'auto',scaling:'1'})");
 await ev("android.trigger.click();android.menu.querySelector('[data-kind=capture][data-choice=raw]').click();android.ui.receive({type:'android_backends',capture:'raw',input:'auto',effective_capture:'raw',effective_input:'current',raw_available:true,available:true})");
 await check('Android Raw availability has no experimental label',"android.menu.querySelector('.backend-availability-text').textContent==='Emulator Raw available'&&!/experimental/i.test(android.menu.textContent)");
 await check('Android Raw tooltip has no experimental label',"!(/experimental/i.test(android.menu.querySelector('[data-kind=capture][data-choice=raw]').title))");
 await check('Raw remains explicit, with unchanged input and source callback',"changes.android.length===1&&android.ui.choices.capture==='raw'&&android.ui.choices.input==='auto'&&android.menu.querySelector('[data-effective=capture]').textContent==='Using raw RGBA → H.264'");
 await ev("android.ui.receive({type:'android_backends',capture:'raw',input:'auto',effective_capture:'unavailable',effective_input:'current',raw_available:false,reason:'Unavailable <img src=x>'})");
 await check('Backend failure warning remains safe text',"android.menu.querySelector('.backend-warning').textContent==='Unavailable <img src=x>'&&!android.menu.querySelector('.backend-warning img')");
 await check('Physical Android keeps its distinct explanation',"phone.menu.querySelector('.backend-explainer').textContent.includes('USB or Wi-Fi')&&phone.menu.querySelector('.backend-footer').textContent.includes('Only affects this device')");
 await check('Physical phone choices remain JPEG/scrcpy only',"JSON.stringify([...phone.menu.querySelectorAll('[data-kind=capture]')].map(b=>b.dataset.choice))==='[\"jpeg\",\"scrcpy\"]'&&phone.ui.choices.capture==='jpeg'&&phone.ui.choices.input==='scrcpy'");
 await ev("android.ui.open(false)");
 for(const [width,height]of [[320,568],[390,844],[1280,900]]){
  await cdp('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:false});
  for(const kind of ['ios','android']){await ev(`${kind}.ui.open(true)`);await check(kind+' popup fits '+width+'x'+height,`(()=>{const r=${kind}.menu.getBoundingClientRect();return r.left>=0&&r.top>=0&&r.right<=innerWidth+1&&r.bottom<=innerHeight+1})()`);await ev(`${kind}.ui.open(false)`)}
 }
 await ev("ios.ui.destroy();ios.pill.remove();ios=make('ios','copy-ios');android.ui.destroy();android.pill.remove();android=make('android','copy-emulator')");
 await check('iOS Native and scaling preferences still persist per simulator',"ios.ui.choices.capture==='native'&&ios.ui.choices.nativeScaling==='0.5'");
 await check('Android Raw preference still persists per emulator',"android.ui.choices.capture==='raw'&&android.ui.choices.input==='auto'");
 await check('iOS Input is an independent closed Quartz/Native radio group',"ios.menu.querySelector('[aria-label=\"Input backend\"]')?.getAttribute('role')==='radiogroup'&&JSON.stringify([...ios.menu.querySelectorAll('[data-kind=input]')].map(b=>b.textContent))==='[\"Quartz\",\"Native\"]'&&ios.ui.choices.input==='current'");
 await ev("ios.trigger.click();ios.menu.querySelector('[data-kind=input][data-choice=native]').click();ios.ui.receive({type:'ios_capture',capture:'native',input:'native',native_scale:'0.5',effective_capture:'native',effective_input:'native'})");
 await check('Native input callback leaves capture and scale unchanged',"ios.ui.choices.capture==='native'&&ios.ui.choices.nativeScaling==='0.5'&&changes.ios.at(-1).input==='native'&&ios.menu.querySelector('[data-effective=input]').textContent==='Using Native'");
 await ev("ios.ui.receive({type:'ios_capture',capture:'native',input:'current',native_scale:'0.5',effective_capture:'unavailable',effective_input:'unavailable'})");
 await check('Stale input-mode snapshot cannot overwrite active Native badges',"ios.menu.querySelector('[data-effective=input]').textContent==='Using Native'&&ios.menu.querySelector('[data-effective=capture]').textContent==='Using Native → H.264'");
 await ev("ios.ui.receive({type:'input_error',message:'Native refused <img src=x onerror=window.__injected=true>'})");
 await check('Native input errors are bounded safe text',"ios.menu.querySelector('.backend-warning').textContent.includes('<img')&&!ios.menu.querySelector('.backend-warning img')");
 await ev("ios.ui.destroy();ios.pill.remove();ios=make('ios','copy-ios');window.otherIOS=make('ios','copy-ios-other')");
 await check('Native input persists per UUID without affecting a second simulator',"ios.ui.choices.input==='native'&&otherIOS.ui.choices.input==='current'&&otherIOS.ui.choices.capture==='current'");
 await ev("localStorage.setItem('simwisp.ios-input.v1:copy-ios-other','auto');otherIOS.ui.destroy();otherIOS.pill.remove();otherIOS=make('ios','copy-ios-other')");
 await check('Unknown iOS input preference normalizes to Quartz, never Android Auto',"otherIOS.ui.choices.input==='current'");
 await ev("otherIOS.ui.destroy();otherIOS.pill.remove();localStorage.setItem('simwisp.ios-input.v1:copy-headless','current');localStorage.setItem('simwisp.ios-capture.v1:copy-headless','current');const h=document.createElement('button');h.textContent='Headless fixture';document.body.append(h);window.headlessTrigger=h;window.headlessUI=new ios.ui.constructor(h,'Headless','copy-headless',()=>{}, {headless:true});window.headlessMenu=document.getElementById(h.getAttribute('aria-controls'))");
 await check('Headless picker overrides capture/input without storing either',"headlessUI.choices.capture==='native'&&headlessUI.choices.input==='native'&&localStorage.getItem('simwisp.ios-input.v1:copy-headless')==='current'&&localStorage.getItem('simwisp.ios-capture.v1:copy-headless')==='current'&&[...headlessMenu.querySelectorAll('[data-choice=current]')].every(b=>b.disabled)");
 await ev("headlessUI.destroy();headlessTrigger.remove()");
 await check('No product socket or capture client created',"unexpectedSockets===0");
 await ev("for(const v of [ios,android,phone]){v.ui.destroy();v.pill.remove()}");
 await check('Popup teardown removes all three menus',"document.querySelectorAll('.backend-popover').length===0");
 if(exceptions.length)throw Error('Browser exceptions');checks.push({name:'No browser exceptions',passed:true});passed=true;
}catch(e){error=String(e);process.exitCode=1}
finally{
 if(ws?.readyState===1){try{await cdp('Browser.close')}catch{}ws.close()}
 for(const p of pending.values())clearTimeout(p.timer);
 if(chrome?.exitCode===null){try{process.kill(-chrome.pid,'SIGTERM')}catch{}await Promise.race([new Promise(r=>chrome.once('exit',r)),sleep(2000)])}
 server.closeAllConnections();await new Promise(r=>server.close(r));
 fs.rmSync(scratch,{recursive:true,force:true,maxRetries:10,retryDelay:100});
 const report={passed,error,checks,exceptions,componentOnly:true,realCapture:false,realInput:false,appRestarted:false};
 if(process.env.TEST_OUTPUT){fs.mkdirSync(process.env.TEST_OUTPUT,{recursive:true});fs.writeFileSync(path.join(process.env.TEST_OUTPUT,'backend-copy-review.json'),JSON.stringify(report,null,2))}
 console.log(JSON.stringify({passed,checks:checks.length,exceptions:exceptions.length,error}));
}
