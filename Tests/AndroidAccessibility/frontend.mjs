import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn } from 'node:child_process';
import assert from 'node:assert/strict';

// Owned headless browser + fake loopback API only. Never connects to Simwisp/ADB.
const root = process.cwd(), scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'simwisp-a11y-ui-'));
const initial = { talkback: false, text_size: true, bold_font: false, high_contrast: false };
const states = new Map(), requests = [], held = [], pending = new Map(), exceptions = [];
let holdReads = false, holdWrites = false, failRead = false, failWrite = false, chrome, ws, sequence = 0, checks = [], currentPhase;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const reply = (res, value, status = 200) => { res.writeHead(status, {'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value)); };

function productionWiringModule() {
  const source=fs.readFileSync(root+'/Resources/Web/js/app.js','utf8');
  const take=(startText,endText)=>{const start=source.indexOf(startText),end=source.indexOf(endText,start);assert.ok(start>=0&&end>start,'Production wiring marker');return source.slice(start,end+endText.length);};
  const pill=take('function createPill(','\n  return pill;\n}');
  const visibility=take('function updateStreamVisibility() {','\n}');
  const wiring=take('    panel.accessibilityMenu = new AndroidAccessibilityMenu(button, {','\n    });');
  return [
    "import { AndroidAccessibilityMenu } from './android-accessibility.js';",
    "import { fetchAndroidAccessibility, setAndroidAccessibility } from './api.js';",
    "import { backendIcon } from './android-backends.js';",
    "const simPanels=new Map(); const termOpen=false; const isMobileViewport=()=>false; const esc=s=>s; const setFocusedPanel=()=>{};",
    "const deviceActionMessage=(...args)=>window.wiringErrors.push(args); const openDeviceConsole=()=>{throw Error('Wrong console opened');};",
    pill,visibility,
    "export function install(udid='emulator-5554') { const panelEl=document.createElement('section');panelEl.className='sim-panel';panelEl.dataset.udid=udid;panelEl.style.cssText='position:fixed;left:12px;top:12px;width:460px;height:700px;display:flex;flex-direction:column';const stage=document.createElement('div');stage.className='sim-stage';stage.textContent='Isolated UI fixture — no real device';stage.style.cssText='display:grid;place-items:center;flex:1';const pill=createPill(udid,'Inert Android fixture','android');panelEl.append(stage,pill);document.body.append(panelEl);const panel={panelEl,pillEl:pill,accessibility:null,accessibilityMenu:null,stream:{updateSettings:v=>{window.wiringSettings.push(v);window.wiringSettingsByDevice?.set(udid,v);}}};simPanels.set(udid,panel);const button=pill.querySelector('[data-action=accessibility]');",
    wiring,
    "return {panel,button,menu:document.getElementById(button.getAttribute('aria-controls')),close:()=>{panel.accessibility?.setOpen(false);panel.accessibilityMenu.destroy();simPanels.delete(udid);panelEl.remove();}};}",
  ].join('\n');
}

const server = http.createServer(async (req,res) => {
  const url = new URL(req.url, 'http://localhost'), p = url.pathname;
  if (p.startsWith('/api/android-accessibility/')) {
    const id = decodeURIComponent(p.slice('/api/android-accessibility/'.length));
    let raw = '';for await(const part of req)raw += part;
    const change = raw ? JSON.parse(raw) : null; requests.push({method:req.method,id,change});
    if(req.method === 'GET') {
      if(failRead){reply(res,{error:'Unavailable <img src=x onerror=window.injected=true>'},503);return;}
      const value = {...states.get(id)};
      if(holdReads)held.push(()=>reply(res,value));else reply(res,value);
    } else {
      if(failWrite){reply(res,{error:'Setting not confirmed. Reopen menu.'},503);return;}
      states.get(id)[change.setting] = change.enabled;
      if(holdWrites)held.push(()=>reply(res,change));else reply(res,change);
    }
    return;
  }
  if(p === '/') { res.setHeader('Content-Type','text/html');res.end('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><link rel="stylesheet" href="/css/tokens.css"><link rel="stylesheet" href="/css/layout.css"><link rel="stylesheet" href="/css/components.css"><body style="display:block"><input id="outside" aria-label="Outside focus target"></body>');return; }
  if(p === '/js/app-wiring-fixture.js'){res.setHeader('Content-Type','text/javascript');res.end(productionWiringModule());return;}
  if(p === '/app-source.txt'){res.end(fs.readFileSync(root+'/Resources/Web/js/app.js'));return;}
  if(!/^\/(?:js|css)\/[a-z0-9.-]+\.(?:js|css)$/.test(p)){res.writeHead(404);res.end();return;}
  const file=root+'/Resources/Web'+p;if(!fs.existsSync(file)){res.writeHead(404);res.end();return;}
  res.setHeader('Content-Type',p.endsWith('.js')?'text/javascript':'text/css');res.end(fs.readFileSync(file));
});
function cdp(method,params={}) { return new Promise((resolve,reject) => {
  const id=++sequence,timer=setTimeout(()=>{pending.delete(id);reject(Error('CDP timeout '+method));},10_000);
  pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params}));
}); }
async function ev(expression) { const r=await cdp('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value; }
async function until(name,test){for(let i=0;i<600;i++){if(await test())return;await sleep(30);}throw Error('Timeout: '+name);}
async function check(name,expression){const passed=typeof expression==='string'?await ev(expression)===true:expression===true;checks.push({name,passed});if(!passed)throw Error(name);}
async function setup(){
  holdReads=holdWrites=failRead=failWrite=false;requests.length=0;held.length=0;
  for(const id of ['emulator-5554','emulator-5556'])states.set(id,{...initial});
  await ev(`(async()=>{
    for(const x of window.fixtures||[]) {x.ui.destroy();x.pill.remove();}
    const {AndroidAccessibilityMenu}=await import('/js/android-accessibility.js'), api=await import('/js/api.js'),{backendIcon}=await import('/js/android-backends.js');
    const source=await(await fetch('/app-source.txt')).text(),start=source.indexOf('function createPill('),end=source.indexOf('\\n  return pill;\\n}',start);
    if(start<0||end<0)throw Error('Production pill renderer missing');
    const createPill=new Function('backendIcon','esc','simPanels','setFocusedPanel',source.slice(start,end+17)+';return createPill;')(backendIcon,s=>s,new Map(),()=>{});
    window.consoleCalls=[];window.consoleErrors=[];window.readCalls=[];window.writeCalls=[];window.socketAttempts=0;
    window.WebSocket=class{constructor(){socketAttempts++;throw Error('No product WebSocket allowed');}};
    window.fixtures=['emulator-5554','emulator-5556'].map((id,i)=>{
      const pill=createPill(id,'Synthetic Android','android');pill.style.cssText='position:fixed;bottom:'+ (24+i*80)+'px;left:12px;width:min(460px,calc(100vw - 24px));z-index:1';document.body.append(pill);
      const trigger=pill.querySelector('[data-action="accessibility"]'),ui=new AndroidAccessibilityMenu(trigger,{
        read:()=>{readCalls.push(id);return api.fetchAndroidAccessibility(id);},
        write:(setting,enabled)=>{writeCalls.push({id,setting,enabled});return api.setAndroidAccessibility(id,setting,enabled);},
        toggleInspector:()=>consoleCalls.push(id),onError:e=>consoleErrors.push(String(e)),
      });
      return {id,pill,trigger,ui,menu:document.getElementById(trigger.getAttribute('aria-controls'))};
    });
    window.a=fixtures[0];window.b=fixtures[1];window.iosPill=createPill('00000000-0000-0000-0000-000000000001','Synthetic iOS','ios');
  })()`);
}
const open = async (who='a') => { await ev(`${who}.ui.open(true,true)`);await until(who+' snapshot',()=>ev(`${who}.menu.querySelector(".android-a11y-settings").getAttribute('aria-busy')==='false'`)); };
async function core(){
  await setup();await sleep(180);
  await check('construction has zero settings reads and no sockets','readCalls.length===0&&writeCalls.length===0&&socketAttempts===0');
  await check('only Android production pill gets A11y','!!a.trigger&&!iosPill.querySelector("[data-action=accessibility]")');
  await open();await check('one snapshot only on opening','readCalls.length===1&&readCalls[0]===a.id');
  await check('exact five actions and four semantic switches','a.menu.querySelectorAll("button").length===5&&a.menu.querySelectorAll("[role=switch]").length===4');
  await check('switches reflect snapshot','a.menu.querySelector("[data-setting=text_size]").getAttribute("aria-checked")==="true"&&[...a.menu.querySelectorAll("[data-setting]:not([data-setting=text_size])")].every(x=>x.getAttribute("aria-checked")==="false")');
  await check('no visible On/Off words or TalkBack footer','!(/\\b(?:On|Off)\\b/.test(a.menu.textContent))&&!a.menu.querySelector("footer")&&!a.menu.textContent.includes("enables only")&&!a.menu.textContent.includes("disables all")');
  for(const setting of Object.keys(initial)) {
    const before=await ev('readCalls.length'), enabled=!states.get(aId())[setting];
    await ev(`a.menu.querySelector('[data-setting=${setting}]').click()`);await until('write '+setting,()=>ev(`a.menu.querySelector(".android-a11y-settings").getAttribute('aria-busy')==='false'`));
    await check('confirmed affected-row switch '+setting,`a.menu.querySelector('[data-setting=${setting}]').getAttribute('aria-checked')==='${enabled}'`);
    await check('write has no readback '+setting,await ev('readCalls.length')===before);
    assert.deepEqual(requests.at(-1),{method:'POST',id:aId(),change:{setting,enabled}});
  }
  await check('four POSTs target only selected Android',requests.filter(x=>x.method==='POST').length===4&&requests.every(x=>x.id===aId()));
  const count=requests.length;
  await ev("a.ui.open(true,true);window.dispatchEvent(new Event('resize'));window.dispatchEvent(new Event('scroll'));a.menu.dispatchEvent(new Event('simwisp-stats'))");await sleep(1200);
  await check('open, resize, scroll, stats and idle do not poll',requests.length===count);
  await ev('a.menu.querySelector("[data-setting=talkback]").focus()');
  await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:' ',code:'Space',windowsVirtualKeyCode:32});await cdp('Input.dispatchKeyEvent',{type:'keyUp',key:' ',code:'Space',windowsVirtualKeyCode:32});
  await until('keyboard write',()=>ev('writeCalls.length===5&&a.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="false"'));
  await check('Space activates focused switch','a.menu.querySelector("[data-setting=talkback]").getAttribute("aria-checked")==="false"');
  await ev('a.menu.querySelector("[data-setting=talkback]").focus();a.menu.dispatchEvent(new KeyboardEvent("keydown",{key:"ArrowDown",bubbles:true}))');
  await check('arrow-key row navigation','document.activeElement.dataset.setting==="text_size"');
  await ev('a.menu.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true}))');
  await check('Escape closes and restores trigger focus','a.menu.hidden&&document.activeElement===a.trigger&&a.trigger.getAttribute("aria-expanded")==="false"');
  await open();await check('reopen performs exactly one new snapshot','readCalls.length===2');
  await open('b');await check('opening second device closes first, uses second selector','a.menu.hidden&&!b.menu.hidden&&readCalls.at(-1)===b.id');
  await ev('b.menu.querySelector("[data-action=show-inspector]").click()');await until('console callback',()=>ev('consoleCalls.length===1'));
  await check('fifth row invokes only selected console and closes menu','b.menu.hidden&&consoleCalls[0]===b.id&&socketAttempts===0');
  await open();await ev('document.getElementById("outside").focus()');await check('outside focus dismisses menu','a.menu.hidden');
  await open();await ev('document.body.dispatchEvent(new PointerEvent("pointerdown",{bubbles:true}))');await check('outside pointer dismisses menu','a.menu.hidden');
}
function aId(){return 'emulator-5554';}
async function lifecycle(){
  await setup();failRead=true;await open();
  await check('read failure disables switches and renders safe text','[...a.menu.querySelectorAll("[data-setting]")].every(x=>x.disabled)&&a.menu.textContent.includes("<img")&&!a.menu.querySelector("img")&&!window.injected');
  const count=requests.length;await sleep(400);await check('failed reads never auto-retry',requests.length===count);
  failRead=false;await ev('a.ui.open(false)');await open();
  failWrite=true;const before=requests.length;await ev('a.menu.querySelector("[data-setting=bold_font]").click()');await until('write failure',()=>ev('a.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="false"'));
  await check('write failure leaves affected state unavailable','a.menu.querySelector("[data-setting=bold_font]").disabled&&a.menu.querySelector(".error").textContent.includes("not confirmed")');
  await check('write failure makes no automatic read request',requests.length===before+1&&requests.at(-1).method==='POST');
  failWrite=false;await ev('a.ui.open(false)');await open();await check('explicit reopen recovers state','!a.menu.querySelector("[data-setting=bold_font]").disabled');
  await ev('a.ui.open(false)');holdReads=true;states.set(aId(),Object.fromEntries(Object.keys(initial).map(k=>[k,false])));
  await ev('a.ui.open(true,true)');await until('held old read',()=>held.length===1);
  await ev('a.ui.open(false)');states.set(aId(),Object.fromEntries(Object.keys(initial).map(k=>[k,true])));
  await ev('a.ui.open(true,true)');await until('held new read',()=>held.length===2);held[1]();await until('new read committed',()=>ev('a.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="false"'));
  held[0]();await sleep(150);holdReads=false;held.length=0;
  await check('older response cannot overwrite reopened menu','[...a.menu.querySelectorAll("[data-setting]")].every(x=>x.getAttribute("aria-checked")==="true")');
  holdWrites=true;await ev('a.menu.querySelector("[data-setting=talkback]").click()');await until('held write',()=>held.length===1);
  await check('pending write prevents duplicate mutations','[...a.menu.querySelectorAll("[data-setting]")].every(x=>x.disabled)');
  await ev('a.ui.open(false);a.ui.open(true,true)');await until('reopen while write pending',()=>requests.at(-1)?.method==='GET');
  held[0]();held.length=0;holdWrites=false;await until('old write settled',()=>ev('a.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="false"'));
  await check('late write completion respects fresh snapshot','a.menu.querySelector("[data-setting=talkback]").getAttribute("aria-checked")==="false"&&!a.menu.querySelector("[data-setting=talkback]").disabled');
  await ev('a.ui.open(false)');holdReads=true;await ev('b.ui.open(true,true)');await until('read before disposal',()=>held.length===1);await ev('b.ui.destroy()');held[0]();held.length=0;holdReads=false;await sleep(100);
  await check('destroy ignores in-flight response and removes detached menu','!b.menu.isConnected&&b.trigger.getAttribute("aria-expanded")==="false"');
  await ev('a.ui.destroy();a.trigger.click()');await sleep(80);await check('destroy removes listeners and all menus','document.querySelectorAll(".android-accessibility-menu").length===0&&socketAttempts===0');
}
async function layout(){
  await setup();
  for(const [width,height] of [[320,568],[390,844],[1024,768],[1280,800],[568,320]]) {
    await cdp('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:false});await open();
    await check('upward menu fits '+width+'x'+height,'(()=>{const r=a.menu.getBoundingClientRect(),t=a.trigger.getBoundingClientRect();return r.left>=0&&r.top>=0&&r.right<=innerWidth+1&&r.bottom<=t.top+1&&r.bottom<=innerHeight+1})()');
    await check('all switches have usable hit targets '+width+'x'+height,'[...a.menu.querySelectorAll("[data-setting]")].every(x=>x.getBoundingClientRect().height>=44)');
    await ev('a.ui.open(false)');
  }
  await cdp('Emulation.setDeviceMetricsOverride',{width:1024,height:768,deviceScaleFactor:1,mobile:false});
  for(const theme of ['light','dark']){await ev(`document.documentElement.dataset.theme='${theme}'`);await open();await check('theme tokens apply '+theme,'getComputedStyle(a.menu).backgroundColor===getComputedStyle(document.documentElement).getPropertyValue("--bg-elevated").trim()||getComputedStyle(a.menu).backgroundColor!=="rgba(0, 0, 0, 0)"');if(process.env.TEST_OUTPUT){const shot=await cdp('Page.captureScreenshot',{format:'png'});fs.writeFileSync(path.join(process.env.TEST_OUTPUT,'android-a11y-'+theme+'.png'),Buffer.from(shot.data,'base64'));}await ev('a.ui.open(false)');}
}

async function wiring(){
  await setup();await ev("for(const f of fixtures){f.ui.destroy();f.pill.remove();}window.wiringErrors=[];window.wiringSettings=[];");
  await ev("(async()=>{const module=await import('/js/app-wiring-fixture.js');window.wired=module.install();})()");
  await check('production wiring does not read settings or create inspector at startup','readCalls.length===0&&wiringSettings.length===0&&!document.querySelector(".accessibility-pane")');
  const before=requests.length;await ev('wired.button.click()');await until('wired menu snapshot',()=>ev('!wired.menu.hidden&&wired.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="false"'));
  await check('production A11y trigger opens menu, not inspector','!wired.menu.hidden&&!document.querySelector(".accessibility-pane")&&wired.button.getAttribute("aria-expanded")==="true"');
  await check('production menu read targets its own selected serial',requests.length===before+1&&requests.at(-1).method==='GET'&&requests.at(-1).id==='emulator-5554');
  await check('settings menu alone does not subscribe to logcat','wiringSettings.length===0');
  await check('fifth row clearly identifies existing TalkBack inspector','wired.menu.querySelector("[data-action=show-inspector]").textContent.trim()==="Show TalkBack inspector"&&!wired.menu.textContent.includes("RN console")');
  await ev('wired.panel.accessibilityMenu.inspectorButton.click()');await until('lazy existing inspector',()=>ev('wired.panel.accessibility?.isOpen===true'));
  await check('fifth row uses actual AccessibilityPane without duplicate activation','wired.menu.hidden&&document.querySelectorAll(".accessibility-pane").length===1&&wired.panel.accessibility.isOpen');
  await check('only explicit inspector open subscribes to accessibility stream','wiringSettings.length===1&&wiringSettings[0].accessibility_enabled===true');
  await check('inspector open does not issue settings reads',requests.length===before+1);
  await check('trigger keeps menu semantics after inspector creation','wired.button.getAttribute("aria-controls")===wired.menu.id&&wired.button.getAttribute("aria-expanded")==="false"');
  await ev('wired.panel.accessibility.receive({type:"accessibility_event",subscription:wired.panel.accessibility.subscription,node:{speech:"Synthetic TalkBack speech"}})');
  await check('existing inspector receives speech through unchanged subscription','document.querySelector(".a11y-speech").textContent==="Synthetic TalkBack speech"');
  await ev('wired.button.click()');await until('menu while inspector open',()=>ev('!wired.menu.hidden&&wired.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="false"'));
  await ev('wired.panel.accessibilityMenu.inspectorButton.click()');await sleep(80);
  await check('Hide action closes the existing inspector without duplicating it','document.querySelectorAll(".accessibility-pane").length===1&&!wired.panel.accessibility.isOpen&&wiringSettings.length===2&&wiringSettings.at(-1).accessibility_enabled===false');
  await ev('wired.button.click()');await until('reopen menu after Hide',()=>ev('!wired.menu.hidden&&wired.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="false"'));
  await ev('wired.panel.accessibilityMenu.inspectorButton.click()');await until('Show reopens existing inspector',()=>ev('wired.panel.accessibility.isOpen'));
  await ev('document.querySelector(".a11y-close").click()');
  await check('inspector close stops subscription and restores A11y trigger focus','!wired.panel.accessibility.isOpen&&wiringSettings.at(-1).accessibility_enabled===false&&document.activeElement===wired.button&&wired.menu.hidden');
  await ev('wired.button.click()');await until('wired menu teardown fixture',()=>ev('!wired.menu.hidden&&wired.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="false"'));await ev('wired.close()');
  await check('production integration teardown removes menu and inspector','!wired.menu.isConnected&&!document.querySelector(".accessibility-pane")&&socketAttempts===0&&wiringErrors.length===0');
  await check('app panel removal and pagehide explicitly destroy controllers','(async()=>{const source=await(await fetch("/app-source.txt")).text();return source.includes("panel.accessibilityMenu?.destroy();")&&source.includes("p.accessibilityMenu?.destroy();")})()');
}


// Oct23 follow-up only: held fake requests expose the real production loading UI.
async function feedbackLoading(){
  await setup();holdReads=true;await ev('a.ui.open(true,true)');await until('feedback held read',()=>held.length===1);
  await check('loading has no Reading current settings text or footer','!a.menu.textContent.includes("Reading current settings")&&a.menu.querySelector(".android-a11y-request-status").textContent===""');
  await check('activity indicator is visible and named while reading','!a.menu.querySelector(".android-a11y-loading").hidden&&getComputedStyle(a.menu.querySelector(".spinner")).animationName!=="none"&&a.menu.querySelector(".android-a11y-loading").getAttribute("aria-label")==="Loading accessibility settings"');
  await check('pending popup contents are blurred and inert','a.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="true"&&a.menu.querySelector(".android-a11y-content").inert&&getComputedStyle(a.menu.querySelector(".android-a11y-content")).filter.includes("blur(")');
  await check('spinner stays sharp outside the blurred contents','getComputedStyle(a.menu.querySelector(".android-a11y-loading")).filter==="none"&&!a.menu.querySelector(".android-a11y-content").contains(a.menu.querySelector(".spinner"))');
  await ev('a.menu.querySelector("[data-setting=talkback]").click();a.menu.dispatchEvent(new KeyboardEvent("keydown",{key:"ArrowDown",bubbles:true}));a.ui.inspectorButton.focus()');
  await check('busy switches reject writes but inspector accepts keyboard focus','consoleCalls.length===0&&writeCalls.length===0&&!a.menu.hidden&&document.activeElement===a.ui.inspectorButton');
  for(const [width,height,theme]of [[320,568,'light'],[1024,768,'dark']]){
    await cdp('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:false});await ev('document.documentElement.dataset.theme='+JSON.stringify(theme));
    await ev('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
    await check('busy popup and centered overlay fit '+width+'x'+height,'(()=>{const r=a.menu.getBoundingClientRect(),o=a.menu.querySelector(".android-a11y-loading").getBoundingClientRect(),s=a.menu.querySelector(".spinner").getBoundingClientRect(),t=a.trigger.getBoundingClientRect(),g=a.menu.querySelector(".android-a11y-settings").getBoundingClientRect();return r.top>=0&&r.left>=0&&r.right<=innerWidth+1&&r.bottom<=t.top+1&&Math.abs(o.width-g.width)<=1&&Math.abs(o.height-g.height)<=1&&Math.abs(s.left+s.width/2-(o.left+o.width/2))<=1&&Math.abs(s.top+s.height/2-(o.top+o.height/2))<=1})()');
    if(process.env.TEST_OUTPUT){const shot=await cdp('Page.captureScreenshot',{format:'png'});fs.writeFileSync(path.join(process.env.TEST_OUTPUT,'loading-'+theme+'.png'),Buffer.from(shot.data,'base64'));}
  }
  await cdp('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'reduce'}]});
  await check('loading respects reduced motion without hiding indicator','getComputedStyle(a.menu.querySelector(".spinner")).animationName==="none"&&!a.menu.querySelector(".android-a11y-loading").hidden');
  await cdp('Emulation.setEmulatedMedia',{features:[]});await ev('document.documentElement.dataset.theme="light"');
  held.shift()();holdReads=false;await until('feedback read settled',()=>ev('a.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="false"'));
  await check('read completion unblurs and enables contents','a.menu.querySelector(".android-a11y-loading").hidden&&!a.menu.querySelector(".android-a11y-content").inert&&getComputedStyle(a.menu.querySelector(".android-a11y-content")).filter==="none"&&[...a.menu.querySelectorAll("[data-setting]")].every(x=>!x.disabled)');
  await check('read completion preserves inspector focus chosen while loading','document.activeElement===a.ui.inspectorButton');
  holdWrites=true;await ev('a.menu.querySelector("[data-setting=bold_font]").focus();a.menu.querySelector("[data-setting=bold_font]").click()');await until('feedback held write',()=>held.length===1);
  await check('writes use the same noninteractive activity overlay','!a.menu.hidden&&!a.menu.querySelector(".android-a11y-loading").hidden&&a.menu.querySelector(".android-a11y-content").inert&&a.menu.querySelector(".android-a11y-loading").getAttribute("aria-label")==="Updating accessibility settings"&&document.activeElement===a.menu');
  await ev('a.menu.querySelector("[data-setting=high_contrast]").click()');
  await check('pending write rejects duplicate settings but leaves inspector enabled','consoleCalls.length===0&&writeCalls.length===1&&!a.ui.inspectorButton.disabled&&!a.ui.inspectorButton.closest("[inert]")');
  held.shift()();holdWrites=false;await until('feedback write settled',()=>ev('a.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="false"'));
  await check('write completion restores affected-row focus and state','a.menu.querySelector(".android-a11y-loading").hidden&&!a.menu.querySelector(".android-a11y-content").inert&&document.activeElement.dataset.setting==="bold_font"&&document.activeElement.getAttribute("aria-checked")==="true"');
  await check('overlay introduces no extra settings read or write',requests.length===2&&requests[0].method==='GET'&&requests[1].method==='POST');
  failWrite=true;await ev('a.menu.querySelector("[data-setting=high_contrast]").click()');await until('feedback failed write',()=>ev('a.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="false"'));
  await check('failed write dismisses overlay and reveals recovery error','a.menu.querySelector(".android-a11y-loading").hidden&&!a.menu.querySelector(".android-a11y-content").inert&&a.menu.querySelector(".error").textContent.includes("not confirmed")&&a.menu.querySelector("[data-setting=high_contrast]").disabled');
  failWrite=false;failRead=true;await ev('a.ui.open(false)');await open();
  await check('failed read dismisses overlay and reveals safe error','a.menu.querySelector(".android-a11y-loading").hidden&&!a.menu.querySelector(".android-a11y-content").inert&&getComputedStyle(a.menu.querySelector(".error")).display!=="none"&&!a.menu.querySelector("img")');
  failRead=false;holdReads=true;await ev('a.ui.open(false);a.ui.open(true,true)');await until('feedback old pending read',()=>held.length===1);
  await ev('a.ui.open(false);a.ui.open(true,true)');await until('feedback new pending read',()=>held.length===2);
  held.shift()();await sleep(100);
  await check('stale response cannot clear current busy overlay','a.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="true"&&!a.menu.querySelector(".android-a11y-loading").hidden&&a.menu.querySelector(".android-a11y-content").inert');
  held.shift()();holdReads=false;await until('feedback current read settled',()=>ev('a.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="false"'));
  await check('current response clears its own overlay','a.menu.querySelector(".android-a11y-loading").hidden&&!a.menu.querySelector(".android-a11y-content").inert');
  holdReads=true;await ev('a.ui.open(false);a.ui.open(true,true)');await until('feedback pending Escape',()=>held.length===1);
  await ev('a.menu.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true}))');
  await check('Escape still dismisses busy popup and restores trigger','a.menu.hidden&&document.activeElement===a.trigger');
  held.shift()();holdReads=false;await sleep(100);const count=requests.length;await sleep(350);
  await check('dismissed response never reopens or polls','a.menu.hidden&&socketAttempts===0');await check('busy overlay is event-driven without retry',requests.length===count);
}
async function feedbackInspector(){
  await setup();await ev('for(const f of fixtures){f.ui.destroy();f.pill.remove();}window.wiringErrors=[];window.wiringSettings=[];window.wiringSettingsByDevice=new Map();');
  await ev('(async()=>{const module=await import("/js/app-wiring-fixture.js");window.wired=module.install();window.otherWired=module.install("emulator-5556");})()');
  await check('closed inspectors begin with independent Show labels','wired.panel.accessibilityMenu.inspectorButton.textContent.trim()==="Show TalkBack inspector"&&otherWired.panel.accessibilityMenu.inspectorButton.textContent.trim()==="Show TalkBack inspector"');
  await ev('wired.button.click()');await until('feedback Show menu',()=>ev('!wired.menu.hidden&&wired.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="false"'));
  await ev('wired.panel.accessibilityMenu.inspectorButton.click()');await until('feedback inspector opens',()=>ev('wired.panel.accessibility?.isOpen===true'));
  await ev('window.originalInspector=wired.panel.accessibility;window.firstSubscription=wired.panel.accessibility.subscription');
  await check('actual inspector opening changes action to Hide immediately','wired.panel.accessibilityMenu.inspectorButton.textContent.trim()==="Hide TalkBack inspector"&&wired.menu.hidden');
  await check('visibility state is device-scoped','otherWired.panel.accessibilityMenu.inspectorButton.textContent.trim()==="Show TalkBack inspector"&&!otherWired.panel.accessibility');
  await check('other device remains unsubscribed while first inspector is visible','wiringSettingsByDevice.get("emulator-5556").accessibility_enabled===false');
  await ev('wired.button.click()');await until('feedback visible Hide action',()=>ev('!wired.menu.hidden&&wired.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="false"'));
  await check('open popup shows Hide while inspector is visible','!wired.panel.accessibility.el.hidden&&wired.panel.accessibilityMenu.inspectorButton.textContent.trim()==="Hide TalkBack inspector"');
  if(process.env.TEST_OUTPUT){const shot=await cdp('Page.captureScreenshot',{format:'png'});fs.writeFileSync(path.join(process.env.TEST_OUTPUT,'inspector-hide.png'),Buffer.from(shot.data,'base64'));}
  await ev('wired.panel.accessibilityMenu.inspectorButton.click()');await until('feedback Hide toggles closed',()=>ev('!wired.panel.accessibility.isOpen'));
  await check('Hide action closes pane and changes label back to Show','wired.panel.accessibility.el.hidden&&wired.menu.hidden&&wired.panel.accessibilityMenu.inspectorButton.textContent.trim()==="Show TalkBack inspector"');
  await check('Hide stops subscription and returns focus','wiringSettingsByDevice.get("emulator-5554").accessibility_enabled===false&&document.activeElement===wired.button');
  await ev('wired.button.click()');await until('feedback Show again menu',()=>ev('!wired.menu.hidden&&wired.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="false"'));
  await ev('wired.panel.accessibilityMenu.inspectorButton.click()');await until('feedback Show again opens',()=>ev('wired.panel.accessibility.isOpen'));
  await check('Show reuses existing inspector with a fresh subscription','wired.panel.accessibility===originalInspector&&document.querySelectorAll(".accessibility-pane").length===1&&wired.panel.accessibility.subscription>firstSubscription&&wiringSettingsByDevice.get("emulator-5554").accessibility_enabled===true');
  await ev('wired.panel.accessibility.el.querySelector(".a11y-close").click()');
  await check('pane close control also restores Show label','!wired.panel.accessibility.isOpen&&wired.panel.accessibilityMenu.inspectorButton.textContent.trim()==="Show TalkBack inspector"&&document.activeElement===wired.button');
  const before=requests.length;await ev('wired.panel.accessibility.setOpen(true)');
  await check('external visibility event changes action to Hide','wired.panel.accessibilityMenu.inspectorButton.textContent.trim()==="Hide TalkBack inspector"');
  await ev('wired.panel.accessibility.setOpen(false)');
  await check('external close event changes action to Show','wired.panel.accessibilityMenu.inspectorButton.textContent.trim()==="Show TalkBack inspector"');
  await check('visibility events never reread device settings',requests.length===before);
  await ev('wired.panel.accessibility.setOpen(true)');holdReads=true;await ev('wired.button.click()');await until('feedback inspector pending menu',()=>held.length===1);
  await ev('wired.panel.accessibility.el.querySelector(".a11y-close").click()');
  await check('inspector closing during menu load updates clear action','wired.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="true"&&wired.panel.accessibilityMenu.inspectorButton.textContent.trim()==="Show TalkBack inspector"');
  held.shift()();holdReads=false;await until('feedback inspector menu settled',()=>ev('wired.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy")==="false"'));
  await check('loaded menu keeps current inspector visibility, not stale state','wired.panel.accessibilityMenu.inspectorButton.textContent.trim()==="Show TalkBack inspector"&&!wired.panel.accessibility.isOpen');
  const count=requests.length;await sleep(350);await check('inspector label updates have no polling or setting writes',requests.length===count&&requests.every(r=>r.method==='GET'));
  await ev('wired.close();otherWired.close()');
  await check('follow-up controllers tear down without sockets or errors','!document.querySelector(".android-accessibility-menu")&&!document.querySelector(".accessibility-pane")&&socketAttempts===0&&wiringErrors.length===0');
}


// Only the four remote settings depend on the asynchronous snapshot/mutation.
async function switchRegion(){
  await setup();await ev('for(const f of fixtures){f.ui.destroy();f.pill.remove();}window.wiringErrors=[];window.wiringSettings=[];');
  await ev('(async()=>{const module=await import("/js/app-wiring-fixture.js");window.wired=module.install();})()');
  holdReads=true;await ev('wired.button.click();window.settingsRegion=wired.menu.querySelector(".android-a11y-settings");window.settingsContents=wired.menu.querySelector(".android-a11y-content");window.activityOverlay=wired.menu.querySelector(".android-a11y-loading");window.inspectorAction=wired.panel.accessibilityMenu.inspectorButton;window.instantInspectorReady=!wired.menu.hidden&&!inspectorAction.disabled&&!inspectorAction.closest("[inert]")&&inspectorAction.textContent.trim()==="Show TalkBack inspector";');
  await check('inspector action is ready synchronously on menu open','instantInspectorReady');
  await until('switch-region held read',()=>held.length===1);
  await check('busy region contains exactly the four settings, not header or inspector','settingsRegion.querySelectorAll("button").length===4&&settingsRegion.querySelectorAll("[role=switch]").length===4&&!settingsRegion.contains(inspectorAction)&&!settingsRegion.contains(wired.menu.querySelector("header"))');
  await check('ARIA busy applies to settings only, not whole popup','settingsRegion.getAttribute("aria-busy")==="true"&&!wired.menu.hasAttribute("aria-busy")');
  await check('only switch contents are blurred and inert','settingsContents.inert&&getComputedStyle(settingsContents).filter.includes("blur(")&&getComputedStyle(wired.menu).filter==="none"&&getComputedStyle(wired.menu.querySelector("header")).filter==="none"&&!inspectorAction.closest("[inert]")');
  await ev('wired.menu.querySelector("[data-setting=talkback]").click()');await check('pending settings still reject mutations',requests.every(r=>r.method==='GET'));
  for(const[width,height,theme]of [[320,568,'light'],[1024,768,'dark']]){
    await cdp('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:false});await ev('wired.panel.panelEl.style.width=Math.min(innerWidth-24,460)+"px";wired.panel.panelEl.style.height=Math.min(innerHeight-24,700)+"px";document.documentElement.dataset.theme='+JSON.stringify(theme));
    await ev('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
    await check('spinner covers and centers on switches only '+theme,'(()=>{const g=settingsRegion.getBoundingClientRect(),o=activityOverlay.getBoundingClientRect(),s=activityOverlay.querySelector(".spinner").getBoundingClientRect(),h=wired.menu.querySelector("header").getBoundingClientRect(),b=inspectorAction.getBoundingClientRect();return !activityOverlay.hidden&&Math.abs(g.x-o.x)<1&&Math.abs(g.y-o.y)<1&&Math.abs(g.width-o.width)<1&&Math.abs(g.height-o.height)<1&&Math.abs(s.x+s.width/2-g.x-g.width/2)<1&&Math.abs(s.y+s.height/2-g.y-g.height/2)<1&&o.top>=h.bottom-1&&o.bottom<=b.top+1})()');
    await check('inspector row remains pointer reachable during load '+theme,'(()=>{const r=inspectorAction.getBoundingClientRect();return inspectorAction.contains(document.elementFromPoint(r.x+r.width/2,r.y+r.height/2))})()');
    if(process.env.TEST_OUTPUT){const shot=await cdp('Page.captureScreenshot',{format:'png'});fs.writeFileSync(path.join(process.env.TEST_OUTPUT,'switches-loading-'+theme+'.png'),Buffer.from(shot.data,'base64'));}
  }
  await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:'End',code:'End',windowsVirtualKeyCode:35});await cdp('Input.dispatchKeyEvent',{type:'keyUp',key:'End',code:'End',windowsVirtualKeyCode:35});
  await check('keyboard can reach inspector while settings are loading','document.activeElement===inspectorAction');
  async function pointerInspector(){const p=await ev('(()=>{const r=inspectorAction.getBoundingClientRect();return{x:r.x+r.width/2,y:r.y+r.height/2}})()');await cdp('Input.dispatchMouseEvent',{type:'mousePressed',...p,button:'left',clickCount:1});await cdp('Input.dispatchMouseEvent',{type:'mouseReleased',...p,button:'left',clickCount:1});}
  await pointerInspector();await until('Show before settings return',()=>ev('wired.panel.accessibility?.isOpen===true'));
  await check('pointer Show opens actual pane before pending GET resolves','wired.menu.hidden&&wired.panel.accessibility.isOpen&&inspectorAction.textContent.trim()==="Hide TalkBack inspector"');
  await check('inspector Show only subscribes; does not add settings requests',held.length===1&&requests.length===1&&await ev('wiringSettings.at(-1).accessibility_enabled===true'));
  held.shift()();await sleep(80);await check('late closed-menu snapshot does not affect inspector','wired.menu.hidden&&wired.panel.accessibility.isOpen');
  await ev('wired.button.click()');await until('Hide during held snapshot',()=>held.length===1);
  await check('Hide label is available while new settings snapshot is pending','settingsRegion.getAttribute("aria-busy")==="true"&&inspectorAction.textContent.trim()==="Hide TalkBack inspector"&&!inspectorAction.disabled&&!inspectorAction.closest("[inert]")');
  await ev('wired.panel.accessibility.receive({type:"accessibility_event",subscription:wired.panel.accessibility.subscription,node:{speech:"Synthetic TalkBack speech — independent of settings loading"}})');
  if(process.env.TEST_OUTPUT){const shot=await cdp('Page.captureScreenshot',{format:'png'});fs.writeFileSync(path.join(process.env.TEST_OUTPUT,'switches-loading-hide.png'),Buffer.from(shot.data,'base64'));}
  await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:'End',code:'End',windowsVirtualKeyCode:35});await cdp('Input.dispatchKeyEvent',{type:'keyUp',key:'End',code:'End',windowsVirtualKeyCode:35});
  await check('open inspector action keeps keyboard focus during pending read','!wired.menu.hidden&&document.activeElement===inspectorAction');
  await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13,text:'\r'});await cdp('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});await until('keyboard Hide before settings return',()=>ev('!wired.panel.accessibility.isOpen'));
  await check('keyboard Hide closes pane before GET resolves','wired.menu.hidden&&inspectorAction.textContent.trim()==="Show TalkBack inspector"&&wiringSettings.at(-1).accessibility_enabled===false');
  await check('Hide does not consume or retry pending GET',held.length===1&&requests.length===2);
  held.shift()();holdReads=false;await sleep(80);
  await ev('wired.button.click()');await until('settings available for pending write',()=>ev('settingsRegion.getAttribute("aria-busy")==="false"'));
  holdWrites=true;await ev('wired.menu.querySelector("[data-setting=bold_font]").focus();wired.menu.querySelector("[data-setting=bold_font]").click()');await until('switch-region held write',()=>held.length===1);
  await check('write blocks switches without blocking inspector','settingsRegion.getAttribute("aria-busy")==="true"&&settingsContents.inert&&[...settingsRegion.querySelectorAll("button")].every(b=>b.disabled)&&!inspectorAction.disabled&&!inspectorAction.closest("[inert]")');
  await pointerInspector();await until('Show before write acknowledgement',()=>ev('wired.panel.accessibility.isOpen'));
  await check('Show works while mutation acknowledgement is pending','wired.menu.hidden&&inspectorAction.textContent.trim()==="Hide TalkBack inspector"');
  await ev('wired.button.click()');await pointerInspector();await until('Hide before write acknowledgement',()=>ev('!wired.panel.accessibility.isOpen'));
  await check('Hide also works while mutation acknowledgement is pending',held.length===1&&await ev('wired.menu.hidden&&inspectorAction.textContent.trim()==="Show TalkBack inspector"'));
  held.shift()();holdWrites=false;await sleep(100);const count=requests.length;await sleep(250);
  await check('inspector actions do not produce mutations or automatic readbacks',requests.length===count&&requests.filter(r=>r.method==='POST').length===1&&requests.every(r=>r.id==='emulator-5554'));
  await ev('wired.button.click()');await until('fresh reopen after pending operations',()=>ev('settingsRegion.getAttribute("aria-busy")==="false"'));
  await check('fresh snapshot restores switches without stealing inspector state','!settingsContents.inert&&activityOverlay.hidden&&wired.menu.querySelector("[data-setting=bold_font]").getAttribute("aria-checked")==="true"&&inspectorAction.textContent.trim()==="Show TalkBack inspector"');
  await ev('wired.panel.accessibilityMenu.open(false)');failRead=true;await ev('wired.button.click()');await until('independent inspector with unavailable settings',()=>ev('settingsRegion.getAttribute("aria-busy")==="false"'));
  await check('settings errors leave inspector available','[...settingsRegion.querySelectorAll("button")].every(b=>b.disabled)&&!inspectorAction.disabled&&!inspectorAction.closest("[inert]")&&wired.menu.querySelector(".error").textContent.length>0');
  await pointerInspector();await until('inspector usable despite settings error',()=>ev('wired.panel.accessibility.isOpen'));await check('inspector opens despite failed settings snapshot','wired.menu.hidden&&inspectorAction.textContent.trim()==="Hide TalkBack inspector"');
  await ev('wired.close()');await check('switch-region fixture tears down without product connections','!document.querySelector(".android-accessibility-menu")&&!document.querySelector(".accessibility-pane")&&socketAttempts===0&&wiringErrors.length===0');
}

let failed=false;
try {
  assert.equal(process.platform,'darwin');assert.ok(fs.existsSync('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'));
  if(process.env.TEST_OUTPUT)fs.mkdirSync(process.env.TEST_OUTPUT,{recursive:true});
  await new Promise(r=>server.listen(0,'127.0.0.1',r));
  chrome=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new','--disable-gpu','--remote-debugging-address=127.0.0.1','--remote-debugging-port=0','--user-data-dir='+scratch,'--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-sync','--disable-extensions','about:blank'],{stdio:['ignore','ignore',fs.openSync(path.join(process.env.TEST_OUTPUT||scratch,'chrome-stderr.log'),'a')],detached:true});
  await until('owned Chrome',()=>fs.existsSync(scratch+'/DevToolsActivePort'));
  const port=fs.readFileSync(scratch+'/DevToolsActivePort','utf8').split('\n')[0],tabs=await(await fetch('http://127.0.0.1:'+port+'/json/list')).json();
  ws=new WebSocket(tabs.find(t=>t.type==='page').webSocketDebuggerUrl);await new Promise((r,j)=>{ws.addEventListener('open',r,{once:true});ws.addEventListener('error',j,{once:true});});
  ws.addEventListener('message',e=>{const m=JSON.parse(e.data);if(m.id&&pending.has(m.id)){const p=pending.get(m.id);pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result);}else if(m.method==='Runtime.exceptionThrown')exceptions.push(m.params);});
  await cdp('Runtime.enable');await cdp('Page.enable');await cdp('Emulation.setDeviceMetricsOverride',{width:1280,height:800,deviceScaleFactor:1,mobile:false});await cdp('Page.navigate',{url:'http://127.0.0.1:'+server.address().port});await until('page',()=>ev('document.readyState==="complete"'));
  for(const [phase,run] of Object.entries({core,lifecycle,layout,wiring,feedbackLoading,feedbackInspector,switchRegion})) {
    if(process.env.ANDROID_A11Y_UI_PHASE&&process.env.ANDROID_A11Y_UI_PHASE!==phase)continue;
    currentPhase=phase;checks=[];const beforeExceptions=exceptions.length;
    try{await run();await check('no browser exceptions',exceptions.length===beforeExceptions);if(process.env.TEST_OUTPUT)fs.writeFileSync(path.join(process.env.TEST_OUTPUT,'ui-'+phase+'.json'),JSON.stringify({passed:true,checks,fakeAPI:true,productService:false},null,2));console.log('Android accessibility '+phase+': '+checks.length+' checks PASS');}
    catch(error){if(process.env.TEST_OUTPUT)fs.writeFileSync(path.join(process.env.TEST_OUTPUT,'ui-'+phase+'-failure.json'),JSON.stringify({passed:false,error:String(error),checks,exceptions,requests,held:held.length,ui:await ev('({wiredState:window.wired&&{hidden:wired.menu.hidden,inspectorOpen:wired.panel.accessibility?.isOpen,buttonDisabled:wired.panel.accessibilityMenu.inspectorButton.disabled,focus:document.activeElement?.outerHTML?.slice(0,160)},reads:readCalls,writes:writeCalls,hidden:a.menu.hidden,busy:a.menu.querySelector(".android-a11y-settings").getAttribute("aria-busy"),menuRect:a.menu.getBoundingClientRect().toJSON(),triggerRect:a.trigger.getBoundingClientRect().toJSON(),overlayRect:a.menu.querySelector(".android-a11y-loading")?.getBoundingClientRect().toJSON(),spinnerRect:a.menu.querySelector(".spinner")?.getBoundingClientRect().toJSON()})')},null,2));throw error;}
  }
}catch(error){failed=true;console.error('Android accessibility UI failed ('+currentPhase+'): '+String(error));process.exitCode=1;}
finally{
  for(const release of held.splice(0))try{release();}catch{}
  if(ws?.readyState===1){try{await cdp('Browser.close');}catch{}ws.close();}
  for(const p of pending.values())clearTimeout(p.timer);
  if(chrome?.exitCode===null){try{process.kill(-chrome.pid,'SIGTERM');}catch{}await Promise.race([new Promise(r=>chrome.once('exit',r)),sleep(2000)]);}
  server.closeAllConnections();await new Promise(r=>server.close(r));fs.rmSync(scratch,{recursive:true,force:true,maxRetries:10,retryDelay:100});
}
