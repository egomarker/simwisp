import fs from 'node:fs';import path from 'node:path';import {pathToFileURL} from 'node:url';
const report={checks:[],passed:false,syntheticDecoder:true,realBrowser:false,realInput:false};
const timers=new Map();let timerID=0;const trace=[];const warnings=[];
globalThis.setTimeout=globalThis.setInterval=(fn)=>{const id=++timerID;timers.set(id,fn);return id};globalThis.clearTimeout=globalThis.clearInterval=id=>timers.delete(id);
globalThis.location={protocol:'https:',host:'fixture.local:4141'};globalThis.isSecureContext=true;
class WS{static OPEN=1;static CONNECTING=0;static all=[];constructor(url){this.url=url;this.readyState=0;this.messages=[];WS.all.push(this)}send(s){const m=JSON.parse(s);this.messages.push(m);if(m.type==='frame_ack')trace.push(m.decode_error?'error-ack':'ack')}close(){this.readyState=3;this.onclose?.()}open(){this.readyState=1;this.onopen?.()}receive(data){this.onmessage?.({data})}}
class Decoder{static all=[];static supported=true;static probe=null;static retain=0;static isConfigSupported(config){return this.probe??Promise.resolve({supported:this.supported,config})}constructor(options){this.options=options;this.state='unconfigured';this.decodeQueueSize=0;this.chunks=[];this.retainCount=Decoder.retain;Decoder.all.push(this)}configure(c){this.config=c;this.state='configured'}decode(c){if(this.state!=='configured')throw Error('closed decode');this.chunks.push(c);if(this.retainCount>0&&this.chunks.length>this.retainCount)this.deliver(this.chunks[this.chunks.length-this.retainCount-1].timestamp)}close(){this.state='closed'}deliver(timestamp){const f={timestamp,closed:false,close(){if(this.closed)throw Error('double close');this.closed=true;trace.push('close')}};this.options.output(f);return f}error(){this.options.error(Error('synthetic decode failure'))}}
globalThis.WebSocket=WS;globalThis.VideoDecoder=Decoder;globalThis.EncodedVideoChunk=class{constructor(v){Object.assign(this,v)}};
const originalWarn=console.warn;console.warn=(...args)=>warnings.push(args.map(String).join(' '));
const {SimStream}=await import(pathToFileURL(path.resolve('Resources/Web/js/stream.js')).href);
function check(name,ok){report.checks.push({name,passed:ok===true});if(ok!==true)throw Error('FAIL '+name)}
const flush=async()=>{for(let n=0;n<8;n++)await Promise.resolve()};
function start(){const statuses=[],sizes=[];let first=0;const canvas={width:405,height:901,style:{},getContext(){return{drawImage(f,...args){canvas.lastDraw=args;check('Only open VideoFrame is drawn',!f.closed);trace.push('draw')}}},addEventListener(){},getBoundingClientRect(){return{left:0,top:0,width:405,height:901}},focus(){}};const stream=new SimStream('emulator-fixture',canvas,{onStatus:(s,m)=>statuses.push([s,m]),onFirstFrame:()=>first++,onOrientationChange:(w,h)=>sizes.push([w,h])});const ws=WS.all.at(-1);return{stream,canvas,ws,statuses,sizes,first:()=>first}}
const cfg=(epoch=1)=>JSON.stringify({type:'video_config',epoch,codec:'avc1.42001E',description:Buffer.from([1,66,0,30,255,225,0]).toString('base64'),width:405,height:901,coded_width:406,coded_height:902});
function packet({epoch=1,id=1,time=16667,key=true,magic=0x53575631}={}){const b=new ArrayBuffer(28),v=new DataView(b);v.setUint32(0,magic);v.setUint8(4,key?1:0);v.setUint32(8,epoch);v.setUint32(12,id);v.setBigUint64(16,BigInt(time));return b}
try{
 let t=start();t.ws.open();check('Only WSS URL constructed',t.ws.url.startsWith('wss://'));check('Capability readiness sent on open',t.ws.messages.some(m=>m.type==='video_ready'));
 const initial=t.ws.messages.length;t.stream.updateSettings({quality:45,accessibility_enabled:true,accessibility_subscription:9});t.ws.receive(JSON.stringify({type:'input_capabilities',live_touch:true}));check('Delayed native binding replays current settings and video readiness',t.ws.messages.length>initial&&t.ws.messages.at(-1).type==='video_ready'&&t.ws.messages.at(-2).quality===45&&t.ws.messages.at(-2).accessibility_subscription===9);
 t.ws.receive(cfg());t.ws.receive(packet());await flush();let d=Decoder.all.at(-1);check('Exactly one key access unit submitted',d.chunks.length===1&&d.chunks[0].type==='key');check('ACK sent on successful decode submission',t.ws.messages.some(m=>m.type==='frame_ack'&&m.frame_id===1));check('Decoder receives AVCC and low-latency option',d.config.description instanceof Uint8Array&&d.config.optimizeForLatency===true);
 const at=trace.length,f=d.deliver(16667);check('Presentation draws then closes without duplicate ACK',trace.slice(at).join(',')==='draw,close');check('VideoFrame released after presentation',f.closed);let ack=t.ws.messages.find(m=>m.type==='frame_ack');check('ACK carries exact epoch/frame identity',ack.epoch===1&&ack.frame_id===1);check('Visible dimensions exclude encoder padding',t.canvas.width===405&&t.canvas.height===901&&t.canvas.lastDraw[2]===405&&t.canvas.lastDraw[3]===901);check('First-frame hook follows output, not packet receipt',t.first()===1);
 t.ws.receive(packet({id:2,time:33334,key:false}));await flush();check('Dependent delta submitted without reconfiguration',d.chunks.length===2&&d.chunks[1].type==='delta');d.deliver(33334);
 const count=d.chunks.length;t.ws.receive(packet({epoch:99,id:200}));await flush();check('Wrong-epoch packet cannot enter decoder',d.chunks.length===count);check('Wrong-epoch ACK cannot acknowledge current native frame',t.ws.messages.at(-1).epoch===99&&t.ws.messages.at(-1).decode_error===true);
 t.stream.updateSettings({stream_paused:true});check('Pause closes decoder immediately',d.state==='closed');t.ws.receive(packet({id:3}));await flush();check('Paused packets never decode',d.chunks.length===count);
 t.stream.updateSettings({stream_paused:false});t.ws.receive(cfg(2));t.ws.receive(packet({epoch:2,id:3}));await flush();d=Decoder.all.at(-1);const messageCount=t.ws.messages.length,drawCount=trace.filter(v=>v==='draw').length;t.stream.destroy();const late=d.deliver(16667);check('Destroy closes decoder',d.state==='closed');check('Late output always closes its frame',late.closed);check('Late output neither draws nor acknowledges replacement',trace.filter(v=>v==='draw').length===drawCount&&t.ws.messages.length===messageCount);check('Destroy removes all timers',timers.size===0);
 t=start();t.ws.open();t.ws.receive(cfg());await flush();t.ws.receive(packet({key:false}));await flush();check('Missing initial IDR requests recovery',t.ws.messages.some(m=>m.type==='video_keyframe'));check('Missing keyframe clears decoder',Decoder.all.at(-1).state==='closed');
 t.ws.receive(cfg(2));t.ws.receive(packet({epoch:2,id:1}));await flush();d=Decoder.all.at(-1);d.error();check('Decode error requests new keyframe epoch',t.ws.messages.at(-1).type==='video_keyframe');check('Decode error releases decoder',d.state==='closed');
 t.ws.receive(cfg(3));t.ws.receive(packet({epoch:3,id:1}));await flush();d=Decoder.all.at(-1);
 t.ws.receive(packet({epoch:3,id:2,time:33334,key:false}));await flush();
 check('Second unrendered packet does NOT reset the decoder',d.chunks.length===2&&d.state==='configured');
 check('Second unrendered packet receives input credit',t.ws.messages.some(m=>m.type==='frame_ack'&&m.epoch===3&&m.frame_id===2));
 // Simulate Safari withholding five decoded frames until later input arrives.
 d.deliver(16667);d.deliver(33334);check('Buffered frames can render asynchronously',t.ws.messages.filter(m=>m.type==='frame_ack'&&m.epoch===3).length===2);
 // Restart into a new session with a decoder that deliberately retains 5 frames.
 t.stream.destroy();Decoder.retain=5;t=start();t.ws.open();t.ws.receive(cfg());await flush();
 for (let i=1;i<=35;i++) {
   t.ws.receive(packet({id:i,time:i*16667,key:i===1}));await flush();
   check('Stop-and-wait server can progress while decoder withholds output '+i,
     t.ws.messages.some(m=>m.type==='frame_ack'&&m.frame_id===i));
 }
 d=Decoder.all.at(-1);
 check('A decoder retaining five frames continues rendering',d.chunks.length===35&&t.first()===1);
 check('No decoder reconfiguration from delayed output',d.state==='configured');
 check('Buffered decoder eventually renders thirty outputs',t.stream!==null&&trace.filter(v=>v==='draw').length>=32);
 t.stream.destroy();Decoder.retain=0;
 // An entirely stuck decoder has a finite backlog rather than unlimited memory.
 t=start();t.ws.open();t.ws.receive(cfg());await flush();
 for (let i=1;i<=49;i++) {t.ws.receive(packet({id:i,time:i*16667,key:i===1}));await flush()}
 d=Decoder.all.at(-1);
 check('No-output decoder triggers bounded keyframe recovery',d.state==='closed'&&t.ws.messages.at(-1).type==='video_keyframe');
 check('No-output decoder does not ACK the rejected packet',!t.ws.messages.some(m=>m.type==='frame_ack'&&m.frame_id===49));
 t.ws.receive(packet({magic:123}));check('Malformed header requests recovery',t.ws.messages.at(-1).type==='video_keyframe');t.stream.destroy();check('Faulted stream destroys all timers',timers.size===0);
 let resolve;Decoder.probe=new Promise(r=>resolve=r);t=start();t.ws.open();t.ws.receive(cfg());t.ws.receive(packet());t.stream.destroy();const decoders=Decoder.all.length;resolve({supported:true});await flush();check('Destroyed capability probe cannot create decoder',Decoder.all.length===decoders);check('Capability probe cannot retain timers',timers.size===0);Decoder.probe=null;
 Decoder.supported=false;t=start();t.ws.open();t.ws.receive(cfg());await flush();check('Unsupported codec reports actionable status',t.statuses.at(-1)[0]==='unsupported'&&t.statuses.at(-1)[1].includes('H.264'));check('Unsupported codec closes socket and timers',t.ws.readyState===3&&timers.size===0);t.stream.destroy();Decoder.supported=true;
 const sockets=WS.all.length;globalThis.isSecureContext=false;t=start();check('Insecure context never opens a streaming socket',WS.all.length===sockets);check('Insecure context points to HTTPS trust setup',t.statuses.at(-1)[0]==='unsupported'&&t.statuses.at(-1)[1].includes('Trust'));t.stream.destroy();globalThis.isSecureContext=true;
 globalThis.VideoDecoder=undefined;t=start();check('Missing WebCodecs has clear unsupported status',t.statuses.at(-1)[0]==='unsupported');t.stream.destroy();globalThis.VideoDecoder=Decoder;
 check('Every created decoder was closed',Decoder.all.every(d=>d.state==='closed'));check('No leftover mock timers',timers.size===0);report.passed=true;report.expectedRecoveryWarnings=warnings.length;console.log(report.checks.length+' focused production decoder lifecycle/fault checks passed');
}catch(e){report.error=String(e);process.exitCode=1;console.error(e)}finally{console.warn=originalWarn;if(process.env.TEST_OUTPUT){fs.mkdirSync(process.env.TEST_OUTPUT,{recursive:true});fs.writeFileSync(path.join(process.env.TEST_OUTPUT,'decoder-review.json'),JSON.stringify(report,null,2)+'\n')}}
