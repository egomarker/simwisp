// Isolated ADB/scrcpy peer. Only numeric loopback sockets and owned fixture files.
import fs from 'node:fs';
import net from 'node:net';
const [root,role,...args]=process.argv.slice(2);
const record = v => fs.appendFileSync(root+'/events.ndjson',JSON.stringify({at_ms:Number(process.hrtime.bigint())/1e6,...v})+'\n');
if(role==='cli'){
  if(args[0]!=='-s'||!['emulator-5554','emulator-5556','USBPHYSICALTEST123','adb-PHYSICAL-TEST._adb-tls-connect._tcp','192.0.2.10:37123','[2001:db8::1]:5555'].includes(args[1]))throw Error('Unscoped/non-fixture ADB');
  record({kind:'command',args});const cmd=args.slice(2);
  if(cmd[0]==='exec-out'){
    if(cmd.length!==4||cmd[1]!=='sh'||cmd[2]!=='-c'||!cmd[3].startsWith("CLASSPATH='")||!cmd[3].includes(' exec app_process / --nice-name='))throw Error('Invalid ADB helper command string / double quoting');
    const helper=cmd[3].match(/io\.simwisp\.SimwispJpeg (\d+) (\d+) /);if(!helper)throw Error('Missing helper source size/FPS');
    const sourceEdge=Number(helper[1]);record({kind:'jpeg_process',pid:process.pid,serial:args[1],source_edge:sourceEdge});
    const fixture=JSON.parse(fs.readFileSync(root+'/jpeg.json','utf8'));let sequence=0,timer,next=performance.now(),wasIdle=false;
    process.stdout.on('error',()=>process.exit(0));
    const send=()=>{
      const mode=fs.existsSync(root+'/jpeg-mode.json')?JSON.parse(fs.readFileSync(root+'/jpeg-mode.json','utf8')):{};
      if(mode.stall){timer=setTimeout(send,50);return}
      const fail=mode.failure;if(fail==='eof')process.exit(0);
      if(mode.heartbeat || fail?.startsWith('heartbeat-')){
        wasIdle=true;
        const h=Buffer.alloc(16);h.write('SWH1');h.writeUInt32BE(fail==='heartbeat-length'?9:8,4);
        h.writeBigUInt64BE(fail==='heartbeat-zero'?0n:fail==='heartbeat-duplicate'?1n:process.hrtime.bigint(),8);
        process.stdout.write(h.subarray(0,3));process.stdout.write(h.subarray(3,11));process.stdout.write(h.subarray(11));
        timer=setTimeout(send,mode.heartbeat?500:50);return;
      }
      if(fail==='error'){const e=Buffer.from('JPEG failure <img src=x>\n'),h=Buffer.alloc(8);h.write('SWE1');h.writeUInt32BE(e.length,4);process.stdout.write(Buffer.concat([h,e]));process.exitCode=2;return}
      if(wasIdle){next=performance.now();wasIdle=false} // no synthetic catch-up burst on wake
      const landscape=mode.rotation||fs.existsSync(root+'/jpeg-rotation');
      const scaled=(mode.scaledFixture&&sourceEdge!==640||!args[1].startsWith('emulator-')&&sourceEdge<640)?fixture.scaled[String(sourceEdge)]:null;
      if(mode.scaledFixture&&sourceEdge!==640&&!scaled)throw Error('Unexpected source scaling edge');
      const width=scaled?(landscape?scaled.height:scaled.width):(landscape?640:320),height=scaled?(landscape?scaled.width:scaled.height):(landscape?320:640);
      const bytes=mode.corrupt?Buffer.from([255,216,255,217]):Buffer.from(scaled?(landscape?scaled.landscape:scaled.portrait):landscape?fixture.landscape:fixture.portrait[mode.static?(mode.index??0):sequence%fixture.portrait.length],'base64');
      const h=Buffer.alloc(32);h.write(fail==='magic'?'BAD!':'SWJ1');h.writeUInt32BE(fail==='length'?8388609:bytes.length,4);
      h.writeBigUInt64BE(fail==='sequence'?0n:fail==='duplicate'?1n:BigInt(++sequence),8);
      h.writeBigUInt64BE(fail==='timestamp'?0n:fail==='regression'?1000n-BigInt(sequence):process.hrtime.bigint(),16);
      h.writeUInt32BE(fail==='dimensions'?8193:width,24);h.writeUInt32BE(height,28);
      const p=Buffer.concat([h,bytes]);process.stdout.write(p.subarray(0,3));process.stdout.write(p.subarray(3,19));process.stdout.write(p.subarray(19));
      next+=1000/(mode.fps??60);timer=setTimeout(send,Math.max(0,next-performance.now()));
    };send();process.on('SIGTERM',()=>{clearTimeout(timer);process.exit(0)});
  }
  else if(cmd[0]==='forward'&&cmd[1]==='tcp:0')console.log(JSON.parse(fs.readFileSync(root+'/peer.json')).port);
  else if(cmd[0]==='forward'&&cmd[1]==='--remove'){try{fs.unlinkSync(root+'/options.json')}catch{}}
  else if(cmd.join(' ')==='shell setprop debug.stagefright.enableshaping 0'){}
  else if(cmd.join(' ')==='shell getprop debug.stagefright.enableshaping')console.log('0');
  else if(cmd.join(' ')==='shell dumpsys display'){
    const display=fs.existsSync(root+'/display.json')?JSON.parse(fs.readFileSync(root+'/display.json','utf8')):{};
    record({kind:'geometry_query',width:display.width??320,height:display.height??640,delay_ms:display.delay_ms??0});
    if(display.delay_ms)await new Promise(r=>setTimeout(r,display.delay_ms));
    if(display.fail)process.exit(1);
    console.log('mOverrideDisplayInfo=DisplayInfo{"fixture", displayId 0, real '+(display.width??320)+' x '+(display.height??640)+', rotation 0}');
  }
  else if(cmd.includes('com.genymobile.scrcpy.Server')){
    fs.writeFileSync(root+'/options.json',JSON.stringify({video:!cmd.includes('video=false'),serial:args[1],max_size:Number(cmd.find(v=>v.startsWith('max_size=')).split('=')[1]),fps:Number(cmd.find(v=>v.startsWith('max_fps=')).split('=')[1])}));record({kind:'process',pid:process.pid});
    const mode=fs.existsSync(root+'/scrcpy-mode.json')?JSON.parse(fs.readFileSync(root+'/scrcpy-mode.json','utf8')):{};
    if(mode.native_error){process.stderr.write('stack corruption detected (-fstack-protector)\nAborted\n');setTimeout(()=>process.exit(134),40)}else setInterval(()=>{},1000);
  }
}else{
  const fixture=JSON.parse(fs.readFileSync(root+'/video.json','utf8')),performanceTest=fs.existsSync(root+'/performance');let pair=null;const sockets=new Set();
  const session=(w=320,h=640)=>{const d=Buffer.alloc(12);d.writeUInt32BE(0x80000000);d.writeUInt32BE(w,4);d.writeUInt32BE(h,8);return d};
  function packet(hex,index,config=false,key=false){const b=Buffer.from(hex,'hex'),h=Buffer.alloc(12);h.writeBigUInt64BE((config?1n<<62n:key?1n<<61n:0n)|BigInt(Math.round(index*1000000/(performanceTest?60:30))));h.writeUInt32BE(b.length,8);return Buffer.concat([h,b])}
  const server=net.createServer(async socket=>{
    sockets.add(socket);socket.on('close',()=>sockets.delete(socket));socket.on('error',()=>{});
    for(let n=0;n<200&&!fs.existsSync(root+'/options.json');n++)await new Promise(r=>setTimeout(r,10));
    if(!fs.existsSync(root+'/options.json')){socket.destroy();return}
    const opt=JSON.parse(fs.readFileSync(root+'/options.json','utf8'));
    if(opt.video&&!pair){
      pair={v:socket,index:0,timer:null,dimensions:''};const current=pair;
      const mode=()=>fs.existsSync(root+'/scrcpy-mode.json')?JSON.parse(fs.readFileSync(root+'/scrcpy-mode.json','utf8')):{};
      const choose=()=>{const m=mode();if(!m.scaled)return{w:320,h:640,media:fixture,m};
        const bw=m.width??320,bh=m.height??640,r=Math.min(1,opt.max_size/Math.max(bw,bh));
        let w=Math.max(8,Math.round(bw*r)),h=Math.max(8,Math.round(bh*r));if(m.align8){w=w&~7;h=h&~7}if(m.rotation)[w,h]=[h,w];
        const all=JSON.parse(fs.readFileSync(root+'/phone-video.json','utf8')),media=all[w+'x'+h];if(!media)throw Error('No synthetic H264 fixture '+w+'x'+h);return{w,h,media,m}};
      const initial=choose();socket.write(Buffer.concat([Buffer.from([0]),Buffer.from(initial.m.bad_codec?'hevc':'h264')]));
      const send=()=>{if(socket.destroyed||fs.existsSync(root+'/hold-video'))return;const{w,h,media,m}=choose();if(m.disconnect||m.native_error){socket.destroy();return}if(m.idle)return;
        const dims=w+'x'+h;if(current.dimensions!==dims){current.dimensions=dims;current.index=0;socket.write(Buffer.concat([session(w,h),packet(media.config,0,true)]));record({kind:'video_session',serial:opt.serial,width:w,height:h,max_size:opt.max_size})}
        const f=media.frames[current.index%media.frames.length];socket.write(packet(f.key?media.config+f.payload:f.payload,current.index,false,f.key));current.index++};
      send();if(performanceTest){let next=performance.now()+1000/60;const pump=()=>{send();next+=1000/60;current.timer=setTimeout(pump,Math.max(0,next-performance.now()))};current.timer=setTimeout(pump,1000/60)}else{current.timer=setInterval(send,initial.m.scaled?Math.max(1,Math.round(1000/opt.fps)):33)}socket.on('close',()=>{clearTimeout(current.timer);if(pair===current)pair=null});
    }else{
      const current=pair;if(!opt.video)socket.write(Buffer.from([0]));let buffer=Buffer.alloc(0);
      socket.on('data',data=>{buffer=Buffer.concat([buffer,data]);while(buffer.length){const t=buffer[0],len=t===0?14:t===2?32:t===1?(buffer.length>=5?5+buffer.readUInt32BE(1):Infinity):1;if(buffer.length<len)break;const p=buffer.subarray(0,len);buffer=buffer.subarray(len);record({kind:'control',serial:opt.serial,type:t,hex:p.toString('hex'),action:t===2?p[1]:null});if(t===17&&current&&!current.v.destroyed){current.index=0;current.dimensions='';}}});
    }
  });server.listen(0,'127.0.0.1',()=>{fs.writeFileSync(root+'/peer.json',JSON.stringify({port:server.address().port}));console.log('peer ready')});
  process.on('SIGTERM',()=>{for(const s of sockets)s.destroy();server.close(()=>process.exit(0));setTimeout(()=>process.exit(1),500).unref()});
}
