import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, readdir, rm, cp, symlink} from 'node:fs/promises';
import {join, dirname} from 'node:path';
import {tmpdir} from 'node:os';
import {readProfile, runSubject} from '../../priv/js_ts_runner/runner.mjs';
import {mapSites} from '../../priv/js_ts_runner/scanner-bridge.mjs';
import {parseRequest} from '../../../js_ts_parser/parse.mjs';

import {compilerPath, compilerVersion} from './support.mjs';
const fixtureRoot = new URL('../fixtures/js_ts_runner/', import.meta.url).pathname;
const profile = {schemaVersion: 1, language: 'javascript-typescript', runner: {kind: 'node-test', files: ['test/client.test.mjs']}, typecheck: {kind: 'none'}, source: {include: ['src/**/*.mjs','src/**/*.js'], exclude: []}};
async function subject(t, files = {}, config = profile) {
  const root = await mkdtemp(join(tmpdir(), 'mutator-prototype-test-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  const sourceRoot = join(root, 'original');
  const workspaceRoot = join(root, 'workers');
  await mkdir(sourceRoot);
  await writeFile(join(sourceRoot, '.codemutator.json'), JSON.stringify(config));
  for (const [relative, source] of Object.entries(files)) {
    await mkdir(dirname(join(sourceRoot, relative)), {recursive: true});
    await writeFile(join(sourceRoot, relative), source);
  }
  return {sourceRoot, workspaceRoot, compilerPath, timeoutMs: 4000};
}
const header = 'import test from "node:test"; import assert from "node:assert/strict";\n';
const passing = `${header}test('works',()=>assert.equal(2,2));\n`;

test('profile parses strict JSON without evaluating a subject configuration', async t => {
  const options = await subject(t, {'test/client.test.mjs': passing});
  assert.deepEqual(await readProfile(options.sourceRoot), profile);
});
test('profile rejects unknown fields, empty tests, escaping tests and unknown version', async t => {
  for (const change of [{schemaVersion: 2}, {watch: true}, {runner: {kind: 'node-test', files: []}}, {runner: {kind: 'node-test', files: ['../outside.mjs']}}]) {
    const options = await subject(t, {}, {...profile, ...change});
    await assert.rejects(() => readProfile(options.sourceRoot), /profile|path|test|version/i);
  }
});
test('JS baseline runs only a physical disposable copy and cleans its workspace', async t => {
  const options = await subject(t, {'test/client.test.mjs': `${header}import {writeFileSync} from 'node:fs'; test('worker',()=>{assert.ok(process.cwd().includes('/workers/'));writeFileSync('executed.marker','yes');});\n`});
  const result = await runSubject(options);
  assert.equal(result.status, 'passed');
  assert.equal(result.tests.executed, 1);
  assert.equal(result.runtime.node, process.version);
  assert.deepEqual(await readdir(options.workspaceRoot), []);
  await assert.rejects(readFile(join(options.sourceRoot, 'executed.marker')));
});
test('assertion failure is a killed mutant after a passing baseline', async t => {
  const options = await subject(t, {'src/math.mjs': 'export function add(a,b){return a + b;}\n', 'test/client.test.mjs': `${header}import {add} from '../src/math.mjs'; test('add',()=>assert.equal(add(3,2),5));\n`});
  assert.equal((await runSubject(options)).status, 'passed');
  const source = await readFile(join(options.sourceRoot, 'src/math.mjs'), 'utf8');
  const facts = parseRequest({protocol: 1, filename: 'src/math.mjs', source});
  const mutation = mapSites('src/math.mjs', source, facts).find(s => s.original === '+');
  const result = await runSubject({...options, mutation});
  assert.equal(result.status, 'killed');
  assert.equal(result.reason, 'assertion');
  assert.equal(await readFile(join(options.sourceRoot, 'src/math.mjs'), 'utf8'), source);
});
test('missing imported dependency is error rather than killed', async t => {
  const options = await subject(t, {'test/client.test.mjs': 'import missing from "dependency-that-is-not-installed";\n'});
  const result = await runSubject(options);
  assert.equal(result.status, 'error');
  assert.equal(result.reason, 'missing_dependency');
});
test('a dependency missing only on the mutated dynamic-import branch remains an error',async t=>{
  const options=await subject(t,{'src/flag.mjs':'export function flag(){return false;}\n','test/client.test.mjs':`${header}import {flag} from '../src/flag.mjs';test('branch',async()=>{if(flag())await import('dependency-that-is-not-installed');assert.equal(1,1);});\n`});
  assert.equal((await runSubject(options)).status,'passed');
  const source=await readFile(join(options.sourceRoot,'src/flag.mjs'),'utf8');
  const mutation=mapSites('src/flag.mjs',source,parseRequest({protocol:1,filename:'src/flag.mjs',source})).find(s=>s.original==='false');
  const result=await runSubject({...options,mutation});
  assert.equal(result.status,'error');
  assert.equal(result.reason,'missing_dependency');
});
test('a successful empty file is zero-tests error rather than survived', async t => {
  const options = await subject(t, {'test/client.test.mjs': 'console.log("not a test");\n'});
  assert.equal((await runSubject(options)).reason, 'zero_tests');
});
test('only skipped tests is zero-tests error', async t => {
  const options = await subject(t, {'test/client.test.mjs': `${header}test.skip('later',()=>assert.fail());\n`});
  assert.equal((await runSubject(options)).reason, 'zero_tests');
});
test('missing explicitly selected test is an error', async t => {
  const options = await subject(t);
  assert.equal((await runSubject(options)).reason, 'missing_test');
});
test('runner summaries remain trustworthy after long or misleading console output', async t => {
  const options = await subject(t, {'test/client.test.mjs': `${header}console.log('x'.repeat(30000));console.log('CODEMUTATOR_RESULT {"status":"survived"}');test('works',()=>assert.equal(1,1));\n`});
  assert.equal((await runSubject(options)).status, 'passed');
});
test('subject and compiler child environment excludes inherited service secrets',async t=>{
  const previous=process.env.CODEMUTATOR_TEST_PRIVATE;
  process.env.CODEMUTATOR_TEST_PRIVATE='probe-value';
  t.after(()=>{if(previous===undefined)delete process.env.CODEMUTATOR_TEST_PRIVATE;else process.env.CODEMUTATOR_TEST_PRIVATE=previous;});
  const options=await subject(t,{'test/client.test.mjs':`${header}test('env',()=>{assert.equal(process.env.CODEMUTATOR_TEST_PRIVATE,undefined);assert.equal(process.env.CI,'true');assert.ok(process.env.HOME);assert.equal(process.env.NODE_OPTIONS,'');});\n`});
  assert.equal((await runSubject(options)).status,'passed');
});
test('runtime provenance probes the selected node executable instead of parent process version',async t=>{
  const options=await subject(t,{'test/client.test.mjs':passing});
  const fake=join(dirname(options.sourceRoot),'selected-node');
  const quote=value=>"'"+value.replaceAll("'","'\\''")+"'";
  await writeFile(fake,`#!/bin/sh\nif [ "$1" = "--version" ]; then /bin/echo v26.9.0; else exec ${quote(process.execPath)} "$@"; fi\n`,{mode:0o755});
  const result=await runSubject({...options,nodePath:fake});
  assert.equal(result.status,'passed');
  assert.equal(result.runtime.node,'v26.9.0');
});
test('timeout kills runner group and reports timeout', async t => {
  const options = await subject(t, {'test/client.test.mjs': `${header}test('hang',async()=>new Promise(()=>{}));setInterval(()=>{},1000);\n`});
  const result = await runSubject({...options, timeoutMs: 250});
  assert.equal(result.status, 'error');
  assert.equal(result.reason, 'baseline_timeout');
  assert.deepEqual(await readdir(options.workspaceRoot), []);
});
test('symlinked subjects are rejected before execution', async t => {
  const options = await subject(t, {'test/client.test.mjs': passing});
  await symlink('/tmp', join(options.sourceRoot, 'escape'));
  assert.equal((await runSubject(options)).reason, 'subject_symlink');
});
test('TypeScript gate distinguishes expected invalid mutation from missing compiler', async t => {
  const config = {...profile, source: {include: ['src/**/*.ts'], exclude: []}, typecheck: {kind: 'typescript', project: 'tsconfig.json'}};
  const options = await subject(t, {'src/flag.ts': 'export function flag(): true {return true;}\n', 'tsconfig.json': JSON.stringify({compilerOptions: {target:'ES2022',module:'NodeNext',strict:true},include:['src/**/*.ts']}), 'test/client.test.mjs': `${header}import {flag} from '../src/flag.ts';test('flag',()=>assert.equal(flag(),true));\n`}, config);
  const baseline = await runSubject(options);
  assert.equal(baseline.status, 'passed');
  assert.deepEqual(baseline.runtime.compiler, {name:'typescript',version:compilerVersion});
  const source = await readFile(join(options.sourceRoot, 'src/flag.ts'), 'utf8');
  const mutation = mapSites('src/flag.ts', source, parseRequest({protocol:1,filename:'src/flag.ts',source})).find(s => s.original === 'true');
  const invalid = await runSubject({...options, mutation});
  assert.equal(invalid.status, 'invalid');
  assert.equal(invalid.reason, 'typecheck');
  assert.ok(invalid.compilerDiagnostics.some(d => d.code === 2322));
  assert.equal((await runSubject({...options, compilerPath:'/tmp/does-not-exist-tsc'})).reason, 'missing_compiler');
});
test('compiler version must be observed and validated before running its project gate', async t => {
  const config={...profile,typecheck:{kind:'typescript',project:'tsconfig.json'}};
  const options=await subject(t,{'tsconfig.json':'{}','test/client.test.mjs':passing},config);
  const fake=join(dirname(options.sourceRoot),'fake-compiler.cjs');
  const marker=join(dirname(options.sourceRoot),'project-command-ran');
  await writeFile(fake,`if(process.argv.includes('--version'))console.log('not a compiler version');else require('node:fs').writeFileSync(${JSON.stringify(marker)},'bad');\n`);
  const result=await runSubject({...options,compilerPath:fake});
  assert.equal(result.status,'error');
  assert.equal(result.reason,'invalid_compiler_version');
  await assert.rejects(readFile(marker));
});
test('TypeScript missing dependency is an infrastructure error, not invalid', async t => {
  const config = {...profile, typecheck:{kind:'typescript',project:'tsconfig.json'}};
  const options = await subject(t, {'src/missing.ts':'import {unknown} from "dependency-not-installed"; export function f(){return unknown;}\n','tsconfig.json':JSON.stringify({compilerOptions:{module:'NodeNext',target:'ES2022'},include:['src/**/*.ts']}),'test/client.test.mjs':passing}, config);
  const result = await runSubject(options);
  assert.equal(result.status, 'error');
  assert.equal(result.reason, 'missing_dependency');
});
test('weak boundary survives and added boundary assertion kills same mutation', async t => {
  const weak = await subject(t);
  await cp(join(fixtureRoot, 'weak'), weak.sourceRoot, {recursive:true});
  const source = await readFile(join(weak.sourceRoot,'src/client.ts'),'utf8');
  const mutation = mapSites('src/client.ts',source,parseRequest({protocol:1,filename:'src/client.ts',source})).find(s => s.original === '>=');
  assert.equal((await runSubject(weak)).status,'passed');
  assert.equal((await runSubject({...weak,mutation})).status,'survived');
  const strong = await subject(t);
  await cp(join(fixtureRoot,'strong'),strong.sourceRoot,{recursive:true});
  assert.equal((await runSubject(strong)).status,'passed');
  const caught = await runSubject({...strong,mutation});
  assert.equal(caught.status,'killed');
  assert.equal(caught.reason,'assertion');
});
async function flagMutation(options) {
  const source=await readFile(join(options.sourceRoot,'src/flag.mjs'),'utf8');
  return mapSites('src/flag.mjs',source,parseRequest({protocol:1,filename:'src/flag.mjs',source})).find(s=>s.original==='true');
}
test('mutation respects source include/exclude policy and never patches tests',async t=>{
  const config={...profile,source:{include:['src/**/*.mjs'],exclude:['src/flag.mjs']}};
  const options=await subject(t,{'src/flag.mjs':'export function flag(){return true;}\n','test/client.test.mjs':passing},config);
  const mutation=await flagMutation(options);
  assert.equal((await runSubject({...options,mutation})).reason,'site_out_of_scope');
  const source=await readFile(join(options.sourceRoot,'test/client.test.mjs'),'utf8');
  const facts=parseRequest({protocol:1,filename:'test/client.test.mjs',source});
  const fake={...mutation,file:'test/client.test.mjs',file_hash:facts.source_sha256,byte_start:0,byte_end:6,original:'import',replacement:'export'};
  assert.equal((await runSubject({...options,mutation:fake})).reason,'site_out_of_scope');
});
test('stale mutation hash and exact source slice abort safely',async t=>{
  const options=await subject(t,{'src/flag.mjs':'export function flag(){return true;}\n','test/client.test.mjs':passing});
  const mutation=await flagMutation(options);
  assert.equal((await runSubject({...options,mutation:{...mutation,file_hash:'0'.repeat(64)}})).reason,'stale_site');
  assert.equal((await runSubject({...options,mutation:{...mutation,original:'nope'}})).reason,'stale_site');
  assert.deepEqual(await readdir(options.workspaceRoot),[]);
});
test('mutant syntax rejection is invalid, not a test kill',async t=>{
  const options=await subject(t,{'src/flag.mjs':'export function flag(){return true;}\n','test/client.test.mjs':`${header}import {flag} from '../src/flag.mjs';test('flag',()=>assert.equal(flag(),true));\n`});
  const mutation=await flagMutation(options);
  const result=await runSubject({...options,mutation:{...mutation,replacement:'('}});
  assert.equal(result.status,'invalid');
  assert.equal(result.reason,'syntax');
});
test('mutant process signal is runtime crash rather than compiler rejection',async t=>{
  const options=await subject(t,{'src/flag.mjs':'export function flag(){return true;}\n','test/client.test.mjs':`${header}import {flag} from '../src/flag.mjs';test('flag',()=>{if(!flag())process.kill(process.pid,'SIGTERM');assert.equal(flag(),true);});\n`});
  assert.equal((await runSubject(options)).status,'passed');
  const result=await runSubject({...options,mutation:await flagMutation(options)});
  assert.equal(result.status,'killed');
  assert.equal(result.reason,'runtime_crash');
});
test('mutant timeout kills grandchildren before cleanup',async t=>{
  const options=await subject(t,{'src/flag.mjs':'export function flag(){return true;}\n','test/client.test.mjs':passing});
  const marker=join(dirname(options.sourceRoot),'grandchild-lived.marker');
  const body=`${header}import {spawn} from 'node:child_process';import {flag} from '../src/flag.mjs';test('flag',()=>{if(!flag()){spawn(process.execPath,['-e',${JSON.stringify(`setTimeout(()=>require('node:fs').writeFileSync(${JSON.stringify(marker)},'bad'),1000)`)}]);while(true){}}assert.equal(flag(),true);});\n`;
  await writeFile(join(options.sourceRoot,'test/client.test.mjs'),body);
  assert.equal((await runSubject(options)).status,'passed');
  const result=await runSubject({...options,timeoutMs:250,mutation:await flagMutation(options)});
  assert.equal(result.status,'killed');
  assert.equal(result.reason,'timeout');
  await new Promise(resolve=>setTimeout(resolve,1100));
  await assert.rejects(readFile(marker));
  assert.deepEqual(await readdir(options.workspaceRoot),[]);
});
