import fs from 'node:fs';import vm from 'node:vm';import assert from 'node:assert/strict';
const source=fs.readFileSync('Resources/Web/js/app.js','utf8'),start=source.indexOf('async function handleAddBoot('),end=source.indexOf("addSimBtn.addEventListener('click', openAddPopover);",start),hstart=source.indexOf('function refreshDevicesAfterHeadlessFirstFrame('),hend=source.indexOf('function deviceActionMessage(',hstart);
assert(start>0&&end>start&&hstart>0&&hend>hstart);
const checks=[],check=(name,passed)=>{checks.push({name,passed:!!passed});if(!passed)console.log('FAIL: '+name)};
function fixture({present=true,cancel=false,fail=false}={}){
 const events=[],panels=new Map(),ctx={Set,Map,Promise,Error,_bootError:'',_bootingIds:new Set(),_pendingBoots:new Map(),addSearch:{value:''},allSims:[{id:'old',name:'Old windowed sim'}],simPanels:panels,window:{confirm:()=>{events.push('confirm');return!cancel}},
 renderAddList:()=>{},renderDeviceList:()=>{},closeAddPopover:()=>{},closeMobileSidebar:()=>{},deviceActionMessage:()=>{},
 fetchIOSWindows:async()=>({windowed:present}),bootSim:async()=>{events.push('boot');if(fail)throw Error('failed')},bootAvd:async()=>{},
 fetchSims:async()=>{events.push('inventory-fetch');return[]},loadSims:async()=>{events.push('refresh');ctx.allSims=[{id:'new',headless:true}]},synchronizePanelModes:()=>{},
 addSimPanel:(id,name,w,h,p,flag)=>{events.push('open-stream');panels.set(id,{refreshDevicesOnFirstFrame:flag,pendingHeadlessBoot:ctx._pendingBoots.get(id)})},
 setInterval:()=>{events.push('interval');return 1},setTimeout:()=>2,clearInterval:()=>{},clearTimeout:()=>{}};
 vm.createContext(ctx);vm.runInContext(source.slice(start,end)+'\n'+source.slice(hstart,hend)+'\nthis.run=handleAddBoot;this.frame=refreshDevicesAfterHeadlessFirstFrame;',ctx);
 return{ctx,events,panels,run:()=>ctx.run('new','New headless','ios',400,800,'headless'),frame:()=>ctx.frame('new',panels.get('new'))};
}
for(const present of [true,false]){
 const f=fixture({present});await f.run();
 check('No full refresh at boot acknowledgement, renderer='+present,!f.events.includes('refresh'));
 check('Headless opens exact UUID stream without discovery polling, renderer='+present,f.events.includes('open-stream')&&!f.events.includes('interval')&&!f.events.includes('inventory-fetch'));
 check('Other list entries stay until video, renderer='+present,f.ctx.allSims.some(s=>s.id==='old'));
 f.frame();await Promise.resolve();
 check('First displayed frame triggers one full refresh, renderer='+present,f.events.filter(e=>e==='refresh').length===1&&!f.ctx.allSims.some(s=>s.id==='old'));
 f.frame();check('Reconnect/repeated callback cannot repeat refresh, renderer='+present,f.events.filter(e=>e==='refresh').length===1);
}
{
 const f=fixture({fail:true});await f.run();check('Failed Headless boot never refreshes before streaming',!f.events.includes('refresh')&&!f.events.includes('open-stream'));
}
{
 const f=fixture({cancel:true});await f.run();check('No cancels boot, stream and refresh',!f.events.includes('boot')&&!f.events.includes('open-stream')&&!f.events.includes('refresh'));
}
{
 const f=fixture();await f.run();const old=f.panels.get('new');f.panels.set('new',{refreshDevicesOnFirstFrame:false});f.ctx.frame('new',old);
 check('Late first frame from replaced stream cannot refresh',!f.events.includes('refresh'));
}
{
 const f=fixture();await f.run();f.panels.delete('new');f.ctx.frame('new',{refreshDevicesOnFirstFrame:true});check('Closed view cannot cause delayed refresh',!f.events.includes('refresh'));
}
check('Production callback is wired to first frame, not connected status',source.includes("onFirstFrame:        () => { overlayEl.classList.add('hidden'); refreshDevicesAfterHeadlessFirstFrame(udid, panel); }")&&!source.slice(start,end).includes('loadSims('));
const passed=checks.every(c=>c.passed);fs.writeFileSync(process.argv[2]+'/stream-refresh.json',JSON.stringify({passed,checks,productionHandlerAndFrameGate:true,realDeviceActions:false,appRestart:false},null,2)+'\n');console.log('First-stream refresh checks: '+checks.length+', passed: '+passed);process.exit(passed?0:1);
