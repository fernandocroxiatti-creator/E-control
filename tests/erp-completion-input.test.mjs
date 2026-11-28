import test from 'node:test';
import assert from 'node:assert/strict';
import { parseCommand, reportPeriod, csv, validDate } from '../lib/erp-completion/input.ts';
const id = 'e1100000-0000-4000-8000-000000000001';
function form(values) { const f = new FormData(); for (const [k,v] of Object.entries(values)) f.set(k,v); return f; }
test('bank command preserves decimal precision and rejects malformed financial input', () => {
 const values = { tenant_id:id, branch_id:id, request_id:id, code:'BB01',name:'Banco',kind:'checking',opening:'123456789012345,12345678' };
 assert.equal(parseCommand('account',form(values)).args.p_opening,'123456789012345.12345678');
 for (const opening of ['', 'NaN', 'Infinity', '1e5', '1.123456789','1000000000000000']) assert.throws(()=>parseCommand('account',form({...values,opening})));
 assert.throws(()=>parseCommand('arbitrary_rpc',form(values)));
});
test('transfer rejects equal accounts and nonpositive amounts', () => {
 const values={tenant_id:id,request_id:id,from:id,to:id,amount:'10',occurred_on:'2026-11-27',description:'Transfer test'};
 assert.throws(()=>parseCommand('transfer',form(values)));
 for(const amount of ['0','-1']) assert.throws(()=>parseCommand('transfer',form({...values,to:'e1100000-0000-4000-8000-000000000002',amount})));
});
test('calendar validation rejects rollover and oversized reporting periods',()=>{
 assert.equal(validDate('2026-02-29'),false); assert.equal(validDate('2028-02-29'),true);
 assert.equal(reportPeriod('2026-12-01','2026-11-01'),null);
 assert.equal(reportPeriod('2025-01-01','2026-11-01'),null);
 assert.deepEqual(reportPeriod('2026-11-01','2026-11-30'),{from:'2026-11-01',to:'2026-11-30'});
});
test('CSV neutralizes formulas and quotes semicolons, quotes and line breaks',()=>{
 const result=csv([['=SUM(A1)', ' @attack', 'a;b', 'a"b', 'a\nb']]);
 assert.equal(result,'\uFEFF"\'=SUM(A1)";"\' @attack";"a;b";"a""b";"a\nb"');
});
