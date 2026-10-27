import test from 'node:test';
import assert from 'node:assert/strict';
import {resolve} from 'node:path';
import reporter from '../../priv/js_ts_runner/reporter.mjs';

test('reporter joins relative entry-file stderr with absolute loader failure paths', async () => {
  const relative = 'test/loader.test.mjs';
  async function* events() {
    yield {type:'test:stderr',data:{entryFile:relative,file:resolve(relative),message:'Error [ERR_MODULE_NOT_FOUND]: missing'}};
    yield {type:'test:fail',data:{file:resolve(relative),details:{error:{code:'ERR_TEST_FAILURE'}}}};
    yield {type:'test:summary',data:{success:false,counts:{failed:1}}};
  }
  let output='';
  for await (const part of reporter(events())) output+=part;
  const report=JSON.parse(output);
  assert.equal(report.loaderFailures.length,1);
  assert.match(report.loaderFailures[0].stderr,/ERR_MODULE_NOT_FOUND/);
});
