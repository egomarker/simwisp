import fs from 'node:fs';
import {ConsoleBuffer} from '../../Resources/Web/js/metro-console.js';

// The same deterministic reference checks run in Node and a real browser.
// No GC timing, RSS thresholds, live Metro or screen content is involved.
export function reviewConsoleRetention(BufferClass) {
  const checks=[],check=(name,passed)=>checks.push({name,passed:passed===true});
  const retained=b=>b.entries.filter(Boolean).reduce((n,v)=>n+v.bytes,0);
  const released=b=>b.entries.slice(0,b.offset).every(v=>v==null)&&retained(b)===b.bytes;
  const count=new BufferClass();
  for(let i=0;i<5001;i++)count.push({sequence:i,text:'row '+i});
  check('count eviction releases referenced entry immediately',released(count));
  check('count order and dropped accounting unchanged',count.values.length===5000&&count.values[0].sequence===1&&count.dropped===1);
  const bytes=new BufferClass();
  for(let i=0;i<1154;i++)bytes.push({sequence:i,text:String.fromCharCode(65+i%26).repeat(40000)});
  check('byte eviction releases all discarded objects before compaction',released(bytes));
  check('byte cap applies to reachable serialized entries',retained(bytes)<=5242880);
  bytes.push({sequence:1154,text:'after compaction'});
  check('compaction retains order/accounting without cleared slots in values',released(bytes)&&bytes.values.every(v=>v&&typeof v.sequence==='number'));
  const trim=new BufferClass();trim.push({sequence:1,text:'x'.repeat(40000)});trim.trim(5242880);
  check('reserved-object trim releases removed entry without another push',released(trim)&&trim.values.length===0&&retained(trim)===0&&trim.dropped===1);
  trim.trim(0);check('repeated trim cannot revive evicted entries',trim.values.length===0&&released(trim));
  const mixed=new BufferClass();
  for(let i=0;i<16000;i++){
    mixed.push({sequence:i,text:i%2?'unicode: \u2603\uD83D\uDE00':'row'});
    if(i%257===0)check('repeated compaction/eviction references '+i,released(mixed));
  }
  check('repeated compaction preserves surviving order',mixed.values.every((v,i)=>v.sequence===11000+i)&&mixed.values.length===5000);
  const before=mixed.bytes,dropped=mixed.dropped;mixed.push({text:'x'.repeat(5242880)});
  check('oversized entry rejection leaves surviving records intact',mixed.bytes===before&&mixed.dropped===dropped+1&&released(mixed));
  mixed.clear();check('clear releases all slots and resets accounting',mixed.entries.length===0&&mixed.offset===0&&mixed.bytes===0&&mixed.dropped===0);
  return {passed:checks.every(c=>c.passed),checks,largeEntryLogicalBytes:bytes.bytes,largeEntryRetainedBytes:retained(bytes)};
}
if(process.argv[1]?.endsWith('/retention.mjs')){
  const report=reviewConsoleRetention(ConsoleBuffer);
  if(process.env.TEST_OUTPUT){fs.mkdirSync(process.env.TEST_OUTPUT,{recursive:true});fs.writeFileSync(process.env.TEST_OUTPUT+'/console-retention-review.json',JSON.stringify(report,null,2));}
  console.log(JSON.stringify(report,null,2));if(!report.passed)process.exitCode=1;
}
