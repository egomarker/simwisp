// Owned IOSurfaces + production NativeCapture/Streams/TLS/WebCodecs; no devices.
export async function reviewNativeBusy({ev,api,active,connect,destroy,pixels,put,remove,events,until,check,sleep,getReceived}) {
 await connect();await sleep(200);
 const first=await api(),audit=await ev('({...audit})'),inputs=events('input.ndjson').length;
 await ev("nativeStream.send({type:'touch_down',x:.2,y:.3})");await until('gesture down admitted',()=>events('input.ndjson').length===inputs+1);
 put('mode.json',{busy:true,variant:true});
 await until('actual guarded snapshot rejects injected mid-copy seed',async()=>(await api()).capture_counters.busy_seed_snapshots>0);
 const start=await api(),wire=getReceived();await sleep(750);const busy=await api(),image=await pixels();
 check('busy source keeps Streaming and readable image availability',busy.state==='Streaming'&&busy.capture_counters.cached_image_available===true);
 check('busy DSoff emits continuously NEW H264 rather than packet replay',busy.frames>start.frames+30&&getReceived()>wire+30&&await ev('audit.invalid===0'));
 check('busy retains last owned image instead of producer green candidate',image.corners[0][0]>150&&image.corners[0][1]<100&&image.corners[2][2]>150);
 check('busy preserves real browser decoder and epoch',await ev(`audit.epoch===${audit.epoch}&&audit.decoderCreates===${audit.decoderCreates}`));
 check('busy does not prepare pixels or recreate encoder',busy.capture_counters.prepared_pixel_buffers===first.capture_counters.prepared_pixel_buffers&&busy.capture_counters.encoder_creations===1);
 check('busy counters distinguish seed race from missing surface',busy.capture_counters.busy_seed_snapshots>30&&busy.capture_counters.inactive_surfaces===0&&busy.capture_counters.busy_cached_image_encodes>30);
 await ev("nativeStream.send({type:'touch_move',x:.5,y:.6});nativeStream.send({type:'touch_up',x:.5,y:.6})");
 await until('gesture remains admitted during busy video',()=>events('input.ndjson').length===inputs+3);
 check('one continuous DOWN MOVE UP survives transient capture busy',events('input.ndjson').slice(inputs).map(x=>x.message.type).join(',')==='touch_down,touch_move,touch_up');
 await ev('nativeStream.updateSettings({data_saver:true})');await sleep(400);const idle=await api(),idleWire=getReceived();await sleep(500);const afterIdle=await api();
 check('busy DSon idles encodes but keeps availability and polling',getReceived()===idleWire&&afterIdle.capture_counters.polls>idle.capture_counters.polls&&afterIdle.capture_counters.cached_image_available===true);
 check('saver forced IDR during busy keeps same decoder/epoch',await ev(`audit.epoch===${audit.epoch}&&audit.decoderCreates===${audit.decoderCreates}`));
 put('mode.json',{variant:true});await ev('nativeStream.updateSettings({data_saver:false})');
 await until('coherent fresh green image after busy',async()=>(await pixels()).corners.every(c=>c[0]<100&&c[1]>150&&c[2]<100));
 check('fresh source resumes without hard recovery',await ev(`audit.epoch===${audit.epoch}&&audit.decoderCreates===${audit.decoderCreates}`));
 const fresh=await api();check('warm buffers remain bounded and reused',fresh.capture_counters.snapshot_buffers<=3&&fresh.capture_counters.snapshot_buffer_allocations<=3&&fresh.capture_counters.snapshot_buffer_reuses>50);
 put('mode.json',{inactive:true});await until('true absence clears availability',async()=>{const x=await api();return x.state==='Starting'&&x.capture_counters.cached_image_available===false});await sleep(250);
 const inactive=await api(),inactiveWire=getReceived(),inputBefore=events('input.ndjson').length;await ev("nativeStream.send({type:'touch_move',x:.6,y:.7})");await sleep(300);
 check('true absence sends no stale pixels',getReceived()===inactiveWire&&(await api()).frames===inactive.frames);
 check('true absence still refuses touch',events('input.ndjson').length===inputBefore);
 check('true absence records reason and releases warm snapshot storage',inactive.capture_counters.inactive_surfaces>0&&inactive.capture_counters.snapshot_buffer_bytes===0);
 put('mode.json',{variant:true});await active();
 await until('real absence recovery recreates decoder epoch',()=>ev(`audit.epoch!==${audit.epoch}&&audit.decoderCreates>${audit.decoderCreates}`));
 check('real inactivity recovery still requires fresh decoder configuration',true);
 const beforeLayout=await api();put('mode.json',{busy:true,width:640,height:320});
 await until('busy new geometry invalidates old image',async()=>{const x=await api();return x.state==='Starting'&&x.capture_counters.busy_geometry_changes>0});await sleep(250);
 const geometryWire=getReceived();await sleep(250);check('busy rotated geometry never replays wrong-size image',getReceived()===geometryWire&&(await api()).capture_counters.cached_image_available===false);
 put('window.json',{width:640,height:320});put('mode.json',{width:640,height:320});await active();
 await until('coherent rotated video accepted',async()=>{const p=await pixels();return p.w===640&&p.h===320});
 check('coherent real rotation recreates encoder',(await api()).capture_counters.encoder_creations===beforeLayout.capture_counters.encoder_creations+1);
 await destroy();remove('window.json');put('mode.json',{busy:true});
 await ev("window.nativeStats=[];window.nativeStream=new SimStream('native-fixture',document.getElementById('native-canvas'),{fps:60,quality:20,backends:{capture:'native',input:'current'},onStats:s=>nativeStats.push(s)})");
 await until('first image is busy with no invented cache',async()=>{const x=await api();return x?.capture_counters.busy_without_cached_image>2});const cold=await api();
 check('cold busy source has no encoder, video or touch availability',cold.frames===0&&cold.capture_counters.encoder_creations===0&&cold.capture_counters.cached_image_available===false);
 remove('mode.json');await active();put('mode.json',{busy:true});await until('cached busy source active',async()=>(await api()).capture_counters.busy_seed_snapshots>5);
 const opens=events().filter(x=>x.kind==='open').length;
 await until('busy cached encodes cannot hide 8s unreadable deadline',async()=>(await api())?.ios_capture.effective_capture==='unavailable',12000);
 const failed=await api();check('eight-second busy failure is visible and releases cache',failed.ios_capture.reason.includes('8s')&&failed.capture_counters.cached_image_available!==true);
 await sleep(350);const stopped=getReceived();await sleep(450);
 check('busy timeout is latched without silent fallback or retry',getReceived()===stopped&&events().filter(x=>x.kind==='open').length===opens);
 await destroy();remove('mode.json');remove('window.json');
}

export async function reviewNativeReuse({ev,api,connect,destroy,pixels,put,remove,until,check}) {
 await connect();const audit=await ev('({...audit})');
 for(let i=0;i<12;i++) {
  const green=i%2===0;put('mode.json',{variant:green});
  await until('fresh decoded pooled image '+i,async()=>{const c=(await pixels()).corners[0];return green ? c[0]<100&&c[1]>150&&c[2]<100:c[0]>150&&c[1]<100&&c[2]<100});
  check('pooled immutable source renders expected fresh color '+i,true);
 }
 const state=await api();
 check('fresh motion reuses ONE fullsize source reference after completed CI renders',state.capture_counters.source_frames>=13&&state.capture_counters.snapshot_buffers===1&&state.capture_counters.snapshot_buffer_allocations===1&&state.capture_counters.snapshot_buffer_reuses>=10);
 check('fresh motion keeps one encoder and decoder epoch',state.capture_counters.encoder_creations===1&&await ev(`audit.epoch===${audit.epoch}&&audit.decoderCreates===${audit.decoderCreates}`));
 check('fresh motion never queues source frames or uses JPEG',state.capture_counters.queued_frames===0&&state.capture_counters.jpeg_encodes===0&&state.capture_counters.jpeg_decodes===0);
 await destroy();remove('mode.json');
}
