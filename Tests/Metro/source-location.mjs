import fs from 'node:fs';

// Production renderer, synthetic entries only: no target or inspector connection.
export async function reviewSourceLocations({root,cdp,evaluate,check,delay,shot}) {
  const url='http://127.0.0.1:8081/index.bundle//&platform=ios&dev=true&lazy=true&minify=false&inlineSourceMap=false&modulesOnly=false&runModule=true&excludeSource=true&sourcePaths=url-server&app=com.childrensmercy.guidelines';
  const source={url,line:1174,column:39};
  const frames=[{function:'anonymous',url,line:1174,column:39},{function:'anonymous',url,line:1858,column:34},{function:'anonymous',url,line:77717,column:28},{function:'asyncGeneratorStep',url,line:24751,column:18}];
  const entry={local_key:1,sequence:1,level:'log',text:'Home – ScreenView',timestamp_ms:new Date('2026-10-14T19:38:15').getTime(),source,stack:frames};
  const expectedSource=url+':1175:40',expectedStack=frames.map(f=>`${f.function} (${f.url}:${f.line+1}:${f.column+1})`).join('\n');
  const selector='#source-location-review';let checks=0;const verify=async(name,expression)=>{try{await check('Source location: '+name,expression);checks++;}catch(error){fs.writeFileSync(root+'/source-location-failure.json',JSON.stringify({name,expression,ui:await evaluate(`(()=>{const r=document.querySelector('#source-location-review .console-row');return{row:r?.outerHTML,focus:document.activeElement?.outerHTML,head:r?.firstElementChild.getBoundingClientRect().toJSON(),details:r?.querySelector('details')?.getBoundingClientRect().toJSON()}})()`)},null,2));throw error;}};
  const key=async(name,code,n)=>{await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:name,code,windowsVirtualKeyCode:n,text:name==='Enter'?'\r':' '});await cdp('Input.dispatchKeyEvent',{type:'keyUp',key:name,code,windowsVirtualKeyCode:n});await delay(80);};
  const pointer=async(s,touch=false)=>{const p=await evaluate(`(()=>{const r=document.querySelector(${JSON.stringify(s)}).getBoundingClientRect();return{x:r.x+r.width/2,y:r.y+r.height/2}})()`);if(touch){await cdp('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[p]});await cdp('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});}else{await cdp('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...p});await cdp('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...p});}await delay(80);};
  const q=s=>`document.querySelector(${JSON.stringify(selector+' '+s)})`;
  const row=q('.console-row'),details=q('.console-details'),link=q('.console-source-link'),summary=q('summary');
  const capture=async(name)=>{const clip=await evaluate(`(()=>{const r=${row}.getBoundingClientRect();return{x:r.x,y:r.y,width:r.width,height:r.height,scale:1}})()`);const r=await cdp('Page.captureScreenshot',{format:'png',clip,captureBeyondViewport:false});const bytes=Buffer.from(r.data,'base64');fs.writeFileSync(root+'/'+name+'.png',bytes);return bytes;};
  const original=await evaluate('({theme:document.documentElement.dataset.theme,sockets:window.__wire.sockets.length})');
  const baseline=process.env.METRO_SOURCE_BASELINE;
  try {
    await evaluate(`(async()=>{const{MetroConsole}=await import('/js/metro-console.js');window.__sourceLocationModule=MetroConsole;window.__sourceLocationEntry=${JSON.stringify(entry)};window.__sourceLocationMount=Class=>{const e=document.createElement('div');e.id='source-location-review';e.style.cssText='position:fixed;left:8px;top:8px;width:calc(100vw - 16px);height:400px;padding:8px;background:var(--bg-elevated);color:var(--text-primary);z-index:99999;display:flex;flex-direction:column;overflow:hidden';document.body.append(e);const c=new Class(e,{deviceId:'synthetic-source-review',binding:{}});c.buffer.push(window.__sourceLocationEntry);c.setVisible(true);return c};window.__sourceLocation=window.__sourceLocationMount(MetroConsole)})()`);
    await verify('short one-based location, not a second source line',`${link}.textContent==='1175:40'&&!${link}.hidden&&${details}.hidden&&!${details}.open&&${row}.innerText.includes('1175:40')&&!${row}.innerText.includes('http://')`);
    await verify('button controls its own disclosure',`${link}.type==='button'&&${link}.getAttribute('aria-controls')===${details}.id&&${link}.getAttribute('aria-expanded')==='false'&&${link}.getAttribute('aria-label')==='Show source details 1175:40'&&${link}.title===${JSON.stringify(expectedSource)}`);
    await verify('right aligned without stretching or moving message',`(()=>{const h=${q('.console-row-head')}.getBoundingClientRect(),l=${link}.getBoundingClientRect(),m=${q('.console-text')}.getBoundingClientRect();return Math.abs(l.right-h.right)<1&&m.right<l.left&&l.top<h.bottom&&getComputedStyle(${link}).textDecorationLine==='underline'})()`);
    const doc=await cdp('DOM.getDocument'),node=await cdp('DOM.querySelector',{nodeId:doc.root.nodeId,selector:selector+' .console-source-link'}),ax=await cdp('Accessibility.getPartialAXTree',{nodeId:node.nodeId,fetchRelatives:false});
    await verify('accessible native button with collapsed disclosure state',JSON.stringify(ax.nodes.some(n=>n.role?.value==='button'&&n.name?.value==='Show source details 1175:40'&&n.properties?.some(p=>p.name==='expanded'&&p.value?.value===false))));
    await evaluate(`${link}.focus()`);await key('Enter','Enter',13);
    await verify('Enter shows original full URL and stack below the row',`${details}.open&&!${details}.hidden&&${link}.hidden&&${summary}.textContent===${JSON.stringify(expectedSource)}&&${q('pre')}.textContent===${JSON.stringify(expectedStack)}&&${details}.parentElement===${row}&&${details}.getBoundingClientRect().top>=${q('.console-row-head')}.getBoundingClientRect().bottom&&document.activeElement===${summary}`);
    await evaluate('window.__sourceLocation.render()');await delay(80);
    await verify('expanded state and summary keyboard focus survive render',`${details}.open&&${link}.hidden&&document.activeElement===${summary}`);
    await key(' ','Space',32);
    await verify('Space on original summary collapses and returns short link/focus',`!${details}.open&&${details}.hidden&&!${link}.hidden&&document.activeElement===${link}`);
    await evaluate('window.__sourceLocation.render()');await delay(80);
    await verify('collapsed state and link keyboard focus survive render',`!${details}.open&&!${link}.hidden&&document.activeElement===${link}`);
    await key(' ','Space',32);await verify('Space activates the short button',`${details}.open&&${link}.hidden`);
    await key('Enter','Enter',13);await verify('Enter collapses the original summary',`!${details}.open&&!${link}.hidden&&document.activeElement===${link}`);
    await pointer(selector+' .console-source-link');await verify('mouse click opens details',`${details}.open&&${link}.hidden`);
    await pointer(selector+' summary');await verify('mouse click on unchanged full summary collapses',`!${details}.open&&${details}.hidden&&!${link}.hidden`);
    await evaluate(`${link}.click();window.__sourceLocation.render()`);await delay(80);
    await verify('immediate re-render after clicking retains expansion',`${details}.open&&${link}.hidden`);
    await evaluate(`${summary}.click();window.__sourceLocation.render()`);await delay(80);
    await verify('immediate re-render after native collapse retains collapse',`!${details}.open&&!${link}.hidden`);
    await evaluate(`window.__sourceLocation.buffer.push({...window.__sourceLocationEntry,local_key:2,sequence:2,text:'No source metadata',source:null,stack:[]});window.__sourceLocation.buffer.push({...window.__sourceLocationEntry,local_key:3,sequence:3,text:'Stack only',source:null});window.__sourceLocation.render()`);await delay(80);
    await verify('no-source messages have no toggle or empty details',`!${q('[data-sequence="2"]')}.querySelector('.console-source-link,details')`);
    await verify('stack-only entries retain meaningful Stack fallback',`${q('[data-sequence="3"] .console-source-link')}.textContent==='Stack'&&${q('[data-sequence="3"] details')}.hidden`);
    await evaluate(`${q('[data-sequence="3"] .console-source-link')}.click()`);await delay(80);
    await verify('stack-only expanded summary remains unchanged',`${q('[data-sequence="3"] summary')}.textContent==='Stack'&&${q('[data-sequence="3"] pre')}.textContent===${JSON.stringify(expectedStack)}`);
    await evaluate(`${link}.click();window.__sourceLocation.buffer.push({...window.__sourceLocationEntry,local_key:4,sequence:1,text:'Runtime sequence restarted',source:null,stack:[]});window.__sourceLocation.render()`);await delay(80);
    await verify('append/sequence restart preserve expansion by local key',`${details}.open&&${q('[data-sequence="4"]')}.textContent.includes('Runtime sequence restarted')`);
    await evaluate('window.__sourceLocation.setVisible(false);window.__sourceLocation.setVisible(true)');await delay(80);
    await verify('hide/show retains expanded state',`${details}.open&&${link}.hidden`);
    await evaluate(`window.__sourceLocation.buffer.clear();window.__sourceLocation.buffer.push({...window.__sourceLocationEntry,text:${JSON.stringify('Home – ScreenView\nSecond line ')}+('unbroken'.repeat(80))});window.__sourceLocation.render()`);await delay(80);
    for(const theme of ['light','dark']) {
      await evaluate(`document.documentElement.dataset.theme=${JSON.stringify(theme)}`);
      for(const size of [{name:'desktop',width:1440,height:1000},{name:'tablet',width:1024,height:768},{name:'small-phone',width:320,height:568}]) {
        await cdp('Emulation.setDeviceMetricsOverride',{...size,name:undefined,deviceScaleFactor:1,mobile:size.width<700});
        await cdp('Emulation.setTouchEmulationEnabled',{enabled:size.width<700});
        await evaluate(`if(${details}.open)${summary}.click()`);await delay(80);
        await verify(theme+'/'+size.name+' collapsed wrapping stays right and inside viewport',`(()=>{const h=${q('.console-row-head')}.getBoundingClientRect(),l=${link}.getBoundingClientRect(),m=${q('.console-text')}.getBoundingClientRect(),r=${row}.getBoundingClientRect();return !${link}.hidden&&Math.abs(l.right-h.right)<1&&m.right<=l.left&&r.right<=innerWidth&&r.left>=0&&${q('.console-list')}.scrollWidth<=${q('.console-list')}.clientWidth+1})()`);
        if(size.name!=='tablet')await shot('source-'+theme+'-'+size.name+'-collapsed');
        await pointer(selector+' .console-source-link',size.width<700);
        await verify(theme+'/'+size.name+' expands original full details',`${details}.open&&${link}.hidden&&${summary}.textContent===${JSON.stringify(expectedSource)}&&getComputedStyle(${details}).marginLeft==='5px'&&getComputedStyle(${details}).fontSize==='11px'&&getComputedStyle(${q('pre')}).maxHeight==='120px'&&${q('.console-list')}.scrollWidth<=${q('.console-list')}.clientWidth+1`);
        if(size.name!=='tablet')await shot('source-'+theme+'-'+size.name+'-expanded');
      }
    }
    await cdp('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});await cdp('Emulation.setTouchEmulationEnabled',{enabled:false});
    await evaluate('window.__sourceLocation.buffer.clear();window.__sourceLocation.buffer.push(window.__sourceLocationEntry);window.__sourceLocation.render()');await delay(80);
    if(baseline) {
      const beforeCSS=fs.readFileSync(baseline+'/Resources/Web/css/metro-console.css','utf8');
      await verify('all original CSS declarations unchanged',JSON.stringify(fs.readFileSync('Resources/Web/css/metro-console.css','utf8').split('\n').filter(l=>!l.startsWith('.console-source-link')).join('\n')===beforeCSS));
      for(const theme of ['light','dark'])for(const width of [1440,320]) {
        await cdp('Emulation.setDeviceMetricsOverride',{width,height:1000,deviceScaleFactor:1,mobile:false});
        await evaluate(`document.documentElement.dataset.theme=${JSON.stringify(theme)};${details}.open=true;document.activeElement?.blur()`);await delay(80);
        const after=await capture('source-'+theme+'-'+width+'-expanded-after');
        await evaluate(`window.__sourceLocation.destroy();document.querySelector(${JSON.stringify(selector)}).remove();window.__oldMetroSheet=[...document.querySelectorAll('link[rel=stylesheet]')].find(l=>l.href.endsWith('/css/metro-console.css'));window.__oldMetroSheet.disabled=true;window.__beforeMetroStyle=document.createElement('style');window.__beforeMetroStyle.textContent=${JSON.stringify(beforeCSS)};document.head.append(window.__beforeMetroStyle)`);
        await evaluate(`(async()=>{const{MetroConsole}=await import('/js/metro-console-before.js');window.__sourceLocation=window.__sourceLocationMount(MetroConsole);${details}.open=true})()`);await delay(80);
        const before=await capture('source-'+theme+'-'+width+'-expanded-before');
        await verify(theme+'/'+width+' expanded pixels match pre-edit renderer exactly',JSON.stringify(before.equals(after)));
        await evaluate(`window.__sourceLocation.destroy();document.querySelector(${JSON.stringify(selector)}).remove();window.__beforeMetroStyle.remove();window.__oldMetroSheet.disabled=false;window.__sourceLocation=window.__sourceLocationMount(window.__sourceLocationModule);${details}.open=true`);await delay(80);
      }
    }
    await evaluate(`const e=document.createElement('div');e.id='source-location-second';document.body.append(e);window.__sourceLocationSecond=new window.__sourceLocationModule(e,{deviceId:'second',binding:{}});window.__sourceLocationSecond.buffer.push(window.__sourceLocationEntry);window.__sourceLocationSecond.setVisible(true)`);
    await verify('multiple consoles cannot cross-toggle or duplicate disclosure IDs',`(()=>{const second=document.querySelector('#source-location-second details');return ${details}.id!==second.id&&document.querySelector('#source-location-second button.console-source-link').getAttribute('aria-controls')===second.id})()`);
    await evaluate(`document.querySelector('#source-location-second button.console-source-link').click()`);await delay(80);
    await verify('second console toggle leaves first expansion alone',`${details}.open&&document.querySelector('#source-location-second details').open`);
    await evaluate(`window.__sourceLocation.buffer.push({...window.__sourceLocationEntry,local_key:5,sequence:5,source:{url:'<img src=x onerror=window.__injected=true>',line:0,column:0},stack:[{function:'<script>unsafe</script>',url:'<svg onload=window.__injected=true>',line:0,column:0}]});window.__sourceLocation.render()`);await delay(80);
    await verify('text/URL/stack remain escaped and zero-based zero remains 1:1',`${q('[data-sequence="5"] .console-source-link')}.textContent==='1:1'&&!${row}.parentElement.querySelector('img,svg,script')&&!window.__injected`);
    await evaluate(`window.__sourceLocation.toolbar.querySelector('[aria-label="Clear local console"]').click();window.__sourceLocation.buffer.push({...window.__sourceLocationEntry,text:'New local content after clear'});window.__sourceLocation.render()`);await delay(80);
    await verify('Clear forgets expansion, no stale toggle repopulates state',`!${details}.open&&!${link}.hidden`);
    await evaluate('window.__sourceLocation.destroy()');await delay(80);
    await verify('destroy removes all row controls without inspector connection',`!document.querySelector(${JSON.stringify(selector)}).children.length&&window.__wire.sockets.length===${original.sockets}`);
    fs.writeFileSync(root+'/source-location-review.json',JSON.stringify({passed:true,checks,expandedPixelParity:!!baseline,realMetro:false,realDevices:false},null,2));
  } finally {
    await evaluate(`window.__sourceLocation?.destroy();window.__sourceLocationSecond?.destroy();document.querySelector(${JSON.stringify(selector)})?.remove();document.querySelector('#source-location-second')?.remove();window.__beforeMetroStyle?.remove();if(window.__oldMetroSheet)window.__oldMetroSheet.disabled=false;document.documentElement.dataset.theme=${JSON.stringify(original.theme)};for(const k of Object.keys(window))if(k.startsWith('__sourceLocation'))delete window[k]`);
    await cdp('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});await cdp('Emulation.setTouchEmulationEnabled',{enabled:false});
  }
}
