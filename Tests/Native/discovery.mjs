// Metadata-discovery policy through production HTTPS/VT/WebCodecs; no devices.
export async function reviewNativeDiscovery({ev,api,active,connect,destroy,pixels,put,remove,events,until,check,sleep}) {
 const opens=()=>events().filter(x=>x.kind==='open');
 const discovery=name=>events('discovery.ndjson').filter(x=>x.name===name).at(-1);
 await connect();const name=opens().at(-1).name,initial=await api(),audit=await ev('({...audit})');
 check('cold Native fixture discovers exactly one inventory',discovery(name)?.updates===1&&discovery(name)?.inventory_reads===1);
 await sleep(1350);
 check('former one-second TTL does not trigger metadata work',discovery(name)?.updates===1&&discovery(name)?.inventory_reads===1);
 for(let i=0;i<6;i++) {
  const green=i%2===0;put('mode.json',{variant:green});
  await until('new decoded pixels without metadata polling '+i,async()=>{const c=(await pixels()).corners[0];return green?c[0]<100&&c[1]>150&&c[2]<100:c[0]>150&&c[1]<100&&c[2]<100});
  check('fresh actual decoded image '+i+' while discovery stays cached',discovery(name)?.updates===1&&discovery(name)?.inventory_reads===1);
 }
 put('mode.json',{busy:true,variant:true});
 await until('actual owned snapshot busy rejection',async()=>(await api()).capture_counters.busy_seed_snapshots>0);
 const beforeBusy=await api();await sleep(700);const busy=await api();
 check('busy frames do not initiate metadata recovery',discovery(name)?.updates===1&&discovery(name)?.inventory_reads===1);
 check('busy cache continuity preserves decoder and source availability',busy.state==='Streaming'&&busy.frames>beforeBusy.frames+30&&await ev(`audit.epoch===${audit.epoch}&&audit.decoderCreates===${audit.decoderCreates}`));
 check('healthy metadata policy does not alter user stream parameters',busy.target_fps===initial.target_fps&&busy.quality===initial.quality&&busy.data_saver===initial.data_saver&&busy.ios_capture.native_scale===initial.ios_capture.native_scale);
 put('mode.json',{variant:true});await active();
 await until('coherent green after busy',async()=>(await pixels()).corners[0][1]>150);
 // Real nil known surfaces invalidate discovery; the next read encounters an
 // actually incompatible replacement getter and MUST expose it, not retry.
 const count=opens().length;put('mode.json',{bad_descriptor:true});
 await until('replacement ABI error remains visible and latched',async()=>(await api())?.ios_capture.effective_capture==='unavailable');
 const failed=await api();
 check('failed-source rediscovery does not bypass checked getter ABI',failed.ios_capture.reason.includes('framebufferSurface')&&failed.ios_capture.reason.includes('signature'));
 check('real absent surfaces triggered error-driven discovery',discovery(name)?.updates===2&&discovery(name)?.inventory_reads===2);
 await sleep(1200);
 check('real metadata failure has no silent retry or capture fallback',opens().length===count&&(await api()).frames===failed.frames&&(await api()).capture_counters.cached_image_available!==true);
 remove('mode.json');await connect();const next=opens().at(-1).name;
 check('explicit reconnect discovers fresh metadata exactly once',next!==name&&discovery(next)?.updates===1&&discovery(next)?.inventory_reads===1);
 const beforePause=opens().length;
 await ev('nativeStream.updateSettings({stream_paused:true})');await until('paused source retired',async()=>(await api())?.state==='Paused');
 await until('pause released metadata owner',()=>events().some(x=>x.kind==='close'&&x.name===next));
 await sleep(350);
 check('pause never runs a background metadata audit',discovery(next)?.updates===1&&opens().length===beforePause);
 await ev('nativeStream.updateSettings({stream_paused:false})');await active();const resumed=opens().at(-1).name;
 check('resume begins one new source-lifetime discovery',opens().length===beforePause+1&&resumed!==next&&discovery(resumed)?.updates===1&&discovery(resumed)?.inventory_reads===1);
 await destroy();const beforeWindow=opens().length;await connect('current');await sleep(300);
 check('Mac-window is isolated from metadata policy',opens().length===beforeWindow);
 await destroy();remove('mode.json');
}
