// Production HTTPS/Service/StreamSession/WebCodecs/UI; native and Quartz input,
// device actions, windows and producer pixels are owned inert fixture objects.
export async function reviewNativeInput({root,report,navigate,json,post,state,until,delay,click,pointer,wait,check,assert,evaluate,cdp,sidebar,shot,closePanels,reset,setAccept}) {
 const phase=process.env.NATIVE_INPUT_PHASE||'all';report.nativeInputPhase=phase;
 if(phase==='all'){
  for(const selected of ['picker','gestures','lifecycle','headless','quartz','cleanup','headless-controls','headless-state']){
   process.env.NATIVE_INPUT_PHASE=selected;
   await reviewNativeInput({root,report,navigate,json,post,state,until,delay,click,pointer,wait,check,assert,evaluate,cdp,sidebar,shot,closePanels,reset,setAccept});
   await reset();await evaluate('localStorage.clear()');
  }
  report.nativeInputPhase='all';return;
 }
 const a='00000000-0000-4000-8000-000000000001',b='00000000-0000-4000-8000-000000000002';
 const panel=id=>`.sim-panel[data-udid="${id}"]`,menu='.ios-capture-popover:not([hidden])';
 const inputPref=id=>'simwisp.ios-input.v1:'+encodeURIComponent(id),capPref=id=>'simwisp.ios-capture.v1:'+encodeURIComponent(id),scalePref=id=>'simwisp.ios-scaling.v1:'+encodeURIComponent(id);
 const sessions=()=>json('/api/sessions'),get=async id=>(await sessions()).find(s=>s.id===id);
 const native=(st,id,kind='event')=>st.events.filter(e=>e.event==='native_'+kind&&(!id||e.id===id));
 const touches=(st,id)=>native(st,id).filter(e=>e.phase);
 const active=(id,capture,input)=>until(async()=>{const s=await get(id);return s?.frames>5&&s.state==='Streaming'&&(!capture||s.ios_capture.capture===capture)&&(!input||s.ios_capture.input===input)},12000);
 const menusClosed=()=>evaluate("document.querySelectorAll('.backend-popover:not([hidden]) .backend-close').forEach(b=>b.click())");
 async function open(id){await sidebar();await click('[data-udid="'+id+'"]');await active(id)}
 async function picker(id,kind,choice){await menusClosed();await click(panel(id)+' .backend-trigger');await click(menu+` [data-kind=${kind}][data-choice="${choice}"]`)}
 async function wire(id,message){await evaluate(`(()=>{const s=window.__wire.sockets.filter(s=>s.readyState===WebSocket.OPEN&&s.url.includes('/ws/'+${JSON.stringify(id)})).at(-1);if(!s)throw Error('Missing owned stream');s.send(JSON.stringify(${JSON.stringify(message)}))})()`)}
 async function headlessB(){
  await evaluate(`localStorage.setItem(${JSON.stringify(inputPref(b))},'current');localStorage.setItem(${JSON.stringify(capPref(b))},'current');localStorage.setItem(${JSON.stringify(scalePref(b))},'0.5')`);
  assert('Synthetic B shutdown prepares a fresh headless session',(await post('/api/stop/'+b)).status===200);
  assert('Synthetic B headless launch succeeds without a host window',(await post('/api/boot/'+b,{mode:'headless'})).status===200);
  await json('/api/sims');await click('#btn-refresh');await delay(120);await open(b);await active(b,'native','native');
 }
 async function point(id,x,y){await menusClosed();return evaluate(`(()=>{const c=document.querySelector('${panel(id)} canvas');c.scrollIntoView({block:'nearest'});const r=c.getBoundingClientRect(),x=r.left+r.width*${x},y=r.top+r.height*${y};if(r.width<=0||r.height<=0||!c.contains(document.elementFromPoint(x,y)))throw Error('Canvas not reachable');return{x,y}})()`)}
 async function down(id,x=.35,y=.7){const before=touches(await state(),id).length,p=await point(id,x,y);await cdp('Input.dispatchMouseEvent',{type:'mouseMoved',...p});await cdp('Input.dispatchMouseEvent',{type:'mousePressed',...p,button:'left',buttons:1,clickCount:1});await until(async()=>touches(await state(),id).length>before);return p}
 async function up(p){await cdp('Input.dispatchMouseEvent',{type:'mouseReleased',...p,button:'left',clickCount:1});await delay(60)}
 async function allClosed(){await menusClosed();await closePanels();await until(async()=>{const s=await state();return native(s,null,'connect').length===native(s,null,'close').length});const first=native(await state()).length;await delay(180);assert('No input work or retained peer after final stream closes',native(await state()).length===first&&(await sessions()).length===0);}
 await navigate();
 if(phase==='picker'||phase==='all'){
  const resumeLayout=process.env.NATIVE_INPUT_FROM==='picker-layout';
  if(resumeLayout){
   report.reusedSuccessfulChecks='browser-picker-1/device-service-review.json (before failed desktop target assertion)';
   await evaluate(`localStorage.setItem(${JSON.stringify('simwisp.ios-input.v1:00000000-0000-4000-8000-000000000001')},'native');localStorage.setItem(${JSON.stringify('simwisp.ios-capture.v1:00000000-0000-4000-8000-000000000001')},'native');localStorage.setItem(${JSON.stringify('simwisp.ios-scaling.v1:00000000-0000-4000-8000-000000000001')},'0.5')`);
   await open(a);await active(a,'native','native');await click(panel(a)+' .backend-trigger');
  } else {
  await open(a);await active(a,'current','current');await click(panel(a)+' .backend-trigger');
  await check('iOS Input radio choices are exactly Quartz and Native',`JSON.stringify([...document.querySelectorAll('${menu} [data-kind=input]')].map(b=>b.textContent))==='["Quartz","Native"]'&&document.querySelector('${menu} [data-kind=input][data-choice=current]').getAttribute('aria-checked')==='true'`);
  assert('Quartz default never constructs a Native input peer',native(await state(),null,'connect').length===0);
  await click(menu+' [data-kind=input][data-choice=native]');await active(a,'current','native');
  assert('Selecting Native input preserves Mac-window capture',(await get(a)).ios_capture.capture==='current');
  assert('Native selection is lazy before any valid event',native(await state(),null,'connect').length===0&&(await get(a)).ios_capture.effective_input==='idle');
  await wire(a,{type:'text',text:'reject all 🙂'});await delay(100);
  assert('Invalid Unicode is rejected before connection or partial typing',native(await state(),null,'connect').length===0&&native(await state()).length===0);
  await click(menu+' [data-kind=capture][data-choice=native]');await active(a,'native','native');await click(menu+' [data-kind=scaling][data-choice="0.5"]');await active(a,'native','native');
  await click(menu+' [data-kind=input][data-choice=current]');await active(a,'native','current');
  assert('Quartz can be chosen independently of Native capture/scaling',(await get(a)).ios_capture.native_scale==='0.5');
  await click(menu+' [data-kind=input][data-choice=native]');await active(a,'native','native');
  await check('Input selection persists only in its own per-UUID key',`localStorage.getItem(${JSON.stringify(inputPref(a))})==='native'&&localStorage.getItem(${JSON.stringify(inputPref(b))})===null&&localStorage.getItem(${JSON.stringify(capPref(a))})==='native'&&localStorage.getItem(${JSON.stringify(scalePref(a))})==='0.5'`);
  }
  // Match the unchanged Android/iOS shared CSS: mobile44px, desktop36px.
  for(const width of (resumeLayout?[1024]:[320,390,1024])){
   await cdp('Emulation.setDeviceMetricsOverride',{width,height:width===320?568:844,deviceScaleFactor:1,mobile:false});await delay(80);
   await check('Native Input picker remains bounded with '+(width<=700?44:36)+'px targets at '+width,`(()=>{const m=document.querySelector('${menu}'),r=m.getBoundingClientRect();return r.left>=0&&r.top>=0&&r.right<=innerWidth+1&&r.bottom<=innerHeight+1&&[...m.querySelectorAll('[data-kind=input]')].every(b=>b.getBoundingClientRect().height>=${width<=700?44:36})})()`);
  }
  await evaluate(`document.querySelector('${menu} [data-kind=input][data-choice=native]').focus()`);await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:'ArrowLeft',code:'ArrowLeft',windowsVirtualKeyCode:37});await active(a,'native','current');
  assert('Keyboard navigation changes Input, not Capture or scale',(await get(a)).ios_capture.native_scale==='0.5');
  await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:'ArrowRight',code:'ArrowRight',windowsVirtualKeyCode:39});await active(a,'native','native');
  await shot('native-input-picker');await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await check('Escape closes Native picker and restores trigger focus',`document.querySelector('${panel(a)} .backend-trigger')===document.activeElement&&!document.querySelector('${menu}')`);
  await cdp('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});await menusClosed();await click(panel(a)+' [data-action=close]');await until(async()=>!await get(a));
  await cdp('Page.reload');await wait("!!document.querySelector('.device-item')");await open(a);await active(a,'native','native');
  assert('Capture, input and scaling choices survive reload independently',(await get(a)).ios_capture.native_scale==='0.5');
  await open(b);await active(b,'current','current');assert('Second UUID retains Quartz and Mac-window defaults',true);
  assert('Picker/reload/streaming without valid input still opens zero Native peers',native(await state(),null,'connect').length===0);await allClosed();
 }
 if(phase==='gestures'||phase==='all'){
  await headlessB();assert('Headless stream is lazy until first touch',native(await state(),b,'connect').length===0);
  let p=await down(b,.3,.75),first=touches(await state(),b).length-1;
  assert('Pointer DOWN is delivered before any pointer UP',touches(await state(),b).slice(first).map(e=>e.phase).join(',')==='down');
  for(let i=1;i<=10;i++){p=await point(b,.3+i*.025,.75-i*.035);await cdp('Input.dispatchMouseEvent',{type:'mouseMoved',...p,button:'left',buttons:1});await delay(22)}await up(p);
  await until(async()=>touches(await state(),b).at(-1)?.phase==='up');let gesture=touches(await state(),b).slice(first);
  assert('Real browser pointer events route as continuous down/move/up, never endpoint tap/drag',gesture[0].phase==='down'&&gesture.at(-1).phase==='up'&&gesture.filter(e=>e.phase==='down').length===1&&gesture.filter(e=>e.phase==='up').length===1&&gesture.filter(e=>e.phase==='move').length>=3&&new Set(gesture.map(e=>e.identifier)).size===1);
  assert('Normalized drag coordinates are applied once despite x0.5 video',Math.abs(gesture[0].x-.3)<.001&&Math.abs(gesture[0].y-.75)<.001&&Math.abs(gesture.at(-1).x-.55)<.001&&Math.abs(gesture.at(-1).y-.4)<.001&&(await get(b)).ios_capture.native_scale==='0.5');
  assert('No headless touch falls back to host Quartz',!(await state()).events.some(e=>e.event.startsWith('quartz_')));
  await click(panel(b)+' [data-action=kbd]');await evaluate("document.querySelector('#kbd-input').value='Hi 2!';document.querySelector('#kbd-send').click()");await until(async()=>native(await state(),b).filter(e=>e.usage).length>=10);
  assert('Production keyboard bar sends Native key pairs',native(await state(),b).filter(e=>e.usage).at(-1).down===false);
  await click(panel(b)+' [data-action=home]');await wire(b,{type:'app_switcher'});await until(async()=>native(await state(),b).filter(e=>e.button==='home').length===6);
  assert('Home and App switcher route device button pairs, without host keys',native(await state(),b).filter(e=>e.button==='home').map(e=>e.down).join(',')==='true,false,true,false,true,false'&&!(await state()).events.some(e=>e.event.startsWith('quartz_')));
  p=await down(b);const held=touches(await state(),b).at(-1),connected=native(await state(),b,'connect').length;
  await evaluate("Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'))");await until(async()=>native(await state(),b,'close').length===connected);
  assert('Visibility pause releases held contact once and closes its peer',touches(await state(),b).filter(e=>e.instance===held.instance&&e.identifier===held.identifier&&e.phase==='up').length===1&&(await get(b)).state==='Paused');
  await up(p);const idleEvents=native(await state()).length;await wire(b,{type:'touch_down',x:.2,y:.2});await delay(160);
  assert('Paused input creates no peer, polling or new HID work',native(await state()).length===idleEvents&&native(await state(),b,'connect').length===connected);
  await evaluate("delete document.hidden;document.dispatchEvent(new Event('visibilitychange'))");await active(b,'native','native');assert('Resume remains lazy until new valid input',native(await state(),b,'connect').length===connected);
  p=await down(b,.4,.5);const closing=touches(await state(),b).at(-1);await click(panel(b)+' [data-action=close]');await until(async()=>!await get(b)&&native(await state(),b,'close').length===connected+1);await up(p);
  assert('Closing a held view releases UP and its peer without stopping the device',touches(await state(),b).filter(e=>e.instance===closing.instance&&e.identifier===closing.identifier&&e.phase==='up').length===1&&(await state()).states[b]==='Booted');await allClosed();
 }
 if(phase==='lifecycle'||phase==='all'){
  await headlessB();await open(a);await picker(a,'input','native');await active(a,'current','native');await menusClosed();
  await post('/fixture/config',{hold:'native_input',id:a});const p=await down(a),st=await state(),starts=st.events.filter(e=>e.event==='capture_start'&&e.id===a).length,bFrames=(await get(b)).frames;
  await picker(a,'input','current');await until(async()=>(await get(a))?.ios_capture.input==='current');await picker(a,'input','native');await until(async()=>(await get(a))?.ios_capture.input==='native');await picker(a,'input','current');await until(async()=>(await get(a))?.ios_capture.input==='current');
  assert('Rapid Native→Quartz→Native→Quartz replacement waits for ALL older same-device input',(await get(a)).frames===0&&native(await state(),a,'close').length===0&&(await state()).events.filter(e=>e.event==='capture_start'&&e.id===a).length===starts);
  await delay(150);assert('Unrelated Native capture keeps streaming during selected input retirement',(await get(b)).frames>bFrames);
  await wire(b,{type:'tap',x:.4,y:.5});await until(async()=>touches(await state(),b).at(-1)?.phase==='up');assert('Unrelated device input worker is not blocked by selected input retirement',true);
  await post('/fixture/release',{type:'native_input',id:a});await active(a,'current','current');await up(p);
  const retired=await state(),closeIndex=retired.events.findIndex(e=>e.event==='native_close'&&e.id===a),nextStart=retired.events.findIndex((e,i)=>i>closeIndex&&e.event==='capture_start'&&e.id===a);
  assert('Final Quartz capture starts only after old Native UP/close finishes',closeIndex>=0&&nextStart>closeIndex&&touches(retired,a).at(-1)?.phase==='up'&&native(retired,a,'connect').length===1);
  await wire(a,{type:'key',key:'a'});await until(async()=>(await state()).events.some(e=>e.event==='quartz_key'&&e.id===a));assert('Quartz route remains available after opting out of Native',true);
  await post('/fixture/config',{failNativeInput:true});await wire(b,{type:'key',key:'a'});await until(async()=>(await get(b)).ios_capture.effective_input==='unavailable');
  const failedFrames=(await get(b)).frames,failed=native(await state(),b,'connect').length;await menusClosed();await click(panel(b)+' .backend-trigger');
  await check('Native input failure appears as escaped text, never injected HTML',`document.querySelector('${menu} .backend-warning').textContent.includes('<img')&&!document.querySelector('${menu} .backend-warning img')&&window.__injected===false&&document.querySelector('${menu} [data-effective=input]').textContent==='Unavailable'`);
  await post('/fixture/config',{failNativeInput:false});await wire(b,{type:'text',text:'still latched'});await delay(180);
  assert('Input errors latch without Quartz fallback/retry while capture continues',native(await state(),b,'connect').length===failed&&(await get(b)).frames>failedFrames&&!(await state()).events.some(e=>e.id===b&&e.event.startsWith('quartz_')));
  await picker(b,'scaling','0.25');await active(b,'native','native');await wire(b,{type:'key',key:'a'});await until(async()=>native(await state(),b,'connect').length===failed+1);
  assert('An explicit fresh stream can recover Native input after the failure latch',(await get(b)).ios_capture.effective_input==='native');
  await post('/fixture/config',{hold:'native_input',id:b});const q=await down(b),beforeStop=await state(),shutdowns=beforeStop.events.filter(e=>e.event==='shutdown'&&e.id===b).length,otherFrames=(await get(a)).frames;
  const stopping=post('/api/stop/'+b);await delay(140);
  assert('Stop cannot shut down a selected device while its Native input is in flight',(await state()).events.filter(e=>e.event==='shutdown'&&e.id===b).length===shutdowns);
  assert('Other Quartz stream remains live while Stop joins Native input',(await get(a)).frames>otherFrames);
  await post('/fixture/release',{type:'native_input',id:b});assert('Stop completes after the owned Native input is released',(await stopping).status===200);await up(q);
  const stopped=await state(),lastClose=stopped.events.findLastIndex(e=>e.event==='native_close'&&e.id===b),shutdown=stopped.events.findLastIndex(e=>e.event==='shutdown'&&e.id===b);
  assert('Stop orders final Native close before selected shutdown, without stopping other device',lastClose>=0&&lastClose<shutdown&&stopped.states[a]==='Booted'&&(await get(a)).state==='Streaming');await allClosed();
 }
 if(phase==='headless'||phase==='all'){
  const resumeAndroid=process.env.NATIVE_INPUT_FROM==='headless-android';
  await headlessB();
  if(resumeAndroid){report.reusedSuccessfulChecks='browser-headless-1/device-service-review.json (picker, geometry, inactivity and lazy wake checks)'}else{
  await click(panel(b)+' .backend-trigger');
  await check('Headless uses session-only Native input with device-scoped Rotate and Shake',`localStorage.getItem(${JSON.stringify(inputPref(b))})==='current'&&localStorage.getItem(${JSON.stringify(capPref(b))})==='current'&&document.querySelector('${menu} [data-kind=input][data-choice=current]').disabled&&document.querySelector('${menu} [data-kind=capture][data-choice=current]').disabled&&!document.querySelector('${panel(b)} [data-action=rotate]').disabled&&!document.querySelector('${panel(b)} [data-action=shake]').disabled&&!document.querySelector('${panel(b)} [data-action=home]').disabled&&!document.querySelector('${panel(b)} [data-action=kbd]').disabled`);
  await menusClosed();await wire(b,{type:'touch_down',x:.6,y:.5});await until(async()=>touches(await state(),b).at(-1)?.phase==='down');let old=touches(await state(),b).at(-1);
  await post('/fixture/config',{nativeLandscapeIDs:[b]});await until(async()=>native(await state(),b,'close').length===1);await active(b,'native','native');
  assert('A genuine producer geometry change releases the old identifier at its old point',touches(await state(),b).filter(e=>e.instance===old.instance&&e.identifier===old.identifier&&e.phase==='up').some(e=>e.x===old.x&&e.y===old.y));
  assert('Geometry cleanup does not eagerly reconnect Native input',native(await state(),b,'connect').length===1);
  await wire(b,{type:'touch_down',x:.2,y:.4});await until(async()=>native(await state(),b,'connect').length===2);old=touches(await state(),b).at(-1);
  await post('/fixture/config',{nativeInactiveIDs:[b]});await until(async()=>native(await state(),b,'close').length===2);const idle=native(await state()).length;
  await wire(b,{type:'touch_move',x:.5,y:.5});await delay(170);
  assert('Inactive producer releases Native input and cannot accept new moves',native(await state()).length===idle&&touches(await state(),b).some(e=>e.instance===old.instance&&e.phase==='up'));
  await post('/fixture/config',{nativeInactiveIDs:[]});await active(b,'native','native');assert('Producer wake still reconnects input lazily',native(await state(),b,'connect').length===2);
  }
  await post('/api/stop/emulator-5554');await post('/api/boot-avd',{avd:'Pixel_6_API_36',mode:'headless'});await json('/api/sims');await click('#btn-refresh');await delay(120);await open('emulator-5554');
  await until(async()=>{const s=await get('emulator-5554');return s?.frames>5&&s.capture_counters.source_mode==='emulator_host_rgba_stream'},12000);const androidFrames=(await get('emulator-5554')).frames;
  await wire(b,{type:'tap',x:.4,y:.5});await until(async()=>native(await state(),b,'connect').length===(resumeAndroid?1:3)&&touches(await state(),b).at(-1)?.phase==='up');
  assert('Headless Raw Android remains independent of iOS Native input',(await get('emulator-5554')).frames>androidFrames&&!(await state()).events.some(e=>e.event.startsWith('native_')&&typeof e.id==='string'&&e.id.startsWith('emulator-')));
  await shot('headless-native-input-and-android-raw');await allClosed();
  await open(b);await active(b,'native','native');await cdp('Page.reload');await wait(`!!document.querySelector('${panel(b)} canvas')`);await active(b,'native','native');
  await check('Discovery/reload restores headless Native without rewriting ordinary input preference',`localStorage.getItem(${JSON.stringify(inputPref(b))})==='current'&&window.__wire.sockets.some(s=>s.url.includes('/ws/'+window.b)&&s.url.includes('input_backend=native'))`);await allClosed();
 }
 if(phase==='quartz'){
  const resumeLost=process.env.NATIVE_INPUT_FROM==='quartz-lost';
  if(resumeLost){
   report.reusedSuccessfulChecks='browser-quartz-1/device-service-review.json (Quartz pause/release/default isolation checks)';
   await evaluate(`localStorage.setItem(${JSON.stringify('simwisp.ios-input.v1:00000000-0000-4000-8000-000000000001')},'native')`);
   await open(a);await active(a,'current','native');
  }else{
  await open(a);await active(a,'current','current');let p=await point(a,.45,.6);
  await cdp('Input.dispatchMouseEvent',{type:'mousePressed',...p,button:'left',buttons:1,clickCount:1});
  await until(async()=>(await state()).events.some(e=>e.event==='quartz_touch_down'&&e.id===a));
  await evaluate("Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'))");
  await until(async()=>(await state()).events.some(e=>e.event==='quartz_touch_up'&&e.id===a));
  assert('Pausing a live Quartz socket releases its held pointer before local state is cleared',(await state()).events.filter(e=>e.event==='quartz_touch_up'&&e.id===a).length===1&&(await get(a)).state==='Paused');
  await up(p);await delay(80);assert('The old physical release cannot duplicate Quartz UP after pause',(await state()).events.filter(e=>e.event==='quartz_touch_up'&&e.id===a).length===1);
  assert('Quartz gesture/pause never initializes Native input',native(await state(),null,'connect').length===0);
  await evaluate("delete document.hidden;document.dispatchEvent(new Event('visibilitychange'))");await active(a,'current','current');
  await picker(a,'input','native');await active(a,'current','native');await menusClosed();
  }
  await evaluate("document.querySelector('canvas').addEventListener('pointerdown',e=>window.__fixturePointer=e.pointerId)");
  const lostPoint=await down(a,.5,.6),old=touches(await state(),a).at(-1);
  // Chromium can defer a releasePointerCapture notification without motion.
  // Inject its zero-coordinate event deterministically into the real handler.
  await evaluate("document.querySelector('canvas').dispatchEvent(new PointerEvent('lostpointercapture',{pointerId:window.__fixturePointer,bubbles:true}))");
  await until(async()=>touches(await state(),a).at(-1)?.phase==='up');
  const released=touches(await state(),a).at(-1);
  assert('Scripted lost-capture event releases the same Native identifier at the last valid point',released.identifier===old.identifier&&released.instance===old.instance&&released.x===old.x&&released.y===old.y);
  await up(lostPoint);await allClosed();
 }
 if(phase==='cleanup'){
  await headlessB();await wire(b,{type:'touch_down',x:.6,y:.5});await until(async()=>(await get(b)).ios_capture.effective_input==='native');
  const held=touches(await state(),b).at(-1);
  await evaluate("window.__cleanupErrors=[];window.__wire.sockets.filter(s=>s.url.includes('/ws/'+window.b)).at(-1).addEventListener('message',e=>{if(typeof e.data!=='string')return;try{const value=JSON.parse(e.data);if(value.type==='input_error')window.__cleanupErrors.push(value.message)}catch{}})");
  await post('/fixture/config',{hold:'native_close',id:b,failNativeCleanupIDs:[b],nativeLandscapeIDs:[b]});
  await until(async()=>native(await state(),b,'close_begin').length===1);await active(b,'native','native');
  await wire(b,{type:'touch_down',x:.2,y:.3});await wait("window.__cleanupErrors.some(s=>s.includes('finishing previous cleanup'))");
  assert('Same-stream cleanup gates a new DOWN before its prior teardown result',native(await state(),b,'connect').length===1&&touches(await state(),b).filter(e=>e.phase==='down').length===1);
  assert('Geometry retirement attempts one UP at the original held point',touches(await state(),b).filter(e=>e.phase==='up'&&e.identifier===held.identifier&&e.x===held.x&&e.y===held.y).length===1);
  const frames=(await get(b)).frames;
  await open(a);await picker(a,'input','native');await active(a,'current','native');await wire(a,{type:'tap',x:.4,y:.5});await until(async()=>touches(await state(),a).at(-1)?.phase==='up');
  assert('One device cleanup does not block another device Native input or capture',(await get(b)).frames>frames&&native(await state(),a,'connect').length===1&&native(await state(),b,'close').length===0);
  await post('/fixture/release',{type:'native_close',id:b});await until(async()=>(await get(b)).ios_capture.effective_input==='unavailable');
  assert('Cleanup failure stays latched despite intervening rejected input',(await get(b)).ios_capture.input_reason==='Inert Native cleanup refused');
  await wire(b,{type:'tap',x:.3,y:.6});await delay(130);
  assert('A failed cleanup cannot silently create a second peer or fall back to Quartz',native(await state(),b,'connect').length===1&&!(await state()).events.some(e=>e.id===b&&e.event.startsWith('quartz_')));
  await post('/fixture/config',{failNativeCleanupIDs:[]});await picker(b,'scaling','0.25');await active(b,'native','native');
  assert('Explicit fresh stream waits for cleanup and recovers lazily',native(await state(),b,'connect').length===1);
  await wire(b,{type:'tap',x:.3,y:.5});await until(async()=>(await get(b)).ios_capture.effective_input==='native'&&touches(await state(),b).at(-1)?.phase==='up');
  assert('Fresh Native input opens only after old failed teardown has completed',native(await state(),b,'connect').length===2&&native(await state(),b,'close').length===1);
  await allClosed();
 }
 if(phase==='headless-controls'){
  await headlessB();
  await check('Headless notice is removed without leaving an empty top bar',"(()=>{const p=document.querySelector('.sim-panel[data-udid=\"'+window.b+'\"]');return p.dataset.headless==='true'&&!p.querySelector('.headless-notice')&&!p.textContent.includes('Native touch and keyboard')&&p.firstElementChild.contains(p.querySelector('canvas'))})()");
  await check('Headless Rotate and Shake remain present and enabled without window-shortcut labels',"(()=>{const p=document.querySelector('.sim-panel[data-udid=\"'+window.b+'\"]');return ['rotate','shake','home','kbd'].every(a=>!p.querySelector('[data-action='+a+']').disabled)&&p.querySelector('[data-action=shake]').title==='Shake'})()");
  await click(panel(b)+' [data-action=rotate]');await until(async()=>(await state()).events.some(e=>e.event==='headless_rotate'&&e.id===b));
  await wait("(()=>{const c=document.querySelector('.sim-panel[data-udid=\"'+window.b+'\"] canvas');return c.width>c.height})()");
  let journal=(await state()).events;
  assert('Headless Rotate targets B using full authoritative portrait geometry',journal.some(e=>e.event==='headless_rotate'&&e.id===b&&e.width===320&&e.height===640));
  await click(panel(b)+' [data-action=shake]');await until(async()=>(await state()).events.some(e=>e.event==='headless_shake'&&e.id===b));
  assert('Shake follows actual landscape geometry without double-scaling',(await state()).events.some(e=>e.event==='headless_shake'&&e.id===b&&e.width===640&&e.height===320)&&(await get(b)).ios_capture.native_scale==='0.5');
  assert('Idle system actions neither create HID peers nor post host Quartz input',native(await state(),null,'connect').length===0&&!(await state()).events.some(e=>e.event.startsWith('quartz_')));
  await open(a);await active(a,'current','current');
  await check('Windowed iOS keeps its enabled Rotate and original Shake shortcut label',"(()=>{const p=document.querySelector('.sim-panel[data-udid=\"'+window.a+'\"]');return p.dataset.headless==='false'&&!p.querySelector('[data-action=rotate]').disabled&&!p.querySelector('[data-action=shake]').disabled&&p.querySelector('[data-action=shake]').title.includes('Control')})()");
  await click(panel(a)+' [data-action=rotate]');await click(panel(a)+' [data-action=shake]');await until(async()=>(await state()).events.some(e=>e.event==='quartz_shake'&&e.id===a));
  assert('Windowed Rotate and Shake retain the old device action route',(await state()).events.some(e=>e.event==='quartz_rotate'&&e.id===a)&&!(await state()).events.some(e=>e.event.startsWith('headless_')&&e.id===a));
  const otherFrames=(await get(a)).frames;const p=await down(b,.4,.5),held=touches(await state(),b).at(-1);
  await click(panel(b)+' [data-action=rotate]');await until(async()=>(await state()).events.filter(e=>e.event==='headless_rotate'&&e.id===b).length===2);await up(p);
  journal=(await state()).events;
  const actionIndex=journal.findLastIndex(e=>e.event==='headless_rotate'&&e.id===b),upIndex=journal.findIndex(e=>e.event==='native_event'&&e.id===b&&e.phase==='up'&&e.identifier===held.identifier&&e.instance===held.instance);
  assert('Held touch is released at its last point before the headless action',upIndex>=0&&upIndex<actionIndex&&journal[upIndex].x===held.x&&journal[upIndex].y===held.y);
  await wait("(()=>{const c=document.querySelector('.sim-panel[data-udid=\"'+window.b+'\"] canvas');return c.width<c.height})()");
  assert('A second headless rotation returns to portrait while other capture continues',(await get(a)).frames>otherFrames&&journal[actionIndex].width===640&&journal[actionIndex].height===320);
  await cdp('Page.reload');await wait("!!document.querySelector('.sim-panel[data-udid=\"'+window.b+'\"] canvas')");await active(b,'native','native');
  await check('Reload keeps the notice absent and restores headless Native action routing',"(()=>{const p=document.querySelector('.sim-panel[data-udid=\"'+window.b+'\"]');return p.dataset.headless==='true'&&!p.querySelector('.headless-notice')&&!p.querySelector('[data-action=rotate]').disabled&&!p.querySelector('[data-action=shake]').disabled&&p.firstElementChild.contains(p.querySelector('canvas'))&&window.__wire.sockets.some(s=>s.url.includes('/ws/'+window.b)&&s.url.includes('input_backend=native'))})()");
  await shot('headless-ios-controls-no-notice');
  await wire(b,{type:'settings',stream_paused:true});await until(async()=>(await get(b)).state==='Paused');
  const count=(await state()).events.filter(e=>e.event.startsWith('headless_')).length;
  await wire(b,{type:'rotate'});await wire(b,{type:'shake'});await delay(150);
  assert('Paused headless controls cannot dispatch system actions',(await state()).events.filter(e=>e.event.startsWith('headless_')).length===count);
  await wire(b,{type:'settings',stream_paused:false});await active(b,'native','native');
  await post('/fixture/config',{failHeadlessControl:true});const frames=(await get(b)).frames;await wire(b,{type:'shake'});await until(async()=>(await get(b)).ios_capture.effective_input==='unavailable');
  await delay(130);
  assert('Headless action errors latch visibly without stopping capture or Quartz fallback',(await get(b)).frames>frames&&(await get(b)).ios_capture.input_reason==='Inert headless control refused'&&!(await state()).events.some(e=>e.id===b&&e.event.startsWith('quartz_')));
  await allClosed();
 }
 if(phase==='headless-state'){
  await evaluate(`localStorage.setItem(${JSON.stringify(inputPref(b))},'current');localStorage.setItem(${JSON.stringify(capPref(b))},'current');localStorage.setItem(${JSON.stringify(scalePref(b))},'0.5')`);
  await open(a);await active(a,'current','current');await open(b);await active(b,'current','current');
  await check('Initial windowed panel knows it is windowed and uses normal choices',`document.querySelector('${panel(b)}').dataset.headless==='false'&&document.querySelector('${panel(b)} [data-action=shake]').title.includes('Control')`);
  await post('/fixture/config',{windowlessIDs:[b]});
  assert('Fresh backend recovers already-booted headless state without a boot request',(await json('/api/sims')).find(d=>d.id===b).headless===true&&!(await state()).events.some(e=>e.event==='boot'));
  await click('#btn-refresh');await active(b,'native','native');
  await check('Refresh updates existing panel headless state and session backend choices',`document.querySelector('${panel(b)}').dataset.headless==='true'&&document.querySelector('${panel(b)} [data-action=shake]').title==='Shake'&&window.__wire.sockets.some(s=>s.readyState===WebSocket.OPEN&&s.url.includes('/ws/'+window.b)&&s.url.includes('capture_backend=native')&&s.url.includes('input_backend=native'))`);
  await check('Recovered headless mode does not overwrite ordinary saved preferences',`localStorage.getItem(${JSON.stringify(inputPref(b))})==='current'&&localStorage.getItem(${JSON.stringify(capPref(b))})==='current'&&localStorage.getItem(${JSON.stringify(scalePref(b))})==='0.5'`);
  await click(panel(b)+' .backend-trigger');
  await check('Recovered frontend picker knows headless and gates incompatible choices',`[...document.querySelectorAll('${menu} [data-choice=current]')].every(e=>e.disabled)&&document.querySelector('${menu} [data-kind=input][data-choice=native]').getAttribute('aria-checked')==='true'`);await menusClosed();
  const snapshots=(await state()).events.filter(e=>e.event==='mode_snapshot').length,requests=await evaluate("window.__requests.filter(r=>r.url==='/api/sims').length");await delay(1300);
  assert('Healthy streaming does not poll mode metadata every second',(await state()).events.filter(e=>e.event==='mode_snapshot').length===snapshots);
  await check('Frontend adds no one-second device-mode polling',`window.__requests.filter(r=>r.url==='/api/sims').length===${requests}`);
  await click(panel(b)+' [data-action=shake]');await until(async()=>(await state()).events.some(e=>e.event==='headless_shake'&&e.id===b));
  assert('A frontend-known headless Shake uses only the device-scoped action',!(await state()).events.some(e=>e.id===b&&e.event==='quartz_shake'));
  await click(panel(a)+' [data-action=shake]');await until(async()=>(await state()).events.some(e=>e.id===a&&e.event==='quartz_shake'));
  assert('Windowed simulator Shake still follows its windowed route',!(await state()).events.some(e=>e.id===a&&e.event==='headless_shake'));
  await cdp('Page.reload');await wait(`!!document.querySelector('${panel(b)} canvas')`);await active(b,'native','native');
  await check('Browser reload restores backend headless fact and Native session-only choices',`document.querySelector('${panel(b)}').dataset.headless==='true'&&localStorage.getItem(${JSON.stringify(inputPref(b))})==='current'&&document.querySelector('${panel(b)} [data-action=shake]').title==='Shake'`);
  await delay(200);
  await check('Recovered mode does not create a reconnect loop',`window.__wire.sockets.filter(s=>s.url.includes('/ws/'+window.b)).length===1`);
  await post('/fixture/config',{windowlessIDs:[]});await click('#btn-refresh');await active(b,'current','current');
  await check('Explicit refresh restores windowed frontend state and saved ordinary choices',`document.querySelector('${panel(b)}').dataset.headless==='false'&&document.querySelector('${panel(b)} [data-action=shake]').title.includes('Control')&&localStorage.getItem(${JSON.stringify(capPref(b))})==='current'`);
  await click(panel(b)+' [data-action=shake]');await until(async()=>(await state()).events.some(e=>e.id===b&&e.event==='quartz_shake'));
  assert('The same simulator returning to windowed uses windowed Shake',(await json('/api/sims')).find(d=>d.id===b).headless===false);
  await post('/fixture/config',{windowlessIDs:[b]});await click('#btn-refresh');await active(b,'native','native');
  await post('/fixture/config',{windowlessIDs:[]});await json('/api/sims');
  // Reconnect, WITHOUT refreshing the page/sidebar. Server mode in its existing
  // backend snapshot must correct the old panel and its socket choices.
  await evaluate("window.__wire.sockets.filter(s=>s.readyState===WebSocket.OPEN&&s.url.includes('/ws/'+window.b)).at(-1).close()");
  await active(b,'current','current');
  await check('Reconnect snapshot synchronizes stale panel mode without a page refresh',`document.querySelector('${panel(b)}').dataset.headless==='false'&&window.__wire.sockets.some(s=>s.readyState===WebSocket.OPEN&&s.url.includes('/ws/'+window.b)&&s.url.includes('capture_backend=current')&&s.url.includes('input_backend=current'))`);
  const bNative=(await state()).events.filter(e=>e.id===b&&e.event==='headless_shake').length;
  await click(panel(b)+' [data-action=shake]');await until(async()=>(await state()).events.filter(e=>e.id===b&&e.event==='quartz_shake').length===2);
  assert('Reconnect mode synchronization cannot dispatch a stale headless Shake',(await state()).events.filter(e=>e.id===b&&e.event==='headless_shake').length===bNative);
  await shot('authoritative-headless-windowed-refresh');await allClosed();
 }
 const final=await state();report.nativeInputJournal=final.events;assert('All constructed Native input peers are closed exactly once',native(final,null,'connect').every(c=>native(final,c.id,'close').filter(e=>e.instance===c.instance).length===1));
 assert('Synthetic checks performed no real input/capture/device/window actions',final.real_input===false&&final.real_capture===false&&final.real_device_actions===false&&final.real_window_actions===false);
 await check('Production decoder outputs are all released when views close',"window.__video.outputs>0&&window.__video.created===window.__video.closed&&window.__video.outputs===window.__video.frameCloses");
}
