import {existsSync} from 'node:fs';
import {isAbsolute} from 'node:path';
import {spawnSync} from 'node:child_process';

export const compilerPath=process.env.CODEMUTATOR_E2E_TSC ?? process.env.CODEMUTATOR_TSC;
if(!compilerPath || !isAbsolute(compilerPath) || !existsSync(compilerPath)) {
  throw new Error('Set CODEMUTATOR_E2E_TSC or CODEMUTATOR_TSC to an absolute trusted installed TypeScript lib/tsc.js or bin/tsc before running the Node qualification suite. No compiler is downloaded by tests.');
}
const identity=spawnSync(process.execPath,[compilerPath,'--version'],{encoding:'utf8',timeout:5000,env:{PATH:process.env.PATH??'',NODE_OPTIONS:'',NODE_PATH:''}});
export const compilerVersion=identity.stdout?.match(/^Version (\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\s*$/)?.[1];
if(identity.status!==0 || !compilerVersion)throw new Error('The configured TypeScript compiler must report a valid bounded --version response.');
