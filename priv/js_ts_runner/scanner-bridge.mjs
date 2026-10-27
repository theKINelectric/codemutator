import {createHash} from 'node:crypto';

function sha(value) { return createHash('sha256').update(value).digest('hex'); }
export function relativePath(value) {
  if (typeof value !== 'string' || !value || value.startsWith('/') || value.includes('\\') ||
      value.includes('\0') || value.split('/').some(part => part === '..' || part === '' || part === '.')) {
    throw new Error('Invalid relative path');
  }
  return value;
}
function category(operator) {
  if (['<','<=','>','>='].includes(operator)) return 'comparison';
  if (['==','!=','===','!=='].includes(operator)) return 'equality';
  if (['+','-','*','/'].includes(operator)) return 'arith';
  if (['&&','||'].includes(operator)) return 'logical';
  if (['boolean','true','false'].includes(operator)) return 'bool';
  if (operator === '!') return 'unary_del';
  if (['number','0','1'].includes(operator)) return 'const01';
  throw new Error(`Unsupported parser operator ${operator}`);
}
/** Convert the parser's static facts into the existing Scanner.Site field vocabulary. */
export function mapSites(filename, source, facts) {
  relativePath(filename);
  if (!facts?.ok || facts.protocol !== 1 || !Array.isArray(facts.sites)) throw new Error('Parser result is not successful protocol 1 facts');
  const bytes = Buffer.from(source,'utf8');
  const file_hash = sha(bytes);
  if (facts.source_sha256 !== file_hash) throw new Error('Parser source hash mismatch');
  return facts.sites.map(site => {
    if (!Number.isSafeInteger(site.byte_start) || !Number.isSafeInteger(site.byte_end) || site.byte_start < 0 ||
        site.byte_end <= site.byte_start || site.byte_end > bytes.length || typeof site.original !== 'string' ||
        typeof site.replacement !== 'string' || bytes.subarray(site.byte_start,site.byte_end).toString('utf8') !== site.original ||
        typeof site.function !== 'string' || !site.function || !Number.isSafeInteger(site.function_start) ||
        !Number.isSafeInteger(site.function_end) || !Number.isSafeInteger(site.line) || site.function_start < 1 ||
        site.function_end < site.function_start || site.line < site.function_start || site.line > site.function_end) {
      throw new Error('Invalid parser mutation span or function range');
    }
    const operator = category(site.operator);
    const site_key = sha(JSON.stringify([filename,file_hash,site.byte_start,site.byte_end,operator,site.original,site.replacement])).slice(0,32);
    return {file:filename,function:site.function,function_line:site.function_start,function_end_line:site.function_end,
      line:site.line,byte_start:site.byte_start,byte_end:site.byte_end,operator,original:site.original,replacement:site.replacement,site_key,file_hash};
  });
}
