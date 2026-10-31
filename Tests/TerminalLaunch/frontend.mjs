import fs from 'node:fs';import assert from 'node:assert/strict';
const output=process.argv[2],checks=[];
function check(name,value){assert.ok(value,name);checks.push({name,passed:true});}
const source=fs.readFileSync('Resources/Web/js/terminal.js','utf8').replace("import { terminalTheme } from './theme.js';",'const terminalTheme=()=>({});');
const handlers=new Map();globalThis.window={addEventListener:(n,f)=>handlers.set(n,f),removeEventListener:n=>handlers.delete(n),Terminal:class{cols=80;rows=24;options={};writes=[];loadAddon(){}open(){}onData(){}onResize(){}focus(){}dispose(){this.disposed=true;}reset(){}write(s,cb){this.writes.push(s);cb?.();}},FitAddon:{FitAddon:class{fit(){}}}};
globalThis.location={protocol:'https:',host:'fixture.invalid'};
class Socket{static OPEN=1;static CLOSED=3;static CONNECTING=0;static all=[];readyState=1;sent=[];bufferedAmount=0;constructor(url){this.url=url;Socket.all.push(this);}send(s){this.sent.push(s);}close(){this.readyState=3;}}
globalThis.WebSocket=Socket;
const {SimTerminal}=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
const element={addEventListener(){},removeEventListener(){},getClientRects:()=>[]};
let offered=[];const terminal=new SimTerminal(element,{onLaunch:id=>{offered.push(id);return true;}}),socket=Socket.all.at(-1);socket.onopen();
const id='0123456789abcdef0123456789abcdef';socket.onmessage({data:JSON.stringify({type:'terminal_launch',id})});
check('native launch event invokes embedded tab callback',offered[0]===id&&offered.length===1);
check('accepted event does not reject server session',!socket.sent.some(s=>String(s).includes('terminal_launch_rejected')));
socket.onmessage({data:JSON.stringify({type:'terminal_launch',id:'../../bad'})});check('invalid session ID never reaches callback',offered.length===1);
terminal.destroy({terminate:false});check('normal originating destroy remains detach-only',!socket.sent.some(s=>s==='{"type":"close"}'));
const denied=new SimTerminal(element,{onLaunch:()=>false}),s2=Socket.all.at(-1);s2.onopen();s2.onmessage({data:JSON.stringify({type:'terminal_launch',id})});check('tab-limit failure explicitly rejects only offered child',s2.sent.some(s=>s===JSON.stringify({type:'terminal_launch_rejected',id})));
denied.destroy();
const app=fs.readFileSync('Resources/Web/js/app.js','utf8'),start=app.indexOf('function addTermTab(saved={}) {'),end=app.indexOf('\nfunction syncConsoleVisibility()',start);assert.ok(start>0&&end>start);
let created=0,activated=[],revealed=0;const tabs=[];class FakeTerminal{constructor(e,options){this.sessionId=options.sessionId;this.options=options;created++;}setFontSize(){}}
const make=new Function('SimTerminal','termTabs','tabElement','activateTermTab','persistTerminalTabs','updateTerminalStatus','revealDeveloperPanel',`let terminalEnabled=true,metroDisposed=false,termSerial=0,termFontSize=13,activeTermTabId=null;${app.slice(start,end)};return addTermTab;`)(FakeTerminal,tabs,id=>({id}),id=>activated.push(id),()=>{},()=>{},()=>revealed++);
const parent=make();check('ordinary terminal creation unchanged',created===1&&tabs.length===1&&parent.label==='Terminal 1');
check('launch callback creates Metro-labelled terminal with native ID',parent.controller.options.onLaunch(id)===true&&tabs[1].label==='Metro'&&tabs[1].controller.sessionId===id);
check('native-created terminal reveals developer panel',revealed===1);
check('duplicate delivery focuses existing tab without extra PTY',parent.controller.options.onLaunch(id)===true&&created===2&&activated.at(-1)===tabs[1].id);
while(tabs.length<8)make();check('normal eight-terminal cap retained',make()===undefined&&tabs.length===8);
check('new native offer rejected at browser limit',parent.controller.options.onLaunch('f'.repeat(32))===false&&tabs.length===8);
const native=fs.readFileSync('Sources/Terminal.swift','utf8');check('native quota and attached origin guards remain server-side',native.includes('parent.attached, !parent.closing')&&native.includes('guard sessions.count < 8'));
check('native helper exported only to embedded shell environment',native.includes('environment["REACT_TERMINAL"] = launcher.path'));
check('unclaimed child has bounded lifecycle and rejection binding',native.includes('child.expireIfUnattached()')&&native.includes('self.pendingLaunches[id] == session.id'));
check('packager command uses positional script, not shell interpolation',fs.readFileSync('Sources/TerminalHost.c','utf8').includes('"simwisp-metro", argc == 4 ? argv[3] : NULL'));
fs.writeFileSync(output+'/frontend.json',JSON.stringify({passed:true,checks,productConnection:false,realMetro:false},null,2));console.log('Terminal launch frontend/policy: '+checks.length+' checks PASS');
