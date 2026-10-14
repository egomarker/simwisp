import fs from 'node:fs';
export const objectArgs=[{type:'object',description:'Object',objectId:'fixture-root',preview:{type:'object',overflow:true,properties:[{name:'ModuleName',type:'string',value:'ADHD'},{name:'age',type:'number',value:'25'}]}}];
export async function reviewObjectAPI({assert,admin,attach,counts,metro,target,snap,raw,until,delay}){
 const getCount=async()=>(await metro()).commands.filter(c=>c.method==='Runtime.getProperties').length;
 const one=await attach(target,snap.generation);await until(()=>one.messages.some(m=>m.state==='attached'));
 await admin('emit',{args:objectArgs});await until(()=>one.messages.some(m=>m.type==='entry'));
 const entry=one.messages.find(m=>m.type==='entry').entry,ref=entry.arguments[0].object_ref;
 assert('Object API: opaque reference and original preview delivered',typeof ref==='string'&&!JSON.stringify(entry).includes('fixture-root')&&entry.text.includes('age: 25'));
 const before=await getCount();await delay(80);assert('Object API: no eager property fetch',await getCount()===before);
 let serial=0;
 async function get(client,object_ref){const id='api-'+(++serial);client.send({type:'get_properties',request_id:id,object_ref});await until(()=>client.messages.some(m=>m.type==='properties'&&m.request_id===id));const result=client.messages.find(m=>m.type==='properties'&&m.request_id===id);client.send({type:'properties_ack',request_id:id});await until(()=>client.messages.some(m=>m.type==='properties_ready'&&m.request_id===id));return result;}
 await admin('config',{propertyValue:66});const result=await get(one,ref);
 assert('Object API: full own list exceeds preview cap and reads current values',result.properties.length>20&&result.properties.find(p=>p.name==='age').value.value===66&&!result.truncated);
 assert('Object API: descriptor/accessor/internal prototype preserved',result.properties.some(p=>p.name==='secret'&&p.get&&!p.value)&&result.properties.some(p=>p.internal&&p.name==='[[Prototype]]'));
 assert('Object API: no private object IDs in property response',!JSON.stringify(result).includes('fixture-child')&&!JSON.stringify(result).includes('objectId'));
 const nested=result.properties.find(p=>p.name==='nested').value.object_ref;assert('Object API: nested object is independently inspectable',(await get(one,nested)).properties.some(p=>p.name==='answer'&&p.value.value===42));
 const late=await attach(target,snap.generation);await until(()=>late.messages.some(m=>m.state==='attached'));const seen=await getCount();assert('Object API: handle not delivered to subscriber cannot inspect',!!(await get(late,ref)).error&&(await getCount())===seen);late.close();
 assert('Object API: guessed reference denied without upstream query',!!(await get(one,'00000000-0000-0000-0000-000000000000')).error&&(await getCount())===seen);
 const forged=await attach(target,snap.generation);await until(()=>forged.messages.some(m=>m.state==='attached'));forged.send({type:'get_properties',request_id:'forged',object_ref:ref,expression:'evil()'});await until(()=>forged.closed);assert('Object API: extra/evaluation parameters rejected',(await getCount())===seen);
 await admin('context-reset');await delay(80);assert('Object API: context reset expires prior handle',!!(await get(one,ref)).error);
 await admin('emit',{args:objectArgs});await until(()=>one.messages.filter(m=>m.type==='entry').length===2);const fresh=one.messages.filter(m=>m.type==='entry').at(-1).entry.arguments[0].object_ref;assert('Object API: reused runtime object ID gets new scoped handle',fresh!==ref);
 await admin('config',{propertyStall:true});const timeout=await get(one,fresh);assert('Object API: missing property reply has bounded timeout',timeout.error.includes('timed out'));await admin('config',{propertyStall:false});
 await admin('config',{propertyDelay:300});one.send({type:'get_properties',request_id:'closing',object_ref:fresh});await until(async()=>(await counts()).property_requests===1);one.close();await until(async()=>(await counts()).subscribers===0&&(await metro()).active===0);await delay(400);assert('Object API: closing cancels outstanding lookup and all handles',(await counts()).property_requests===0&&(await counts()).object_handles===0);
 await admin('config',{propertyDelay:0,propertyValue:25});
 const burst=await attach(target,snap.generation,undefined,{autoAck:false});await until(()=>burst.messages.some(m=>m.state==='attached'));await admin('emit',{args:objectArgs});await until(()=>burst.messages.some(m=>m.type==='entry'));const held=burst.messages.find(m=>m.type==='entry').entry;
 burst.send({type:'get_properties',request_id:'burst',object_ref:held.arguments[0].object_ref});await until(()=>burst.messages.some(m=>m.type==='properties'));
 burst.socket.cork();burst.send({type:'entry_ack',sequence:held.sequence});burst.send({type:'properties_ack',request_id:'burst'});burst.socket.uncork();await until(()=>burst.closed||burst.messages.some(m=>m.type==='properties_ready'));
 assert('Object API: coalesced log/property ACKs do not close console',!burst.closed&&burst.messages.some(m=>m.type==='properties_ready'));burst.close();await until(async()=>(await counts()).subscribers===0&&(await metro()).active===0);
 const calls=(await metro()).commands.filter(c=>c.method==='Runtime.getProperties');assert('Object API: fixed read-only upstream method/params only',calls.every(c=>c.params.ownProperties===true&&c.params.accessorPropertiesOnly===false&&c.params.generatePreview===true&&Object.keys(c.params).sort().join(',')==='accessorPropertiesOnly,generatePreview,objectId,ownProperties'));
}
export async function reviewObjectTrees({root,admin,metro,cdp,evaluate,check,delay,shot,wait}){
 const start=(await metro()).commands.filter(c=>c.method==='Runtime.getProperties').length;
 const count=async()=>(await metro()).commands.filter(c=>c.method==='Runtime.getProperties').length;
 const result={checks:[],realMetro:false,realDevices:false};
 const test=async(n,e)=>{await check('Object UI: '+n,e);result.checks.push(n);};
 await admin('emit',{args:objectArgs});await wait("!!document.querySelector('.console-object-summary')");await delay(150);
 await test('preview is collapsed and no eager request',"document.querySelector('.console-object-summary').textContent.includes('age: 25')&&!document.querySelector('.console-object').open");if(await count()!==start)throw Error('Eager object request');
 await admin('config',{propertyValue:66});
 await evaluate("window.__objectRoot=document.querySelector('.console-object');window.__objectRoot.firstElementChild.focus()");
 await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13,text:'\r'});await cdp('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});
 await wait("window.__objectRoot.open&&window.__objectRoot.querySelector('.console-object-body').textContent.includes('field29')");
 await test('Enter expands all own fields beyond inline preview',"window.__objectRoot.querySelector('.console-object-body').textContent.includes('age: 66')&&window.__objectRoot.querySelector('.console-object-body').textContent.includes('field29')");
 await test('not a frozen log-time snapshot',"window.__objectRoot.firstElementChild.textContent.includes('age: 25')&&window.__objectRoot.firstElementChild.title.includes('not frozen')");
 await test('accessors not automatically invoked',"window.__objectRoot.querySelector('.console-object-body').textContent.includes('[Getter — not evaluated]')");
 await test('XSS names and values remain text',"!window.__injected&&!document.querySelector('.console-list img,.console-list script')&&window.__objectRoot.textContent.includes('<img')");
 await test('self references bounded',"window.__objectRoot.textContent.includes('[Circular reference]')");
 const nested="[...window.__objectRoot.querySelectorAll('.console-object-property')].find(p=>p.firstElementChild.textContent==='nested: ').querySelector('summary')";
 await evaluate(nested+".click()");await wait("window.__objectRoot.textContent.includes('answer: 42')");await test('nested click fetches own fields lazily',"window.__objectRoot.textContent.includes('answer: 42')&&window.__objectRoot.textContent.includes('parent: Object [Circular reference]')");
 const array="[...window.__objectRoot.querySelectorAll('.console-object-property')].find(p=>p.firstElementChild.textContent==='array: ').querySelector('summary')";
 await evaluate(array+".click()");await wait("window.__objectRoot.textContent.includes('first')");await test('arrays independently expandable',"window.__objectRoot.textContent.includes('length: 2')");
 const proto="[...window.__objectRoot.querySelectorAll('.console-object-property')].find(p=>p.firstElementChild.textContent==='[[Prototype]]: ').querySelector('summary')";
 await evaluate(proto+".click()");await wait("window.__objectRoot.textContent.includes('constructor:')");await test('prototype descriptor independently expandable',"window.__objectRoot.textContent.includes('constructor:')");
 const requests=await count();await admin('emit',{text:'Object render stability'});await delay(250);
 await test('append preserves object and nested open state',"document.querySelector('.console-object').open&&document.querySelector('.console-object').textContent.includes('answer: 42')");if(await count()!==requests)throw Error('Append refetched objects');
 await evaluate("document.querySelector('.console-object').firstElementChild.focus()");await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:' ',code:'Space',windowsVirtualKeyCode:32,text:' '});await cdp('Input.dispatchKeyEvent',{type:'keyUp',key:' ',code:'Space',windowsVirtualKeyCode:32});await delay(80);
 await test('Space collapses native object disclosure',"!document.querySelector('.console-object').open");
 await evaluate("document.querySelector('.console-object').firstElementChild.click()");await delay(100);if(await count()!==requests)throw Error('Reopen refetched without invalidation');
 await test('reopening retains loaded DevTools-style tree',"document.querySelector('.console-object').open&&document.querySelector('.console-object').textContent.includes('answer: 42')");
 await shot('objects-desktop');
 await cdp('Emulation.setDeviceMetricsOverride',{width:320,height:568,deviceScaleFactor:1,mobile:true});await delay(200);
 await test('small-phone object rows wrap without document overflow',"document.documentElement.scrollWidth<=innerWidth+1&&document.querySelector('.console-object-body').getBoundingClientRect().right<=innerWidth+1");await shot('objects-small-phone');
 await cdp('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});
 await admin('emit',{args:[{type:'object',description:'Large object',objectId:'fixture-big'}]});await wait("[...document.querySelectorAll('.console-object-summary')].some(s=>s.textContent.includes('Large object'))");
 await evaluate("window.__big=[...document.querySelectorAll('.console-object-summary')].find(s=>s.textContent.includes('Large object')).parentElement;window.__big.firstElementChild.click()");await wait("window.__big.textContent.includes('Next fields')");
 await test('large response explicitly truncated and paged',"window.__big.textContent.includes('safety limits')&&window.__big.querySelectorAll('.console-object-property').length===100");
 await evaluate("[...window.__big.querySelectorAll('button')].find(b=>b.textContent==='Next fields').click()");await test('paging cached fields does not query runtime',"window.__big.textContent.includes('field100:')&&!window.__big.textContent.includes('field0:')");
 const beforeExpired=await count();await admin('emit',{args:[{type:'object',description:'Expired object',objectId:'fixture-expired'}]});await wait("[...document.querySelectorAll('.console-object-summary')].some(s=>s.textContent.includes('Expired object'))");await evaluate("[...document.querySelectorAll('.console-object-summary')].find(s=>s.textContent.includes('Expired object')).click()");await wait("document.querySelector('.console-list').textContent.includes('inspection is unsupported')");
 await test('expired or unsupported references reported without fabricated values',"document.querySelector('.console-list').textContent.includes('Object reference is unavailable')");
 await test('log/source expansion remains separate',"!!document.querySelector('.console-source-link')&&!!document.querySelector('.console-details')");
 await test('object data not persisted',"!sessionStorage.getItem('simwispDeveloperTabs').includes('field29')&&!sessionStorage.getItem('simwispDeveloperTabs').includes('object_ref')");
 await admin('config',{propertyValue:25});
 result.passed=true;result.queries=await count()-start;result.realSnapshotGuarantee=false;fs.writeFileSync(root+'/objects-review.json',JSON.stringify(result,null,2));
}

export async function reviewObjectComponent({root,evaluate,check}){
 const results=await evaluate(`(async()=>{
 const{MetroObjectView,safeRemote}=await import('/js/metro-objects.js');
 const{ConsoleBuffer}=await import('/js/metro-console.js');
 const host=document.createElement('div');host.id='object-component-review';document.body.append(host);
 const checks=[],test=(name,v)=>{checks.push({name,passed:!!v});if(!v)throw Error(name);};
 const tick=()=>new Promise(r=>setTimeout(r,30));let active=true,calls=0,resolve,bytes=0;
 const view=new MetroObjectView({element:host,active:()=>active,request:()=>{calls++;return new Promise(r=>resolve=r);},onBytes:n=>bytes=n});
 const value=ref=>safeRemote({type:'object',object_ref:ref,description:'Object',preview:[{name:'a',value:'1',type:'number'}]});
 const result=n=>({properties:[{name:'a',value:{type:'number',value:n}}]});
 let d=view.value(value('one'),'1:arg0');host.append(d);await tick();test('component mount does not fetch',calls===0);d.open=true;await tick();test('first expansion fetches once',calls===1);
 active=false;const html=d.innerHTML;resolve(result(2));await tick();test('hidden view caches response without DOM mutation',d.innerHTML===html&&bytes>0);
 active=true;view.capture();host.replaceChildren(d=view.value(value('one'),'1:arg0'));await tick();test('showing cached expanded view displays fields without query',calls===1&&d.textContent.includes('a: 2'));
 host.replaceChildren(d=view.value(value('late'),'2:arg0'));d.open=true;await tick();test('second object is lazy',calls===2);const oldResolve=resolve;view.clear();host.replaceChildren();oldResolve(result(99));await tick();test('clear rejects stale completion and frees cache',bytes===0&&!host.textContent);
 host.replaceChildren(d=view.value(value('late'),'3:arg0'));d.open=true;await tick();test('clear does not retain stale inspected data',calls===3);resolve(result(3));await tick();
 d.open=false;view.capture();host.replaceChildren(d=view.value(value('late'),'3:arg0'));await tick();test('queued native collapse survives immediate render',!d.open);d.open=true;await tick();test('reopen uses current cached result',calls===3&&d.textContent.includes('a: 3'));
 view.clear();host.replaceChildren();
 const ring=new ConsoleBuffer();for(let i=0;i<4000;i++)ring.push({text:'x'.repeat(1100),local_key:i});
 const quota=new MetroObjectView({element:host,active:()=>true,onBytes:n=>ring.trim(n),request:()=>Promise.resolve({properties:Array.from({length:100},(_,i)=>({name:'field'+i,value:{type:'string',value:'v'.repeat(900)}}))})});
 for(let i=0;i<16;i++){host.replaceChildren(d=quota.value(value('q'+i),String(i)+':arg0'));d.open=true;await tick();}
 test('property cache at most 1MiB',quota.bytes<=1048576&&quota.bytes>0);test('log and property cache share 5MiB budget',ring.bytes+quota.bytes<=5242880&&ring.dropped>0);test('property DOM is paged',host.querySelectorAll('.console-object-property').length<=100);quota.clear();test('clear releases quota accounting',quota.bytes===0);
 const circle=new MetroObjectView({element:host,active:()=>true,onBytes:()=>{},request:()=>Promise.resolve({properties:[{name:'self',value:{type:'object',object_ref:'c',description:'Object'}}]})});host.replaceChildren(d=circle.value(value('c'),'1:arg0'));d.open=true;await tick();test('cycle does not recursively fetch or render',host.textContent.includes('[Circular reference]')&&host.querySelectorAll('details').length===1);circle.clear();
 for(let i=0;i<2100;i++){host.replaceChildren(view.value(value('state'+i),String(i)+':arg0'));}test('old collapsed states do not disable newer objects',!!host.querySelector('details')&&!host.textContent.includes('view limit'));view.clear();
 test('remote string sanitizer bounded',safeRemote({type:'string',value:'x'.repeat(20000)}).value.length<=1024);
 host.remove();return checks;
 })()`);
 for(const r of results)await check('Object component: '+r.name,JSON.stringify(r.passed));
 fs.writeFileSync(root+'/objects-component-review.json',JSON.stringify({passed:true,checks:results,realMetro:false},null,2));
}
