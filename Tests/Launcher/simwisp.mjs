import fs from 'node:fs';import os from 'node:os';import path from 'node:path';import cp from 'node:child_process';import assert from 'node:assert/strict';
const source=fs.readFileSync('simwisp.sh','utf8'),checks=[],red=process.argv.includes('--red'),output=process.argv[2];
// Never run the real project launcher. Every build/open/process command is
// replaced under a private fixture PATH; only copied scripts are executed.
assert(!/(?:^|\s)\/(?:usr\/)?(?:bin|sbin)\/(?:make|open|pkill|pgrep|kill|killall|sleep)\b/m.test(source),'absolute live action would bypass mocks');
assert(!/^\s*(?:kill|killall|osascript)\s/m.test(source),'unexpected live process/UI command');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'simwisp-launcher-tests.'));
const mock=`#!/bin/bash
set -eu
cmd="\${0##*/}"
{ printf '%s\\t%s' "$cmd" "$PWD"; printf '\\t%s' "$@"; printf '\\n'; } >> "$CASE_LOG"
case "$cmd" in
  make) [[ "$CASE_MODE" != build-fails ]] || exit 23 ;;
  id) [[ "$CASE_MODE" != uid-fails ]] || exit 7; printf '61001\\n' ;;
  pkill) case "$CASE_MODE" in no-app|concurrent) exit 1;; signal-fails) exit 2;; esac ;;
  pgrep)
    n=0; [[ ! -f "$CASE_STATE" ]] || read -r n < "$CASE_STATE"; n=$((n+1)); printf '%s\\n' "$n" > "$CASE_STATE"
    case "$CASE_MODE" in stuck|concurrent) exit 0;; query-fails) exit 2;; delayed) [[ "$n" -gt 3 ]] || exit 0;; esac
    exit 1 ;;
  open) [[ "$CASE_MODE" != open-fails ]] || exit 17 ;;
  sleep) : ;;
  *) exit 99 ;;
esac
`;
let next=0;
function run(mode){
 const folder=path.join(root,String(++next)),repo=path.join(folder,'checkout with spaces'),bin=path.join(folder,'mockbin'),outside=path.join(folder,'outside');for(const p of [repo,bin,outside])fs.mkdirSync(p,{recursive:true});fs.writeFileSync(path.join(repo,'simwisp.sh'),source);
 for(const cmd of ['make','open','pkill','pgrep','sleep','id'])fs.writeFileSync(path.join(bin,cmd),mock,{mode:0o700});
 const log=path.join(folder,'events'),p=cp.spawnSync('/bin/bash',[path.join(repo,'simwisp.sh')],{cwd:outside,env:{...process.env,PATH:bin+':'+process.env.PATH,CASE_MODE:mode,CASE_LOG:log,CASE_STATE:path.join(folder,'state')},encoding:'utf8',timeout:10000});
 assert(!p.error,p.error?.message);const events=fs.existsSync(log)?fs.readFileSync(log,'utf8').trim().split('\n').map(s=>{const[cmd,cwd,...args]=s.split('\t');return{cmd,cwd,args}}):[];
 return{...p,events,repo,of:cmd=>events.filter(e=>e.cmd===cmd)};
}
function check(name,value){checks.push({name,passed:!!value});assert(value,name)}
let failure=false;
try{
 const r=run('running');
 check('Existing Simwisp is stopped before opening replacement',r.of('pkill').length===1&&r.events.findIndex(e=>e.cmd==='pkill')<r.events.findIndex(e=>e.cmd==='open'));
 if(!red){
  check('Successful build occurs before termination',r.events[0]?.cmd==='make'&&r.events[0].args.join(' ')==='check');
  check('Termination selects exact current-user Simwisp only',r.of('pkill')[0].args.join(' ')==='-TERM -u 61001 -x Simwisp');
  check('Exit verification selects same exact user and app',r.of('pgrep').every(e=>e.args.join(' ')==='-u 61001 -x Simwisp'));
  check('Launcher works from another cwd and spaces in checkout path',r.events.every(e=>e.cwd===r.repo));
  check('Launch retains app path and LAN arguments',r.of('open').length===1&&r.of('open')[0].args.join(' ')==='build/Simwisp.app --args --lan');
  check('App exit confirmed before open and success propagated',r.status===0&&r.events.findIndex(e=>e.cmd==='pgrep')<r.events.findIndex(e=>e.cmd==='open'));
  check('Immediate exit does not wait unnecessarily',r.of('sleep').length===0);
  const none=run('no-app');check('No existing app is an ordinary successful launch',none.status===0&&none.of('open').length===1);
  const delayed=run('delayed');check('Delayed exit is awaited before launch',delayed.status===0&&delayed.of('pgrep').length===4&&delayed.of('sleep').length===3&&delayed.of('open').length===1);
  check('Wait uses bounded short sleeps',delayed.of('sleep').every(e=>e.args.join(' ')==='0.1'));
  const stuck=run('stuck');check('Stuck old app prevents a duplicate launch',stuck.status!==0&&stuck.of('open').length===0&&/did not exit/.test(stuck.stderr));
  check('Exit wait is bounded at ten seconds',stuck.of('pgrep').length===100&&stuck.of('sleep').length===100);
  const signal=run('signal-fails');check('Signal error aborts instead of opening another app',signal.status===2&&signal.of('open').length===0);
  const query=run('query-fails');check('Process query error is not mistaken for exit',query.status===2&&query.of('open').length===0);
  const build=run('build-fails');check('Build failure preserves old app and never opens new app',build.status===23&&build.events.length===1&&build.of('pkill').length===0&&build.of('open').length===0);
  const uid=run('uid-fails');check('User identification failure sends no signal or launch',uid.status===7&&uid.of('pkill').length===0&&uid.of('open').length===0);
  const open=run('open-fails');check('Open failure is not reported as successful launch',open.status===17);
  const concurrent=run('concurrent');check('App appearing after no-match signal cannot bypass exit gate',concurrent.status!==0&&concurrent.of('open').length===0);
  check('No force-kill or simulator/helper selectors used',r.of('pkill').every(e=>!e.args.includes('-KILL')&&e.args.at(-1)==='Simwisp'));
 }
}catch(error){failure=true;console.error('FAIL: '+error.message)}finally{fs.rmSync(root,{recursive:true,force:true})}
const passed=!failure&&checks.length>0&&checks.every(c=>c.passed);fs.writeFileSync(path.join(output,'launcher.json'),JSON.stringify({passed,checks,fullyMockedCommands:true,realBuildOrAppRestart:false,realProcessSignals:false},null,2)+'\n');console.log(`Launcher checks: ${checks.length}, passed: ${passed}`);process.exit(passed?0:1);
