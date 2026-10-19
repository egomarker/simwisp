import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const checks=[];
const check=(name,condition)=>{checks.push({name,passed:!!condition});if(!condition)console.log('FAIL: '+name)};
const app=fs.readFileSync('Resources/Web/js/app.js','utf8');
const start=app.indexOf('async function handleAddBoot('),end=app.indexOf("addSimBtn.addEventListener('click', openAddPopover);",start);
assert(start>0&&end>start);const handler=app.slice(start,end);
function fixture({present=false,answer=true,bootError=false,stateError=false,hold=false}={}){
 const events=[],wire=[],ctx={console,Set,Map,Promise,Error,_bootError:'',_bootingIds:new Set(),_pendingBoots:new Map(),addSearch:{value:''},allSims:[],window:{confirm:text=>{events.push(['confirm',text]);return answer}},
 renderAddList:()=>{},renderDeviceList:()=>{},closeAddPopover:()=>{},closeMobileSidebar:()=>{},deviceActionMessage:(...args)=>events.push(['message',...args]),
 fetchIOSWindows:async()=>{events.push(['state']);if(stateError)throw Error('state failed');if(hold)await new Promise(r=>ctx.release=r);return{windowed:present}},
 bootSim:async(...args)=>{wire.push(['ios',...args]);events.push(['boot']);if(bootError)throw Error('boot failed')},bootAvd:async(...args)=>wire.push(['android',...args]),
 loadSims:async()=>events.push(['refresh']),fetchSims:async()=>[],synchronizePanelModes:()=>{},simPanels:new Map(),addSimPanel:()=>{},
 setInterval:()=>{events.push(['interval']);return 1},setTimeout:()=>2,clearInterval:()=>{},clearTimeout:()=>{}};
 vm.createContext(ctx);vm.runInContext(handler+'\nthis.run=handleAddBoot;',ctx);return{ctx,events,wire,run:(platform='ios',mode='headless')=>ctx.run('fixture','Inert iPhone',platform,400,800,mode)};
}
{
 const f=fixture({present:true,answer:false});await f.run();
 check('Cancel after renderer signal sends no boot/quit request',f.wire.length===0);
 check('Cancel does not refresh or start boot polling',!f.events.some(e=>['refresh','interval'].includes(e[0])));
 check('Cancel unlocks both launch choices',f.ctx._bootingIds.size===0);
 check('Warning names all windowed iOS simulators and unsaved state',f.events.find(e=>e[0]==='confirm')[1].includes('ALL windowed iOS simulators')&&f.events.find(e=>e[0]==='confirm')[1].includes('Unsaved app state'));
}
{
 const f=fixture({present:true});await f.run();
 check('Yes sends explicit close consent for headless iOS',JSON.stringify(f.wire)==='[["ios","fixture","headless",true]]');
 check('Yes defers refresh until streaming',f.events.slice(0,3).map(e=>e[0]).join(',')==='state,confirm,boot'&&!f.events.some(e=>e[0]==='refresh'));
 check('No premature Yes refresh',f.events.filter(e=>e[0]==='refresh').length===0);
}
{
 const f=fixture();await f.run();
 check('No renderer means no Yes/No warning',!f.events.some(e=>e[0]==='confirm'));
 check('No-renderer Headless sends no false consent',f.wire[0][3]===false);
 check('No-renderer Headless also defers refresh',f.events.filter(e=>e[0]==='refresh').length===0);
}
{
 const f=fixture({present:true,bootError:true});await f.run();
 check('Boot failure does not trigger streaming-only refresh',f.events.filter(e=>e[0]==='refresh').length===0);
 check('Boot failure is visible and starts no discovery poll',f.events.some(e=>e[0]==='message')&&!f.events.some(e=>e[0]==='interval'));
}
{
 const f=fixture({stateError:true});await f.run();
 check('Process-state read failure has no boot or quit side effect',f.wire.length===0&&!f.events.some(e=>e[0]==='refresh'));
}
for(const [platform,mode]of [['ios','windowed'],['android','headless'],['android','windowed']]){
 const f=fixture({present:true});await f.run(platform,mode);
 check('Unchanged non-headless-iOS route '+platform+'/'+mode,!f.events.some(e=>['state','confirm','refresh'].includes(e[0]))&&f.wire.length===1);
}
{
 const f=fixture({hold:true});const a=f.run();await Promise.resolve();await f.run();f.ctx.release();await a;
 check('In-flight process query cannot duplicate a launch',f.events.filter(e=>e[0]==='state').length===1&&f.wire.length===1);
}
// Exercise production API serialization independently, without a host server.
{
 const wire=[];const ctx={AbortController,setTimeout,clearTimeout,fetch:async(url,options)=>{wire.push({url,...options});return{ok:true,json:async()=>({windowed:true})}}};
 vm.createContext(ctx);vm.runInContext(fs.readFileSync('Resources/Web/js/api.js','utf8').replaceAll('export async function','async function')+'\nthis.api={fetchIOSWindows,bootSim};',ctx);
 await ctx.api.fetchIOSWindows();await ctx.api.bootSim('test','headless',true);await ctx.api.bootSim('test','windowed',false);
 check('Process state API is a GET without mutation',wire[0].url==='/api/ios-windows'&&!wire[0].method);
 check('Confirmed API boot transmits strict boolean close_simulator',JSON.parse(wire[1].body).close_simulator===true);
 check('Ordinary Run API omits close permission',!Object.hasOwn(JSON.parse(wire[2].body),'close_simulator'));
}
const passed=checks.every(c=>c.passed);assert.equal(new Set(checks.map(c=>c.name)).size,checks.length);
fs.writeFileSync(process.argv[2]+'/frontend.json',JSON.stringify({passed,checks,productionHandlerAndAPI:true,componentHarness:true,realDeviceActions:false,realWindowActions:false,appRestart:false},null,2)+'\n');
console.log('Process-policy frontend checks: '+checks.length+', passed: '+passed);process.exit(passed?0:1);
