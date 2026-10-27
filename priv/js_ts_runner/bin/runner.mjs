#!/usr/bin/env node
import {runSubject,executeWorker,terminateOwnedChildren} from '../runner.mjs';

// The Phoenix runner owns the outer deadline. Forward its termination to the
// inner compiler/test process groups before this wrapper exits.
process.on('SIGTERM',()=>{terminateOwnedChildren();process.exit(143);});
process.on('SIGINT',()=>{terminateOwnedChildren();process.exit(130);});
process.on('exit',terminateOwnedChildren);

let bytes=0;
let input='';
let finished=false;
function emit(result) {
  const bounded={protocol:1,...result};
  if(Array.isArray(bounded.compilerDiagnostics)) bounded.compilerDiagnostics=bounded.compilerDiagnostics.slice(0,8).map(d=>({code:d.code,message:d.message.slice(0,180)}));
  process.stdout.write('CODEMUTATOR_JS_RESULT '+JSON.stringify(bounded)+'\n');
  process.exitCode=['passed','survived'].includes(result.status)?0:result.status==='invalid'?20:result.status==='killed'?21:22;
}
async function finish() {
  if(finished)return;
  finished=true;
  process.stdin.pause();
  let request;
  try {
    request=JSON.parse(input);
    const keys=['protocol','source_root','workspace_root','compiler_path','timeout_ms','mutation'];
    if(!request || Array.isArray(request) || request.protocol!==1 || Object.keys(request).some(k=>!keys.includes(k)) ||
       typeof request.source_root!=='string' || typeof request.workspace_root!=='string') throw new Error('bad request');
  } catch {
    emit({status:'error',reason:'invalid_request'});
    return;
  }
  try {
    emit(await runSubject({sourceRoot:request.source_root,workspaceRoot:request.workspace_root,compilerPath:request.compiler_path,timeoutMs:request.timeout_ms??5000,mutation:request.mutation??null}));
  } catch {
    emit({status:'error',reason:'runner_error'});
  }
}
const args=process.argv.slice(2);
if(args.length>0) {
  try {
    const options={};
    const fields={'--worker':'workspaceRoot','--compiler':'compilerPath','--timeout':'timeoutMs'};
    for(let i=0;i<args.length;) {
      if(args[i]==='--service-owned-group') {
        if(options.serviceOwnedGroup)throw new Error('duplicate flag');
        options.serviceOwnedGroup=true;i+=1;continue;
      }
      const key=fields[args[i]];
      if(!key || !args[i+1] || options[key]!==undefined)throw new Error('invalid flag');
      options[key]=key==='timeoutMs'?Number(args[i+1]):args[i+1];
      i+=2;
    }
    if(!options.workspaceRoot)throw new Error('missing worker');
    emit(await executeWorker(options));
  } catch {emit({status:'error',reason:'invalid_request'});}
} else {
  process.stdin.setEncoding('utf8');
  process.stdin.on('data',chunk=>{
    if(finished)return;
    bytes+=Buffer.byteLength(chunk);
    if(bytes>65536) {
      finished=true;process.stdin.pause();emit({status:'error',reason:'request_too_large'});return;
    }
    input+=chunk;
    const newline=input.indexOf('\n');
    if(newline>=0){input=input.slice(0,newline);finish();}
  });
  process.stdin.on('end',finish);
  process.stdin.on('error',()=>{if(!finished){finished=true;emit({status:'error',reason:'input_error'});}});
  }
