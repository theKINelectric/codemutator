import {readFile,writeFile,mkdir,mkdtemp,cp,rm,lstat,readdir,realpath} from 'node:fs/promises';
import {join,dirname,sep,matchesGlob} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {relativePath} from './scanner-bridge.mjs';

const reporterPath = fileURLToPath(new URL('./reporter.mjs',import.meta.url));
const ownedGroups = new Set();
export function terminateOwnedChildren() {
  for(const pid of ownedGroups) {try{process.kill(-pid,'SIGKILL');}catch{}}
}
function failure(reason,message=reason) { return Object.assign(new Error(message),{reason}); }
function object(value,keys,label) {
  if (!value || Array.isArray(value) || typeof value !== 'object' || Object.keys(value).some(k => !keys.includes(k))) throw failure('invalid_profile',`Invalid ${label} profile fields`);
}
function pathList(value,label,nonempty=true) {
  if (!Array.isArray(value) || (nonempty && value.length===0)) throw failure('invalid_profile',`${label} must be ${nonempty?'nonempty ':''}paths`);
  for (const path of value) { try { relativePath(path); } catch { throw failure('invalid_profile',`Invalid ${label} path`); } }
}
export async function readProfile(root) {
  let text;
  try { text=await readFile(join(root,'.codemutator.json'),'utf8'); } catch { throw failure('invalid_profile','Missing .codemutator.json profile'); }
  if (Buffer.byteLength(text)>65536) throw failure('invalid_profile','Profile exceeds 64 KB');
  let profile;
  try { profile=JSON.parse(text); } catch { throw failure('invalid_profile','Profile must be valid JSON'); }
  object(profile,['schemaVersion','language','runner','typecheck','source'],'root');
  if(profile.schemaVersion!==1 || profile.language!=='javascript-typescript') throw failure('invalid_profile','Unknown profile version or language');
  object(profile.runner,['kind','files'],'runner');
  if(profile.runner.kind!=='node-test') throw failure('invalid_profile','Unsupported runner profile');
  pathList(profile.runner.files,'test');
  if(profile.runner.files.some(path => !/\.(?:mjs|cjs|js|mts|cts|ts)$/.test(path) || /[*?\[\]]/.test(path))) throw failure('invalid_profile','Tests must be explicit supported source paths');
  object(profile.typecheck,['kind','project'],'typecheck');
  if(!['none','typescript'].includes(profile.typecheck.kind)) throw failure('invalid_profile','Unsupported typecheck profile');
  if(profile.typecheck.kind==='typescript') {
    try { relativePath(profile.typecheck.project); } catch { throw failure('invalid_profile','Invalid compiler project path'); }
  } else if(profile.typecheck.project!==undefined) throw failure('invalid_profile','No compiler project allowed for typecheck none');
  object(profile.source,['include','exclude'],'source');
  pathList(profile.source.include,'source include');
  pathList(profile.source.exclude,'source exclude',false);
  return profile;
}

async function noSymlinks(root) {
  for(const entry of await readdir(root,{withFileTypes:true})) {
    const path=join(root,entry.name);
    const stat=await lstat(path);
    if(stat.isSymbolicLink()) throw failure('subject_symlink','Prototype does not support subject symlinks');
    if(stat.isDirectory()) await noSymlinks(path);
  }
}
async function regular(path,reason) {
  try { if(!(await lstat(path)).isFile()) throw failure(reason); } catch { throw failure(reason); }
}
function inside(child,parent) { return child===parent || child.startsWith(parent+sep); }
async function command(argv,{cwd,env,timeoutMs,ownProcessGroup=true}) {
  return new Promise(resolveResult => {
    let output='';
    let timedOut=false;
    let spawnError=null;
    const child=spawn(argv[0],argv.slice(1),{cwd,env,detached:ownProcessGroup,stdio:['ignore','pipe','pipe']});
    if(child.pid && ownProcessGroup)ownedGroups.add(child.pid);
    const append=chunk => { output=(output+chunk.toString('utf8')).slice(-32000); };
    child.stdout.on('data',append); child.stderr.on('data',append);
    child.on('error',error => {spawnError=error.code ?? 'spawn_error';});
    const timer=timeoutMs===null?null:setTimeout(()=>{
      timedOut=true;
      if(child.pid) {try {if(ownProcessGroup)process.kill(-child.pid,'SIGKILL');else child.kill('SIGKILL');} catch {}}
    },timeoutMs);
    child.on('close',(code,signal)=>{
      clearTimeout(timer);
      if(child.pid)ownedGroups.delete(child.pid);
      resolveResult({code,signal,output,timedOut,spawnError});
    });
  });
}
function diagnostics(output) {
  return [...output.matchAll(/(?:^|\n)([^\n]*?)error TS(\d+): ([^\n]*)/g)].map(match=>({code:Number(match[2]),message:match[3]}));
}
function classify(report,result,phase) {
  if(result.timedOut) return {status:phase==='baseline'?'error':'killed',reason:phase==='baseline'?'baseline_timeout':'timeout'};
  if(result.spawnError) return {status:'error',reason:'runner_unavailable'};
  if(!report || report.protocol!==1 || !report.summary || !Array.isArray(report.failures)) return {status:'error',reason:'missing_summary'};
  const errors=report.failures.flatMap(f=>[f.error,f.error?.cause,f.error?.cause?.cause]).filter(Boolean);
  const missing=errors.some(error=>['ERR_MODULE_NOT_FOUND','MODULE_NOT_FOUND','ERR_PACKAGE_PATH_NOT_EXPORTED'].includes(error.code)) ||
    report.loaderFailures.some(f => /ERR_MODULE_NOT_FOUND|MODULE_NOT_FOUND|ERR_PACKAGE_PATH_NOT_EXPORTED/.test(f.stderr));
  if(missing) return {status:'error',reason:'missing_dependency'};
  const syntax=report.loaderFailures.some(f => /(?:^|\n)SyntaxError:/.test(f.stderr));
  if(syntax) return {status:phase==='baseline'?'error':'invalid',reason:phase==='baseline'?'baseline_syntax':'syntax'};
  if(errors.some(e=>e.signal)) return {status:phase==='baseline'?'error':'killed',reason:phase==='baseline'?'baseline_crash':'runtime_crash'};
  if(report.executed===0) return {status:'error',reason:'zero_tests'};
  if(report.summary.success===true && result.code===0 && report.failures.length===0) return {status:phase==='mutant'?'survived':'passed',reason:null};
  if(errors.some(e=>e.code==='ERR_ASSERTION')) return {status:phase==='baseline'?'error':'killed',reason:phase==='baseline'?'baseline_assertion':'assertion'};
  if(report.failures.some(f=>!f.synthetic && f.error?.failureType==='testCodeFailure')) return {status:phase==='baseline'?'error':'killed',reason:phase==='baseline'?'baseline_runtime':'runtime_crash'};
  return {status:'error',reason:'unclassified_runtime'};
}
function patch(bytes,mutation) {
  if(!mutation || !Number.isSafeInteger(mutation.byte_start) || !Number.isSafeInteger(mutation.byte_end) ||
    mutation.byte_start<0 || mutation.byte_end<=mutation.byte_start || mutation.byte_end>bytes.length ||
    typeof mutation.original!=='string' || typeof mutation.replacement!=='string' ||
    createHash('sha256').update(bytes).digest('hex')!==mutation.file_hash ||
    bytes.subarray(mutation.byte_start,mutation.byte_end).toString('utf8')!==mutation.original) throw failure('stale_site');
  return Buffer.concat([bytes.subarray(0,mutation.byte_start),Buffer.from(mutation.replacement),bytes.subarray(mutation.byte_end)]);
}

/** Caller supplies a service-owned physical worker, already patched if needed. */
export async function executeWorker({workspaceRoot,compilerPath,nodePath=process.execPath,timeoutMs=5000,phase='worker',serviceOwnedGroup=false}) {
  let scratch=null;
  try {
    const worker=await realpath(workspaceRoot);
    const profile=await readProfile(worker);
    try {await noSymlinks(worker);} catch(error) {if(error.reason==='subject_symlink')throw failure('unsupported_workspace_symlink');throw error;}
    if(!Number.isSafeInteger(timeoutMs) || timeoutMs<1 || timeoutMs>600000) throw failure('invalid_timeout');
    scratch=await mkdtemp(join(dirname(worker),'.js-run-'));
    const home=join(scratch,'home');await mkdir(home);
    const env=Object.fromEntries(Object.entries(process.env).filter(([key])=>['PATH','LANG','TZ'].includes(key)||/^LC_[A-Z_]+$/.test(key)));
    Object.assign(env,{HOME:home,CI:'true',NODE_OPTIONS:'',NODE_PATH:'',NODE_COMPILE_CACHE:join(scratch,'node-cache'),TMPDIR:join(scratch,'tmp')});
    await mkdir(env.TMPDIR);
    const ownProcessGroup=!serviceOwnedGroup;
    const projectTimeout=serviceOwnedGroup?null:timeoutMs;
    const probeTimeout=serviceOwnedGroup?5000:Math.min(timeoutMs,5000);
    const nodeIdentity=await command([nodePath,'--version'],{cwd:worker,env,timeoutMs:probeTimeout,ownProcessGroup});
    if(nodeIdentity.timedOut)return {status:'error',reason:'node_probe_timeout',phase};
    if(nodeIdentity.spawnError)return {status:'error',reason:'runner_unavailable',phase};
    const nodeVersion=nodeIdentity.output.trim();
    if(nodeIdentity.code!==0 || !/^v26\.(?:[6-9]|[1-9]\d+)\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(nodeVersion))return {status:'error',reason:'unsupported_node_runtime',phase};
    for(const file of profile.runner.files) await regular(join(worker,file),'missing_test');
    let compilerDiagnostics=[];
    const runtime={node:nodeVersion};
    if(profile.typecheck.kind==='typescript') {
      await regular(join(worker,profile.typecheck.project),'missing_compiler_project');
      const compiler=compilerPath ?? process.env.CODEMUTATOR_TSC ?? join(worker,'node_modules/typescript/lib/tsc.js');
      await regular(compiler,'missing_compiler');
      const identity=await command([nodePath,compiler,'--version'],{cwd:worker,env,timeoutMs:probeTimeout,ownProcessGroup});
      if(identity.timedOut)return {status:'error',reason:'compiler_timeout',phase,runtime};
      const version=identity.output.match(/^Version (\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\s*$/)?.[1];
      if(identity.code!==0 || !version)return {status:'error',reason:'invalid_compiler_version',phase,runtime};
      runtime.compiler={name:'typescript',version};
      const result=await command([nodePath,compiler,'--project',profile.typecheck.project,'--noEmit','--incremental','false','--pretty','false'],{cwd:worker,env,timeoutMs:projectTimeout,ownProcessGroup});
      compilerDiagnostics=diagnostics(result.output);
      if(result.timedOut)return {status:'error',reason:'compiler_timeout',phase,runtime};
      if(result.spawnError)return {status:'error',reason:'missing_compiler',phase,runtime};
      if(result.code!==0) {
        const missingDependency=compilerDiagnostics.some(d=>[2307,2688,7016].includes(d.code));
        const sourceTypeError=compilerDiagnostics.length>0 && compilerDiagnostics.every(d=>d.code>=1000 && d.code<5000 && ![2307,2688,7016].includes(d.code));
        return {status:missingDependency?'error':phase!=='baseline'&&sourceTypeError?'invalid':'error',reason:missingDependency?'missing_dependency':phase!=='baseline'&&sourceTypeError?'typecheck':phase==='baseline'?'baseline_typecheck':'compiler_configuration',phase,compilerDiagnostics,runtime};
      }
    }
    const reportPath=join(scratch,'report.json');
    const result=await command([nodePath,'--test','--test-concurrency=1',`--test-reporter=${reporterPath}`,`--test-reporter-destination=${reportPath}`,...profile.runner.files],{cwd:worker,env,timeoutMs:projectTimeout,ownProcessGroup});
    let report=null;
    try {report=JSON.parse(await readFile(reportPath,'utf8'));} catch {}
    return {...classify(report,result,phase),phase,tests:{executed:report?.executed??0,counts:report?.summary?.counts??null},runtime,compilerDiagnostics};
  } catch(error) {
    return {status:'error',reason:error.reason??'runner_error',phase,message:String(error.message).slice(0,500)};
  } finally {
    if(scratch)await rm(scratch,{recursive:true,force:true});
  }
}

/** Prototype entry: submitted tree is read/copied; only a disposable copy executes. */
export async function runSubject({sourceRoot,workspaceRoot,compilerPath,nodePath=process.execPath,timeoutMs=5000,mutation=null}) {
  let disposable=null;
  const phase=mutation?'mutant':'baseline';
  let original=null;
  let patchedPath=null;
  try {
    const source=await realpath(sourceRoot);
    const profile=await readProfile(source);
    await noSymlinks(source);
    await mkdir(workspaceRoot,{recursive:true});
    const workspaces=await realpath(workspaceRoot);
    if(inside(workspaces,source) || inside(source,workspaces)) throw failure('invalid_workspace');
    if(!Number.isSafeInteger(timeoutMs) || timeoutMs<1 || timeoutMs>600000) throw failure('invalid_timeout');
    disposable=await mkdtemp(join(workspaces,'js-'));
    const worker=join(disposable,'project');
    await cp(source,worker,{recursive:true,dereference:false});
    for(const file of profile.runner.files) await regular(join(worker,file),'missing_test');
    if(mutation) {
      try {relativePath(mutation.file);} catch {throw failure('invalid_site_path');}
      const forbidden=/\.(?:test|spec)\.[^/]+$/.test(mutation.file) || /\.d\.(?:ts|mts|cts)$/.test(mutation.file) ||
        mutation.file.split('/').some(part=>['test','tests','spec','node_modules','.git','dist','build'].includes(part));
      if(forbidden || !profile.source.include.some(pattern=>matchesGlob(mutation.file,pattern)) ||
          profile.source.exclude.some(pattern=>matchesGlob(mutation.file,pattern))) throw failure('site_out_of_scope');
      patchedPath=join(worker,mutation.file);
      original=await readFile(patchedPath);
      await writeFile(patchedPath,patch(original,mutation));
    }
    return await executeWorker({workspaceRoot:worker,compilerPath,nodePath,timeoutMs,phase});
  } catch(error) {
    return {status:'error',reason:error.reason??'runner_error',phase,message:String(error.message).slice(0,500)};
  } finally {
    if(original && patchedPath) await writeFile(patchedPath,original);
    if(disposable) await rm(disposable,{recursive:true,force:true});
  }
}
