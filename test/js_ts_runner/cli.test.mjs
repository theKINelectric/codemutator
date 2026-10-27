import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync,spawn} from 'node:child_process';
import {mkdtempSync,rmSync,cpSync,writeFileSync,existsSync,mkdirSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {mapSites} from '../../priv/js_ts_runner/scanner-bridge.mjs';
import {parseRequest} from '../../../js_ts_parser/parse.mjs';
import {readFileSync} from 'node:fs';

import {compilerPath} from './support.mjs';
const root=new URL('../../priv/js_ts_runner/',import.meta.url).pathname;
const fixtureRoot=new URL('../fixtures/js_ts_runner/',import.meta.url).pathname;
function call(request) {
  return spawnSync(process.execPath,[join(root,'bin/runner.mjs')],{input:JSON.stringify(request)+'\n',encoding:'utf8',timeout:10000});
}
function output(result) {
  assert.equal(result.stderr,'');
  const lines=result.stdout.trim().split('\n');
  assert.equal(lines.length,1);
  assert.ok(lines[0].startsWith('CODEMUTATOR_JS_RESULT '));
  assert.ok(Buffer.byteLength(result.stdout)<8000);
  return JSON.parse(lines[0].slice('CODEMUTATOR_JS_RESULT '.length));
}
test('CLI emits one bounded summary and stable baseline, killed and invalid exit codes',t=>{
  const workspaces=mkdtempSync(join(tmpdir(),'mutator-cli-workers-'));
  t.after(()=>rmSync(workspaces,{recursive:true,force:true}));
  const request={protocol:1,source_root:join(fixtureRoot,'strong'),workspace_root:workspaces,compiler_path:compilerPath};
  const baseline=call(request);
  assert.equal(baseline.status,0);
  assert.equal(output(baseline).status,'passed');
  const source=readFileSync(join(request.source_root,'src/client.ts'),'utf8');
  const site=mapSites('src/client.ts',source,parseRequest({protocol:1,filename:'src/client.ts',source})).find(s=>s.original==='>=');
  const killed=call({...request,mutation:site});
  assert.equal(killed.status,21);
  assert.equal(output(killed).reason,'assertion');
  const invalid=call({...request,mutation:{...site,replacement:'+'}});
  assert.equal(invalid.status,20);
  assert.equal(output(invalid).status,'invalid');
  const syntaxInvalid=call({...request,mutation:{...site,replacement:'('}});
  assert.equal(syntaxInvalid.status,20);
  assert.equal(output(syntaxInvalid).status,'invalid');
});
test('CLI rejects invalid protocol and never exposes stack traces',()=>{
  const result=call({protocol:9});
  assert.equal(result.status,22);
  assert.equal(output(result).reason,'invalid_request');
});
test('service worker CLI runs an existing physical lane without another copy',t=>{
  const workspace=mkdtempSync(join(tmpdir(),'mutator-service-worker-'));
  t.after(()=>rmSync(workspace,{recursive:true,force:true}));
  cpSync(join(fixtureRoot,'strong'),join(workspace,'project'),{recursive:true});
  const result=spawnSync(process.execPath,[join(root,'bin/runner.mjs'),'--worker',join(workspace,'project'),'--compiler',compilerPath,'--timeout','5000'],{encoding:'utf8',timeout:10000});
  assert.equal(result.status,0);
  assert.equal(output(result).status,'passed');
  assert.equal(output(result).phase,'worker');
});
test('outer service TERM reaches the wrapper owned runner and grandchild groups',async t=>{
  const workspace=mkdtempSync(join(tmpdir(),'mutator-service-deadline-'));
  t.after(()=>rmSync(workspace,{recursive:true,force:true}));
  const project=join(workspace,'project');mkdirSync(join(project,'test'),{recursive:true});
  const started=join(workspace,'started.marker');
  const leaked=join(workspace,'grandchild-lived.marker');
  writeFileSync(join(project,'.codemutator.json'),JSON.stringify({schemaVersion:1,language:'javascript-typescript',runner:{kind:'node-test',files:['test/hang.mjs']},typecheck:{kind:'none'},source:{include:['src/**/*.mjs'],exclude:[]}}));
  writeFileSync(join(project,'test/hang.mjs'),`import test from 'node:test';import {spawn} from 'node:child_process';import {writeFileSync} from 'node:fs';test('hang',async()=>{spawn(process.execPath,['-e',${JSON.stringify(`setTimeout(()=>require('node:fs').writeFileSync(${JSON.stringify(leaked)},'bad'),1000)`)}]);writeFileSync(${JSON.stringify(started)},'yes');setTimeout(()=>process.exit(0),1500);await new Promise(()=>{});});\n`);
  const child=spawn(process.execPath,[join(root,'bin/runner.mjs'),'--worker',project,'--timeout','5000'],{stdio:'ignore'});
  t.after(()=>{try{child.kill('SIGKILL');}catch{}});
  const exited=new Promise(resolve=>child.on('close',(code,signal)=>resolve({code,signal})));
  const deadline=Date.now()+3000;
  while(!existsSync(started) && Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,20));
  assert.ok(existsSync(started),'fixture began executing in worker');
  child.kill('SIGTERM');
  await exited;
  await new Promise(resolve=>setTimeout(resolve,1100));
  assert.equal(existsSync(leaked),false,'grandchild must not outlive outer service timeout');
});
test('service mode descendants stay in the recorded group after wrapper SIGKILL',async t=>{
  const workspace=mkdtempSync(join(tmpdir(),'mutator-service-kill-'));
  t.after(()=>rmSync(workspace,{recursive:true,force:true}));
  const project=join(workspace,'project');mkdirSync(join(project,'test'),{recursive:true});
  const started=join(workspace,'started.marker');
  const leaked=join(workspace,'grandchild-lived.marker');
  writeFileSync(join(project,'.codemutator.json'),JSON.stringify({schemaVersion:1,language:'javascript-typescript',runner:{kind:'node-test',files:['test/hang.mjs']},typecheck:{kind:'none'},source:{include:['src/**/*.mjs'],exclude:[]}}));
  writeFileSync(join(project,'test/hang.mjs'),`import test from 'node:test';import {spawn} from 'node:child_process';import {writeFileSync} from 'node:fs';test('hang',async()=>{spawn(process.execPath,['-e',${JSON.stringify(`setTimeout(()=>require('node:fs').writeFileSync(${JSON.stringify(leaked)},'bad'),1000)`)}]);writeFileSync(${JSON.stringify(started)},'yes');setTimeout(()=>process.exit(0),1500);await new Promise(()=>{});});\n`);
  const child=spawn(process.execPath,[join(root,'bin/runner.mjs'),'--worker',project,'--service-owned-group','--timeout','5000'],{stdio:'ignore',detached:true});
  t.after(()=>{try{process.kill(-child.pid,'SIGKILL');}catch{}});
  const exited=new Promise(resolve=>child.on('close',resolve));
  const deadline=Date.now()+3000;
  while(!existsSync(started) && Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,20));
  assert.ok(existsSync(started),'service fixture began execution');
  process.kill(child.pid,'SIGKILL');
  await exited;
  // The Phoenix ProcessRunner performs this recorded-PGID cleanup in after.
  try{process.kill(-child.pid,'SIGKILL');}catch{}
  await new Promise(resolve=>setTimeout(resolve,1100));
  assert.equal(existsSync(leaked),false,'recorded outer group cleanup must reach all test descendants');
});
test('service mode leaves project deadlines to the outer service runner',t=>{
  const workspace=mkdtempSync(join(tmpdir(),'mutator-service-time-'));
  t.after(()=>rmSync(workspace,{recursive:true,force:true}));
  mkdirSync(join(workspace,'project/test'),{recursive:true});
  writeFileSync(join(workspace,'project/.codemutator.json'),JSON.stringify({schemaVersion:1,language:'javascript-typescript',runner:{kind:'node-test',files:['test/wait.mjs']},typecheck:{kind:'none'},source:{include:['src/**/*.mjs'],exclude:[]}}));
  writeFileSync(join(workspace,'project/test/wait.mjs'),"import test from 'node:test';test('wait',async()=>{await new Promise(resolve=>setTimeout(resolve,100));});\n");
  const result=spawnSync(process.execPath,[join(root,'bin/runner.mjs'),'--worker',join(workspace,'project'),'--service-owned-group','--timeout','50'],{encoding:'utf8',timeout:5000});
  assert.equal(result.status,0);
  assert.equal(output(result).status,'passed');
});
