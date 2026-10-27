import test from 'node:test';
import assert from 'node:assert/strict';
import {isSuccess} from '../src/client.ts';
test('ordinary success and error responses', () => {
  assert.equal(isSuccess(201), true);
  assert.equal(isSuccess(299), true);
  assert.equal(isSuccess(400), false);
});
