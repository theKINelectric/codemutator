import {resolve} from 'node:path';

function errorFacts(error, depth = 0) {
  if (!error || typeof error !== 'object' || depth > 3) return null;
  return {name:error.name ?? null,code:error.code ?? null,failureType:error.failureType ?? null,
    signal:error.signal ?? null,exitCode:error.exitCode ?? null,cause:errorFacts(error.cause,depth+1)};
}

/** Reporter output has its own destination; test stdout cannot become the summary. */
export default async function* reporter(events) {
  let summary = null;
  let executed = 0;
  const failures = [];
  const fileStderr = new Map();
  for await (const {type,data} of events) {
    if (type === 'test:summary' && data.file === undefined) summary = {success:data.success,counts:data.counts};
    if (type === 'test:stderr') {
      const file=resolve(data.entryFile ?? data.file);
      fileStderr.set(file, ((fileStderr.get(file) ?? '')+data.message).slice(-16000));
    }
    if (['test:pass','test:fail'].includes(type)) {
      // A successful empty file has a synthetic test:pass but no entryFile.
      if (data.entryFile && data.details?.type === 'test' && !data.skip && !data.todo) executed += 1;
      if (type === 'test:fail' && !data.todo) failures.push({file:resolve(data.file),synthetic:!data.entryFile,error:errorFacts(data.details?.error)});
    }
  }
  const loaderFailures = failures.filter(f => f.synthetic).map(f => ({...f,stderr:fileStderr.get(f.file) ?? ''}));
  yield JSON.stringify({protocol:1,summary,executed,failures,loaderFailures})+'\n';
}
