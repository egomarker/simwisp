import crypto from 'node:crypto';
export async function reviewNativeFinalization({ev,api,connect,destroy,events,check,pixels}) {
 const base='https://127.0.0.1:45156',cookie=crypto.createHash('sha256').update('simwisp-session-v1:isolated-native-capture').digest('hex');
 await connect();const before=await api(),opens=events().filter(e=>e.kind==='open').length;
 const request=(method,origin=base,auth=true)=>fetch(base+'/api/native-frame-times'+(method==='GET'?'?id=native-fixture':''),{
  method,headers:{...(auth?{Cookie:'simwisp_session='+cookie}:{}),...(method==='POST'?{Origin:origin,'Content-Type':'application/json'}:{})},
  ...(method==='POST'?{body:JSON.stringify({id:'native-fixture',seconds:30})}:{})});
 check('Removed Native timing GET is404', (await request('GET')).status===404);
 check('Removed Native timing POST is404', (await request('POST')).status===404);
 check('Ordinary API authentication remains mandatory', (await request('GET',base,false)).status===401);
 check('Ordinary cross-origin mutation protection remains', (await request('POST','https://other.invalid')).status===403);
 for(const file of ['browser-trace.js','browser-trace-ui.js'])check('Retired browser asset is404: '+file,(await fetch(base+'/js/'+file)).status===404);
 check('No browser trace controls remain in production DOM',await ev("!document.querySelector('[id^=browser-trace]')"));
 check('Stream module exports no recorder API',await ev("(async()=>{const m=await import('/js/stream.js');return Object.keys(m).length===1&&typeof m.SimStream==='function'})()"));
 const image=await pixels();check('Actual WebCodecs still draws Native pixels',image.w===320&&image.h===640&&image.corners[0][0]>150&&image.corners[0][1]<100&&image.corners[0][2]<100);
 const after=await api();
 check('Native stays streaming with same source and encoder',after.state==='Streaming'&&events().filter(e=>e.kind==='open').length===opens&&after.capture_counters.encoder_creations===before.capture_counters.encoder_creations);
 check('Cleanup leaves FPS/quality/Data saver/scaling unchanged',after.fps===before.fps&&after.quality===before.quality&&after.data_saver===before.data_saver&&after.ios_capture.native_scale===before.ios_capture.native_scale);
 check('Finalized Native metadata has no experimental marker',!Object.hasOwn(after.ios_capture,'experimental'));
 await destroy();
}
