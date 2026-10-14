import http from 'node:http';import crypto from 'node:crypto';
const a='00000000-0000-4000-8000-000000000001',b='00000000-0000-4000-8000-000000000002';
let propertyValue=25,propertyDelay=0,propertyStall=false;
let mode='valid',delay=0,version='one',sockets=new Set(),requests=0,peak=0,inflight=0,starts=0,commands=[];
const target=(id,device=a,app='com.fixture.app')=>({id,title:'Fixture React Native',deviceId:device,deviceName:device===a?'iPhone 11':'iPhone SE',platform:'ios',appId:app,webSocketDebuggerUrl:'ws://localhost:45153/inspector/debug?page='+id,runtime:'Hermes'});
function send(socket,obj){const data=Buffer.from(typeof obj==='string'?obj:JSON.stringify(obj)),h=Buffer.alloc(data.length<126?2:data.length<65536?4:10);h[0]=0x81;if(data.length<126)h[1]=data.length;else if(data.length<65536){h[1]=126;h.writeUInt16BE(data.length,2)}else{h[1]=127;h.writeBigUInt64BE(BigInt(data.length),2)}if(!socket.destroyed)socket.write(Buffer.concat([h,data]));}
const server=http.createServer(async(req,res)=>{
 if(req.url==='/json/list'){requests++;inflight++;peak=Math.max(peak,inflight);const current=mode;setTimeout(()=>{inflight--;if(current==='redirect'){res.writeHead(302,{location:'http://127.0.0.1:45154/blocked'});res.end();return;}res.setHeader('content-type','application/json');if(current==='malformed')res.end('{bad');else if(current==='oversized')res.end(' '.repeat(1_048_577));else if(current==='empty')res.end('[]');else if(current==='ambiguous')res.end(JSON.stringify([target(version),target('second',a,'com.fixture.second')]));else if(current==='android')res.end(JSON.stringify([{id:version,title:'google sdk_gphone64_arm64',description:'com.fixture.app',webSocketDebuggerUrl:'ws://localhost:45153/inspector/debug?page='+version,reactNative:{appId:'com.fixture.app',deviceName:'sdk_gphone64_arm64 - 16 - API 36',logicalDeviceId:'opaque-inspector-id-not-an-adb-serial'}}]));else if(current==='many')res.end(JSON.stringify(Array.from({length:10},(_,i)=>target('many-'+i,a,'com.fixture.many'+i))));else if(current==='unsafe')res.end(JSON.stringify([{...target(version),webSocketDebuggerUrl:'ws://evil.invalid:45153/inspector/debug'}]));else res.end(JSON.stringify([target(version),target('other',b,'com.fixture.other')]));},delay);return;}
 if(req.url==='/fixture/status'){res.end(JSON.stringify({mode,requests,peak,inflight,starts,active:sockets.size,commands}));return;}
 let body='';for await(const chunk of req){body+=chunk;if(body.length>1_048_576){res.writeHead(413);res.end();return;}}
 const m=JSON.parse(body||'{}');
 if(req.url==='/fixture/config'){mode=m.mode??mode;delay=m.delay??delay;version=m.version??version;propertyValue=m.propertyValue??propertyValue;propertyDelay=m.propertyDelay??propertyDelay;propertyStall=m.propertyStall??propertyStall;}
 if(req.url==='/fixture/context-reset')for(const socket of sockets)send(socket,{method:'Runtime.executionContextsCleared',params:{}});
 if(req.url==='/fixture/drop')for(const socket of sockets)socket.destroy();
 if(req.url==='/fixture/emit')for(let i=0;i<(m.count||1);i++)for(const socket of sockets){send(socket,m.exception?{method:'Runtime.exceptionThrown',params:{exceptionDetails:{text:'Uncaught',exception:{description:m.text||'Fixture exception'},stackTrace:{callFrames:[{functionName:'fixture',url:'index.bundle',lineNumber:120,columnNumber:7}]}}}}:{method:'Runtime.consoleAPICalled',params:{type:m.level||'log',timestamp:Date.now(),args:m.args??[{type:'string',value:m.text??('Fixture '+i)}],stackTrace:{callFrames:[{functionName:'fixture',url:'index.bundle',lineNumber:120,columnNumber:7}]}}});}
 res.end('{"ok":true}');
});
server.on('upgrade',(req,socket)=>{
 if(!req.url.startsWith('/inspector/debug')){socket.destroy();return;}
 const accept=crypto.createHash('sha1').update(req.headers['sec-websocket-key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');socket.write('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: '+accept+'\r\n\r\n');sockets.add(socket);starts++;let bytes=Buffer.alloc(0);
 socket.on('error',()=>{});socket.on('end',()=>socket.destroy());socket.on('close',()=>sockets.delete(socket));socket.on('data',chunk=>{bytes=Buffer.concat([bytes,chunk]);while(bytes.length>=2){const op=bytes[0]&15;let n=bytes[1]&127,k=2;const masked=!!(bytes[1]&128);if(n===126){if(bytes.length<4)return;n=bytes.readUInt16BE(2);k=4;}if(n===127){if(bytes.length<10)return;n=Number(bytes.readBigUInt64BE(2));k=10;}if(n>1_048_576){socket.destroy();return;}if(bytes.length<k+(masked?4:0)+n)return;const mask=masked?bytes.subarray(k,k+4):null;k+=masked?4:0;const data=Buffer.from(bytes.subarray(k,k+n));bytes=bytes.subarray(k+n);if(mask)for(let i=0;i<n;i++)data[i]^=mask[i%4];if(op===8){if(mode==='stalled-close')return;socket.end(Buffer.from([0x88,0]),()=>socket.destroy());return;}if(op===1){try{const m=JSON.parse(data);commands.push(m);if(m.method==='Runtime.getProperties')properties(socket,m);if(m.method==='Runtime.enable'&&mode!=='noack')send(socket,mode==='refused'?{id:m.id,error:{code:-32000,message:'Owned fixture debugger refusal'}}:{id:m.id,result:{}});}catch{}}}});
});
server.listen(45153,'127.0.0.1',()=>console.log('Owned fake Metro ready'));
process.on('SIGTERM',()=>{for(const s of sockets)s.destroy();server.close(()=>process.exit(0));});

function properties(socket,m){
 if(propertyStall)return;
 const remote=(type,value)=>({type,value}),obj=id=>({type:'object',description:'Object',objectId:id});
 const named=(name,value)=>({name,value,isOwn:true,enumerable:true,configurable:true,writable:true});
 let result=[];
 if(m.params.objectId==='fixture-root')result=[named('ModuleName',remote('string','ADHD')),named('age',remote('number',propertyValue)),named('active',remote('boolean',true)),named('nested',obj('fixture-child')),named('self',obj('fixture-root')),named('array',{type:'object',subtype:'array',description:'Array(2)',objectId:'fixture-array'}),{name:'secret',get:{type:'function',description:'get secret()',objectId:'fixture-getter'},enumerable:true},named('<img src=x onerror=window.__injected=true>',remote('string','<script>window.__injected=true</script>')),...Array.from({length:30},(_,i)=>named('field'+i,remote('number',i)))];
 else if(m.params.objectId==='fixture-child')result=[named('answer',remote('number',42)),named('parent',obj('fixture-root'))];
 else if(m.params.objectId==='fixture-array')result=[named('0',remote('string','first')),named('1',obj('fixture-child')),named('length',remote('number',2))];
 else if(m.params.objectId==='fixture-big')result=Array.from({length:1500},(_,i)=>named('field'+i,remote('string','fixture value')));
 else if(m.params.objectId==='fixture-proto')result=[named('constructor',{type:'function',description:'Object()',objectId:'fixture-getter'})];
 else if(m.params.objectId==='fixture-getter')result=[named('name',remote('string','get secret'))];
 else {setTimeout(()=>send(socket,{id:m.id,error:{code:-32000,message:'No such object'}}),propertyDelay);return;}
 setTimeout(()=>send(socket,{id:m.id,result:{result,internalProperties:[{name:'[[Prototype]]',value:obj('fixture-proto')}]}}),propertyDelay);
}
