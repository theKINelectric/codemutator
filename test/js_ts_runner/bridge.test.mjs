import test from 'node:test';
import assert from 'node:assert/strict';
import {mapSites} from '../../priv/js_ts_runner/scanner-bridge.mjs';
import {parseRequest} from '../../../js_ts_parser/parse.mjs';

test('bridge preserves UTF-8 exact spans, qualified owners and deterministic keys',()=>{
  const source='// 🌌 café\nexport const eligible = (age: number) => age >= 18;';
  const facts=parseRequest({protocol:1,source,filename:'src/a.ts'});
  const sites=mapSites('src/a.ts',source,facts);
  const site=sites.find(s=>s.original==='>=');
  assert.ok(site);
  assert.equal(site.function,'eligible');
  assert.equal(site.function_line,2);
  assert.equal(Buffer.from(source).subarray(site.byte_start,site.byte_end).toString(),'>=');
  assert.equal(site.operator,'comparison');
  assert.match(site.file_hash,/^[a-f0-9]{64}$/);
  assert.match(site.site_key,/^[a-f0-9]{32}$/);
  assert.deepEqual(mapSites('src/a.ts',source,facts),sites);
  assert.notEqual(mapSites('src/b.ts',source,facts)[0].site_key,sites[0].site_key);
});
test('bridge rejects stale hash, parser error, invalid offsets and escaping file',()=>{
  const source='function flag(){return true;}';
  const facts=parseRequest({protocol:1,source,filename:'src/a.js'});
  assert.throws(()=>mapSites('src/a.js',source+' ',facts),/hash|source/i);
  assert.throws(()=>mapSites('src/a.js',source,{ok:false,error:{code:'parse_error'}}),/parser|parse/i);
  assert.throws(()=>mapSites('src/a.js',source,{...facts,sites:[{...facts.sites[0],byte_start:999}]}),/span|offset|range/i);
  assert.throws(()=>mapSites('../a.js',source,facts),/path/i);
});
