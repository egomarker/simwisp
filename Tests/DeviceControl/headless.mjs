// Production launches/Stop/API/served UI; effects and pixels are synthetic.
export async function reviewHeadless({navigate,request,json,post,state,until,delay,click,pointer,wait,check,assert,evaluate,cdp,sidebar,shot,closePanels,reset,setAccept}) {
 const a='00000000-0000-4000-8000-000000000001',b='00000000-0000-4000-8000-000000000002';
 const selected=id=>`.add-device-item[data-id="${id}"]`,panel=id=>`.sim-panel[data-udid="${id}"]`,stop=id=>`[data-stop-id="${id}"]`;
 const pref='simwisp.ios-capture.v1:'+encodeURIComponent(b),scale='simwisp.ios-scaling.v1:'+encodeURIComponent(b),androidPref='simwisp.android-backends.v1:Pixel_6_API_36';
 const ss=()=>json('/api/sessions');
 const active=async(id,kind)=>until(async()=>{const s=(await ss()).find(x=>x.id===id);return s?.frames>5&&s.state==='Streaming'&&(!kind||s.capture_counters?.source_mode===kind)},12000);
 async function openAdd(id){await sidebar();await click('#add-sim-btn');await wait(`!!document.querySelector(${JSON.stringify(selected(id))})`);}
 async function launch(id,mode){await openAdd(id);await pointer(selected(id)+` [data-launch-mode="${mode}"]`);}
 async function stopUI(id){await sidebar();setAccept(true);await pointer(stop(id));await wait(`!document.querySelector(${JSON.stringify(stop(id))})`);}
 async function noPanels(){await closePanels();await until(async()=>(await ss()).length===0);}
 await navigate();
 assert('Headless capability advertised by production API',(await json('/api/info')).features.headless_launch===true);
 const rejectedBefore=(await state()).commands.length;
 for(const body of ['[]','null','{','{"mode":true}','{"mode":1}','{"mode":null}','{"mode":"HEADLESS"}','{"mode":"bad"}']){
  const r=await request('/api/boot/'+b,{method:'POST',headers:{'content-type':'application/json'},body});assert('Invalid launch object rejected: '+body,r.status===400);
 }
 for(const mode of ['bad',true,1,null])assert('Android invalid mode rejected before launch '+mode,(await post('/api/boot-avd',{avd:'Pixel_6_API_36',mode})).status===400);
 assert('Invalid launch requests invoke no command/window effect',(await state()).commands.length===rejectedBefore);
 let denied=await request('/api/boot/'+b,{method:'POST',headers:{cookie:''},body:'{"mode":"headless"}'});assert('Unpaired headless launch denied',denied.status===401);
 denied=await request('/api/boot/'+b,{method:'POST',headers:{origin:'https://evil.example'},body:'{"mode":"headless"}'});assert('Cross-origin headless launch denied',denied.status===403);
 // Make a real fixture-library choice by shutting down only B, not editing the live host.
 assert('Fixture windowed B stops before headless launch',(await post('/api/stop/'+b)).status===200);await click('#btn-refresh');await wait(`!document.querySelector(${JSON.stringify(stop(b))})`);
 await openAdd(b);
 assert('Run headless exists beside ordinary Run',await evaluate(`!!document.querySelector('${selected(b)} .add-headless-btn')&&!!document.querySelector('${selected(b)} .add-boot-btn:not(.add-headless-btn)')`));
 await check('Both actions have explicit type and distinct accessible labels',`[...document.querySelectorAll('${selected(b)} button')].every(b=>b.type==='button'&&b.getAttribute('aria-label').startsWith('Run '))&&document.querySelector('${selected(b)} .add-headless-btn').title==='Run headless'`);
 await check('Original headless glyph is inline, currentColor and decorative',`document.querySelector('${selected(b)} .add-headless-btn svg').getAttribute('aria-hidden')==='true'&&document.querySelector('${selected(b)} .add-headless-btn svg').getAttribute('stroke')==='currentColor'&&document.querySelectorAll('${selected(b)} .add-headless-btn path').length===2`);
 for(const size of [{width:320,height:568,mobile:true},{width:390,height:844,mobile:true},{width:1024,height:768,mobile:false},{width:1440,height:1000,mobile:false}]){
  await cdp('Emulation.setDeviceMetricsOverride',{...size,deviceScaleFactor:1});await cdp('Emulation.setTouchEmulationEnabled',{enabled:size.mobile});await sidebar();await delay(350);
  await check('Both launch buttons reachable without overflow at '+size.width,`[...document.querySelectorAll('${selected(b)} button')].every(e=>{const r=e.getBoundingClientRect();return r.width>=36&&r.height>=36&&r.left>=0&&r.right<=innerWidth+1})&&document.documentElement.scrollWidth<=innerWidth+1`);
 }
 await shot('headless-launch-buttons');
 await evaluate(`localStorage.setItem(${JSON.stringify(pref)},'current');localStorage.setItem(${JSON.stringify(scale)},'0.5');window.__holdPath='/api/boot/'+window.b`);
 await pointer(selected(b)+' .add-headless-btn');await wait('window.__held===true');
 await check('Both launch modes disabled while one request is in flight',`[...document.querySelectorAll('${selected(b)} .add-boot-btn')].every(b=>b.disabled)`);
 await evaluate(`document.querySelector('${selected(b)} .add-boot-btn').dispatchEvent(new Event('click'))`);
 await check('Repeated Run event cannot duplicate launch',`window.__requests.filter(r=>r.url==='/api/boot/'+window.b&&r.method==='POST').length===1`);
 await evaluate('window.__releaseHeld()');await active(b,'ios_simulator_native');await wait(`!!document.querySelector('${panel(b)} canvas')`);
 let st=await state();assert('Headless iOS boot recorded without native window',st.events.some(e=>e.event==='boot'&&e.id===b&&e.mode==='headless')&&st.windows.length===1&&st.windows[0].title.startsWith('iPhone 11'));
 assert('Discovery publishes headless intent by UUID',(await json('/api/sims')).find(s=>s.id===b).headless===true);
 await check('Headless panel selects Native input and gates window-only actions',`document.querySelector('${panel(b)}').dataset.headless==='true'&&!document.querySelector('${panel(b)} .headless-notice')&&[...document.querySelectorAll('${panel(b)} [data-action=rotate],${panel(b)} [data-action=shake]')].every(b=>!b.disabled)&&!document.querySelector('${panel(b)} [data-action=home]').disabled`);
 await check('Native choice overrides saved Mac window without overwriting it',`localStorage.getItem(${JSON.stringify(pref)})==='current'&&localStorage.getItem(${JSON.stringify(scale)})==='0.5'&&window.__wire.sockets.some(s=>s.url.includes('/ws/'+window.b)&&s.url.includes('capture_backend=native')&&s.url.includes('input_backend=native')&&s.url.includes('native_scale=0.5'))`);
 await click(panel(b)+' .backend-trigger');
 await check('Headless iOS gates Quartz input and Mac-window capture',"[...document.querySelectorAll('.ios-capture-popover [data-choice=current]')].every(b=>b.disabled)&&[...document.querySelectorAll('.ios-capture-popover [data-kind=input][data-choice=native]')].every(b=>b.getAttribute('aria-checked')==='true')");
 await click('.ios-capture-popover [data-kind=scaling][data-choice="0.25"]');await active(b,'ios_simulator_native');
 await check('Headless scaling is also session-only',`localStorage.getItem(${JSON.stringify(scale)})==='0.5'`);await click('.ios-capture-popover .backend-close');
 const inputs=await evaluate('window.__wire.inputs.length');await pointer(panel(b)+' canvas');await click(panel(b)+' [data-action=kbd]');await evaluate("document.querySelector('#kbd-input').value='inert Native typing';document.querySelector('#kbd-send').click()");await delay(150);
 await check('Headless iOS routes touch and keyboard to the injected Native peer','window.__wire.inputs.length>'+inputs);
 assert('Headless input never falls back to host Quartz',(await state()).events.some(e=>e.event==='native_event'&&e.id===b)&&!(await state()).events.some(e=>e.event.startsWith('quartz_')));
 await shot('headless-ios-native-input');
 const stopCount=st.commands.filter(c=>c.includes('shutdown')).length;await click(panel(b)+' [data-action=close]');await until(async()=>!(await ss()).some(s=>s.id===b));
 assert('Closing a headless view does not shut down its simulator',(await state()).states[b]==='Booted'&&(await state()).commands.filter(c=>c.includes('shutdown')).length===stopCount);
 await sidebar();await click('[data-udid="'+b+'"]');await active(b,'ios_simulator_native');
 await cdp('Page.reload');await wait(`!!document.querySelector('${panel(b)} canvas')`);await active(b,'ios_simulator_native');
 assert('Headless mode survives browser reload through device discovery',true);
 await sidebar();await click('[data-udid="'+a+'"]');await active(a,undefined).catch(async()=>{await until(async()=>(await ss()).find(s=>s.id===a)?.frames>5)});
 const beforeOther=(await ss()).find(s=>s.id===a).frames;await stopUI(b);await delay(300);
 assert('Stop headless iOS leaves windowed device and stream intact',(await state()).states[b]==='Shutdown'&&(await state()).states[a]==='Booted'&&(await ss()).find(s=>s.id===a).frames>beforeOther&&(await state()).quits===0);
 await noPanels();
 await launch(b,'windowed');await until(async()=>(await ss()).find(s=>s.id===b)?.frames>5,10000);
 assert('Ordinary Run still creates selected native window',(await state()).windows.some(w=>w.title.startsWith('iPhone SE'))&&(await json('/api/sims')).find(s=>s.id===b).headless===false);
 await check('Ordinary Run retains saved backend and no view-only restriction',`!document.querySelector('${panel(b)} .headless-notice')&&!document.querySelector('${panel(b)} [data-action=home]').disabled&&window.__wire.sockets.filter(s=>s.url.includes('/ws/'+window.b)).at(-1).url.includes('capture_backend=current')`);
 await stopUI(b);
 // Headless Android: actual synthetic RGBA → production Raw → VT → WebCodecs.
 assert('Fixture first Android stops before headless launch',(await post('/api/stop/emulator-5554')).status===200);await click('#btn-refresh');await wait("!document.querySelector('[data-stop-id=emulator-5554]')");
 await evaluate(`localStorage.setItem(${JSON.stringify(androidPref)},JSON.stringify({capture:'current',input:'current',scaling:'1'}))`);
 await launch('Pixel_6_API_36','headless');await active('emulator-5554','emulator_host_rgba_stream');
 await check('Headless Android chooses Raw without rewriting saved default',`document.querySelector('.sim-panel[data-udid=emulator-5554]').dataset.headless==='true'&&JSON.parse(localStorage.getItem(${JSON.stringify(androidPref)})).capture==='current'&&window.__wire.sockets.some(s=>s.url.includes('/ws/emulator-5554')&&s.url.includes('capture_backend=raw'))`);
 await click(panel('emulator-5554')+' .backend-trigger');await check('Headless Android offers only window-independent captures',"!document.querySelector('.backend-popover:not(.ios-capture-popover) [data-kind=capture][data-choice=current]')&&!document.querySelector('.backend-popover:not(.ios-capture-popover) [data-kind=capture][data-choice=auto]')");await click('.backend-popover:not(.ios-capture-popover) .backend-close');await shot('headless-android-raw');
 await stopUI('emulator-5554');st=await state();assert('Headless Android Stop kills only its serial and leaves other emulator',st.states['emulator-5554']==='Shutdown'&&st.states['emulator-5556']==='Booted'&&st.events.filter(e=>e.event==='adb_kill'&&e.id==='emulator-5554').length===2);
 await launch('Pixel_6_API_36','windowed');await until(async()=>(await ss()).find(s=>s.id==='emulator-5554')?.frames>5,12000);
 await check('Windowed Android keeps saved Mac-window capture',"document.querySelector('.sim-panel[data-udid=emulator-5554]').dataset.headless==='false'&&window.__wire.sockets.filter(s=>s.url.includes('/ws/emulator-5554')).at(-1).url.includes('capture_backend=current')");await stopUI('emulator-5554');
 // An unrelated emulator appearing first cannot steal another AVD's panel.
 await post('/api/stop/emulator-5556');await click('#btn-refresh');await wait("!document.querySelector('[data-stop-id=emulator-5556]')");
 await launch('Pixel_second_emulator','headless');await post('/fixture/config',{states:{'emulator-5554':'Booted'}});await active('emulator-5556','emulator_host_rgba_stream');
 assert('Postboot viewer matches exact AVD rather than first new serial',(await ss()).length===1&&(await ss())[0].id==='emulator-5556');await stopUI('emulator-5556');assert('Second headless Stop preserves concurrent first emulator',(await state()).states['emulator-5554']==='Booted');
 // A rejected boot is visible, escaped, retryable, and starts no view/poll.
 await openAdd(b);await post('/fixture/config',{failBoot:true});await pointer(selected(b)+' .add-headless-btn');await wait("!!document.querySelector('#add-list [role=alert]')");
 await check('Launch error is escaped inline and leaves both retry buttons enabled',`document.querySelector('#add-list [role=alert]').textContent.includes('<img')&&!document.querySelector('#add-list img')&&window.__injected===false&&[...document.querySelectorAll('${selected(b)} .add-boot-btn')].every(b=>!b.disabled)&&document.querySelectorAll('.sim-panel').length===0`);
 const bootRequests=await evaluate("window.__requests.length");await delay(2200);await check('Rejected boot starts no retained discovery poll or stream','window.__requests.length==='+bootRequests);await post('/fixture/config',{failBoot:false});await click('#add-close-btn');
 assert('No successful headless launch opened another Simulator window',(await state()).windows.length===1);
 await reset();await click('#btn-refresh');
 await check('All synthetic decoded frames closed after views stop',"window.__video.outputs>30&&window.__video.closed===window.__video.created&&window.__video.frameCloses===window.__video.outputs");
 assert('Headless launch/view/Stop regressions complete with no real device effects',(await state()).real_device_actions===false&&(await state()).real_capture===false);
}
