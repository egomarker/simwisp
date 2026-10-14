import fs from 'node:fs';

// Unchanged production controller, isolated synthetic entries, never a Metro target.
export async function reviewConsoleScroll({root,cdp,evaluate,check,delay,shot}) {
  const checks=[];
  const test=async(name,expr)=>{await check('Console scroll: '+name,expr);checks.push(name);};
  const state=()=>evaluate('__scrollRead()');
  const command=async expr=>{await evaluate(expr);await delay(160);};
  const fill=async(n,base=0)=>command(`__scrollFill(${n},${base})`);
  const resize=async(h,w=1000)=>command(`__scrollHost.style.height='${h}px';__scrollHost.style.width='${w}px';__scrollConsole.fit()`);
  const saved=await evaluate('({theme:document.documentElement.dataset.theme,sockets:window.__wire?.sockets.length??0})');
  try {
    await cdp('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});
    await evaluate(`(async()=>{
      const {MetroConsole}=await import('/js/metro-console.js');
      const host=document.createElement('div');host.id='console-scroll-review';host.style.cssText='position:fixed;left:8px;top:8px;width:1000px;height:450px;max-width:calc(100vw - 16px);display:flex;flex-direction:column;overflow:hidden;padding:8px;box-sizing:border-box;background:var(--bg-elevated);color:var(--text-primary);z-index:999999';document.body.append(host);
      const c=new MetroConsole(host,{deviceId:'synthetic-scroll-review',binding:{}});window.__scrollConsole=c;window.__scrollHost=host;window.__scrollQueries=0;
      c.objects.request=async()=>{window.__scrollQueries++;return{properties:[{name:'answer',value:{type:'number',value:42}}]}};
      window.__scrollEntry=n=>({local_key:n,sequence:n,level:n%3===0?'warn':'log',text:'Synthetic entry '+n+(n%10===0?' needle':''),timestamp_ms:1760000000000+n,arguments:n===175?[{type:'object',object_ref:'synthetic-resize-object',description:'Object'}]:[],source:{url:'http://synthetic.invalid/index.bundle',line:1174,column:39},stack:[{function:'synthetic',url:'http://synthetic.invalid/index.bundle',line:1174,column:39}]});
      window.__scrollFill=(n,base=0)=>{c.toolbar.querySelector('[aria-label="Clear local console"]').click();if(c.auto.getAttribute('aria-pressed')!=='true')c.auto.click();for(let i=1;i<=n;i++)c.buffer.push(__scrollEntry(base+i));c.render()};
      window.__scrollAppend=(n,base)=>{for(let i=1;i<=n;i++)c.buffer.push(__scrollEntry(base+i));c.render()};
      window.__scrollRead=()=>{const l=c.list,top=l.getBoundingClientRect().top+l.clientTop,r=[...l.children].find(e=>e.getBoundingClientRect().bottom>top);return{rows:l.children.length,retained:c.buffer.values.length,dropped:c.buffer.dropped,count:c.count.textContent,first:Number(l.firstElementChild?.dataset.sequence),last:Number(l.lastElementChild?.dataset.sequence),key:r?Number(r.dataset.sequence):null,offset:r?r.getBoundingClientRect().top-top:0,scrollTop:l.scrollTop,remaining:l.scrollHeight-l.clientHeight-l.scrollTop,auto:c.auto.getAttribute('aria-pressed'),older:c.older.disabled,newer:c.newer.disabled}};
      const ro=new ResizeObserver(()=>c.fit());ro.observe(host);window.__scrollRO=ro;c.setVisible(true);__scrollFill(185);
    })()`);await delay(200);
    await test('185 rows initially retained/rendered','__scrollRead().rows===185&&__scrollRead().retained===185&&__scrollRead().auto==="true"');
    await command('__scrollConsole.list.scrollTop-=36');
    await test('manual upward scrolling disables follow without removing rows','__scrollRead().auto==="false"&&__scrollRead().rows===185');
    await command('__scrollConsole.fit()');
    await test('fit cannot narrow retained page to its visible tail','__scrollRead().rows===185&&__scrollRead().count==="1–185 / 185"&&__scrollRead().older&&__scrollRead().newer');
    for(const h of [720,310,610,230]){await resize(h);await test('near-bottom height '+h+' retains the complete page','__scrollRead().rows===185&&__scrollRead().retained===185&&__scrollRead().dropped===0&&__scrollRead().auto==="false"');}
    await resize(450);await command('__scrollConsole.list.scrollTop=1400');const reading=await state();
    for(const[h,w]of[[680,1000],[300,640],[520,940]]){await resize(h,w);await test('reading anchor survives '+w+'x'+h,`__scrollRead().key===${reading.key}&&Math.abs(__scrollRead().offset-(${reading.offset}))<1.5&&__scrollRead().rows===185`);}
    await command('__scrollAppend(1,185)');await test('append preserves page prefix and reading pixel offset',`__scrollRead().rows===186&&__scrollRead().first===1&&__scrollRead().key===${reading.key}&&Math.abs(__scrollRead().offset-(${reading.offset}))<1.5`);
    await command('__scrollConsole.setVisible(false);__scrollConsole.setVisible(true)');await test('hide/show keeps reading position',`__scrollRead().key===${reading.key}&&Math.abs(__scrollRead().offset-(${reading.offset}))<1.5`);
    await command(`__scrollConsole.list.querySelector('[data-sequence="175"] .console-source-link').click();__scrollConsole.list.querySelector('[data-sequence="175"] .console-object-summary').click()`);
    await test('synthetic object request is lazy and source expands independently','__scrollQueries===1&&__scrollConsole.list.querySelector("[data-sequence=\\"175\\"] .console-object").open&&__scrollConsole.list.querySelector("[data-sequence=\\"175\\"] .console-details").open');
    await command('__scrollConsole.list.scrollTop=1400');await resize(400,700);await command('__scrollConsole.render()');
    await test('resize/render retain source and cached object disclosures','__scrollQueries===1&&__scrollConsole.list.querySelector("[data-sequence=\\"175\\"] .console-object").open&&__scrollConsole.list.querySelector("[data-sequence=\\"175\\"] .console-details").open&&__scrollConsole.list.querySelector("[data-sequence=\\"175\\"] .console-object").textContent.includes("answer: 42")');
    const paused=await state();await command('__scrollConsole.pause.click();__scrollAppend(1,186)');await resize(530,900);
    await test('paused resize does not render pending rows','__scrollRead().rows===186&&__scrollRead().retained===187');await command('__scrollConsole.pause.click()');
    await test('resume includes pending row without losing page','__scrollRead().rows===187&&__scrollRead().first===1');
    await command(`__scrollConsole.search.value='needle';__scrollConsole.search.dispatchEvent(new Event('input'))`);
    await test('search resets to a complete bounded filtered page','__scrollRead().rows===18&&__scrollRead().first===10&&__scrollRead().last===180&&__scrollRead().older&&__scrollRead().newer');
    await resize(280,600);await test('filtered resize cannot hide matching rows','__scrollRead().rows===18');
    await command(`__scrollConsole.search.value='';__scrollConsole.search.dispatchEvent(new Event('input'))`);
    await command('__scrollConsole.toolbar.querySelector("[data-level=warn]").click()');const filtered=await state();await resize(460,1000);
    await test('level filtering survives resize',`__scrollRead().rows===${filtered.rows}&&![...__scrollConsole.list.children].some(r=>r.classList.contains('console-warn'))`);await command('__scrollConsole.toolbar.querySelector("[data-level=warn]").click()');
    await fill(650);await test('latest page is bounded to 300 rows','__scrollRead().rows===300&&__scrollRead().first===351&&__scrollRead().last===650&&!__scrollRead().older&&__scrollRead().newer');
    await command('__scrollConsole.older.click()');await test('Older reaches preceding disjoint page','__scrollRead().rows===300&&__scrollRead().first===51&&__scrollRead().last===350&&__scrollRead().auto==="false"');
    await command('__scrollConsole.list.scrollTop=1500');const older=await state();await resize(650);await command('__scrollAppend(1,650)');
    await test('history page stays stable during resize and append',`__scrollRead().first===51&&__scrollRead().last===350&&__scrollRead().key===${older.key}&&Math.abs(__scrollRead().offset-(${older.offset}))<1.5&&!__scrollRead().older&&!__scrollRead().newer`);
    await command('__scrollConsole.older.click()');await test('oldest partial page is reachable','__scrollRead().first===1&&__scrollRead().last===50&&__scrollRead().rows===50&&__scrollRead().older&&!__scrollRead().newer');await resize(300);
    await test('oldest partial page stays stable on resize','__scrollRead().first===1&&__scrollRead().last===50&&__scrollRead().rows===50');
    const ranges=[];for(let n=0;n<4;n++){const s=await state();ranges.push([s.first,s.last]);if(s.newer)break;await command('__scrollConsole.newer.click()');}
    await test('Newer reaches every retained entry without gaps',JSON.stringify(JSON.stringify(ranges)===JSON.stringify([[1,50],[51,350],[351,650],[651,651]])));
    await command('__scrollConsole.auto.click()');await test('Auto-scroll rejoins newest full window','__scrollRead().auto==="true"&&__scrollRead().rows===300&&__scrollRead().first===352&&__scrollRead().last===651&&Math.abs(__scrollRead().remaining)<1.5');
    for(const[h,w]of[[730,960],[240,600],[600,1000],[310,640]]){await resize(h,w);await test('follow remains pinned through '+w+'x'+h,'__scrollRead().auto==="true"&&Math.abs(__scrollRead().remaining)<1.5&&__scrollRead().rows===300');}
    await evaluate('__scrollHost.style.height="680px";__scrollConsole.list.dispatchEvent(new Event("scroll"));__scrollConsole.fit()');await delay(100);
    await test('layout-generated scroll cannot disable follow','__scrollRead().auto==="true"&&Math.abs(__scrollRead().remaining)<1.5');
    await command('__scrollConsole.list.dispatchEvent(new Event("scroll"));__scrollConsole.render();__scrollConsole.list.dispatchEvent(new Event("scroll"))');await test('queued render scroll cannot disable follow','__scrollRead().auto==="true"');
    await command('__scrollConsole.setFontSize(19)');await test('font reflow preserves follow','__scrollRead().auto==="true"&&Math.abs(__scrollRead().remaining)<1.5');await command('__scrollConsole.setFontSize(13)');
    const point=await evaluate('(()=>{const r=__scrollConsole.list.getBoundingClientRect();return{x:r.x+r.width/2,y:r.y+r.height/2}})()');
    await cdp('Input.dispatchMouseEvent',{type:'mouseWheel',deltaX:0,deltaY:-180,...point});await delay(200);await test('real wheel scrolling disables follow','__scrollRead().auto==="false"');const wheel=await state();await resize(380);await test('wheel reading position survives next resize',`__scrollRead().key===${wheel.key}&&Math.abs(__scrollRead().offset-(${wheel.offset}))<1.5`);
    await fill(5000);await command('__scrollConsole.older.click();__scrollConsole.list.scrollTop=1500');const retained=await state();await command('__scrollAppend(600,5000)');
    await test('buffer eviction before page preserves surviving visible anchor',`__scrollRead().retained===5000&&__scrollRead().dropped===600&&__scrollRead().first===4401&&__scrollRead().last===4700&&__scrollRead().key===${retained.key}&&Math.abs(__scrollRead().offset-(${retained.offset}))<1.5`);
    await command('__scrollAppend(5000,5600)');await test('fully evicted page safely falls back to oldest retained window','__scrollRead().retained===5000&&__scrollRead().dropped===5600&&__scrollRead().first===5601&&__scrollRead().rows===300&&__scrollRead().older&&!__scrollRead().newer');
    await command('__scrollConsole.newer.click()');await test('newer retained history remains reachable after eviction','__scrollRead().first===5901&&__scrollRead().rows===300');
    await command('__scrollConsole.toolbar.querySelector("[aria-label=\\"Clear local console\\"]").click()');await resize(460,1000);await test('Clear resets page/scroll state without stale anchors','__scrollRead().rows===0&&__scrollRead().retained===0&&__scrollRead().count==="0–0 / 0"&&__scrollRead().older&&__scrollRead().newer');
    await fill(185);await resize(450,320);
    await command('__scrollConsole.toolbar.querySelector("[aria-label=\\"Clear local console\\"]").click();for(let i=1;i<=185;i++)__scrollConsole.buffer.push({...__scrollEntry(i),text:("Wrapped synthetic "+i+" ").repeat(50),arguments:[]});__scrollConsole.render();__scrollConsole.focus()');
    await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:'PageUp',code:'PageUp',windowsVirtualKeyCode:33});await cdp('Input.dispatchKeyEvent',{type:'keyUp',key:'PageUp',code:'PageUp',windowsVirtualKeyCode:33});await delay(180);
    await test('native PageUp disables follow on wrapped rows','__scrollRead().auto==="false"&&__scrollRead().rows===185');
    await command('(()=>{const l=__scrollConsole.list,r=l.querySelector("[data-sequence=\\"61\\"]"),box=r.getBoundingClientRect();l.scrollTop+=box.top-l.getBoundingClientRect().top+box.height*.75})()');
    await test('reading position can be inside a deeply wrapped message','__scrollRead().key===61&&__scrollRead().offset< -50');
    await resize(450,1000);
    await test('widening cannot scroll past an anchor whose wrapped height shrank','__scrollRead().key===61&&__scrollRead().rows===185&&__scrollRead().auto==="false"');
    await resize(550,320);await test('narrow wrapping keeps the same retained reading message','__scrollRead().key===61&&__scrollRead().rows===185&&__scrollConsole.list.scrollWidth<=__scrollConsole.list.clientWidth+1');
    await fill(185);if(shot)await shot('console-scroll-fixed-185');
    await test('no target, inspector socket or object polling was added',`__scrollConsole.target===null&&__scrollQueries===1&&(window.__wire?.sockets.length??0)===${saved.sockets}`);
    fs.writeFileSync(root+'/console-scroll-review.json',JSON.stringify({passed:true,checks,realMetro:false,realDevices:false,syntheticOnly:true},null,2));
  } catch(error) {
    fs.writeFileSync(root+'/console-scroll-failure.json',JSON.stringify({error:String(error),checks,state:await state().catch(()=>null)},null,2));throw error;
  } finally {
    await evaluate(`window.__scrollRO?.disconnect();window.__scrollConsole?.destroy();window.__scrollHost?.remove();for(const key of Object.keys(window))if(key.startsWith('__scroll'))delete window[key]`);
    await cdp('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});
  }
}
