// Owned loopback HTTP/2/gRPC screenshot fixture. No emulator, token or pixels
// from the host environment are read. The fixture secret never enters argv.
import fs from 'node:fs';import http2 from 'node:http2';
const root=process.argv[2],token='owned-raw-fixture-secret';
const record=v=>fs.appendFileSync(root+'/raw-events.ndjson',JSON.stringify({...v,at_ms:performance.now()})+'\n');
function uint(n){n=BigInt(n);const a=[];do{let b=Number(n&127n);n>>=7n;a.push(b|(n?128:0))}while(n);return Buffer.from(a)}
const field=(f,n)=>Buffer.concat([uint(f*8),uint(n)]),bytes=(f,b)=>Buffer.concat([uint(f*8+2),uint(b.length),b]);
function protoFields(b){const r={};let i=0;function read(){let v=0n,s=0n;for(let n=0;n<10;n++){if(i>=b.length)throw Error('truncated');const c=b[i++];v|=BigInt(c&127)<<s;if(!(c&128))return Number(v);s+=7n}throw Error('overflow')}while(i<b.length){const k=read(),t=k&7,f=k>>3;if(t!==0)throw Error('unexpected request');r[f]=read()}return r}
const streams=new Set(),sessions=new Set(),server=http2.createServer();let connection=0;
server.on('session',s=>{sessions.add(s);s.on('error',()=>{});s.on('close',()=>sessions.delete(s))});
server.on('stream',(s,h)=>{
 const id=++connection;streams.add(s);s.on('error',()=>{});let body=Buffer.alloc(0),seq=0,timer,initial=true,wasInactive=false;
 s.on('data',b=>{body=Buffer.concat([body,b]);if(body.length>1024)s.close()});
 s.on('close',()=>{streams.delete(s);clearTimeout(timer);record({kind:'raw-close',id})});
 s.on('end',()=>{
  const auth=h.authorization==='Bearer '+token,path=h[':path']==='/android.emulation.control.EmulatorController/streamScreenshot';
  if(!auth||!path){s.respond({':status':403,'content-type':'application/grpc'});s.end();record({kind:'raw-denied',id});return}
  if(body.length<5||body[0]!==0||body.readUInt32BE(1)!==body.length-5)throw Error('Bad request framing');
  const request=protoFields(body.subarray(5));if(request[1]!==1||request[3]!==request[4]||request[3]<8||request[3]>4096)throw Error('Unsafe screenshot request');
  record({kind:'raw-request',id,maxSize:request[3],format:request[1],authValid:true});
  const mode=()=>fs.existsSync(root+'/raw-mode.json')?JSON.parse(fs.readFileSync(root+'/raw-mode.json','utf8')):{};
  const init=mode();s.respond({':status':init.httpStatus??200,'content-type':init.badContentType?'text/plain':'application/grpc'},{waitForTrailers:true});
  s.on('wantTrailers',()=>s.sendTrailers({'grpc-status':String(init.grpcError?13:0)}));
  if(init.grpcError){s.end();return}
  function send(){
   if(s.destroyed)return;const m=mode();if(m.eof){s.end();return}
   if(m.noInitial || (m.static && !initial) || (m.inactive && wasInactive)){timer=setTimeout(send,25);return}
   let proto;
   if(m.inactive){proto=Buffer.alloc(0);wasInactive=true}
   else{
    wasInactive=false;const long=Math.min(request[3],640),short=Math.max(8,Math.floor(long/2));
    const w=m.rotation?long:short,h=m.rotation?short:long,px=Buffer.alloc(w*h*4);
    // Match the real emulator stream: already oriented top-down bitmap.
    // Four different corners catch both vertical and horizontal inversion.
    px.fill(Buffer.from(m.variant?[25,210,160,255]:[210,35,25,255]),0,w*Math.floor(h/3)*4);
    px.fill(Buffer.from([25,190,40,255]),w*Math.floor(h/3)*4,w*Math.floor(h*2/3)*4);
    px.fill(Buffer.from([25,40,210,255]),w*Math.floor(h*2/3)*4);
    const cw=Math.floor(w/4),ch=Math.floor(h/4);
    const corner=(x,y,color)=>{for(let row=y;row<y+ch;row++)px.fill(Buffer.from(color),(row*w+x)*4,(row*w+x+cw)*4)};
    corner(0,0,[220,30,30,255]);corner(w-cw,0,[220,210,20,255]);
    corner(0,h-ch,[20,30,220,255]);corner(w-cw,h-ch,[210,30,210,255]);
    const marker=seq%Math.max(1,w-12);for(let y=2;y<Math.min(12,h);y++)px.fill(Buffer.from([245,245,245,255]),(y*w+marker)*4,(y*w+Math.min(w,marker+8))*4);
    const format=Buffer.concat([field(1,m.png?0:1),field(3,m.badDimensions?4097:w),field(4,h),field(5,m.secondary?1:0)]);
    const raw=m.corrupt?px.subarray(0,px.length-1):px;
    proto=Buffer.concat([bytes(1,format),bytes(4,raw),field(5,m.duplicate?0:seq),field(6,BigInt(Date.now())*1000n)]);
   }
   const header=Buffer.alloc(5);header[0]=m.compressed?1:0;header.writeUInt32BE(m.oversize?33554432+65537:proto.length,1);
   const packet=Buffer.concat([header,proto]);record({kind:'raw-frame',id,seq,inactive:!!m.inactive,bytes:proto.length});seq++;initial=false;
   s.write(packet.subarray(0,2));s.write(packet.subarray(2,17));s.write(packet.subarray(17));
   timer=setTimeout(send,1000/(m.fps??60));
  }send();
 });
});
server.listen(0,'127.0.0.1',()=>{fs.writeFileSync(root+'/raw-peer.json',JSON.stringify({port:server.address().port}));console.log('raw peer ready')});
process.on('SIGTERM',()=>{for(const s of streams)s.destroy();for(const s of sessions)s.destroy();server.close(()=>process.exit(0));setTimeout(()=>process.exit(1),500).unref()});
