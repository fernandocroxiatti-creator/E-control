import test from 'node:test';
import assert from 'node:assert/strict';
import { parseSaasPolicy, parseSaasReactivation } from '../lib/saas/input.ts';
import { parseBillingReceivable } from '../lib/billing/receivable-input.ts';
import { parseOfx, MAX_OFX_BYTES } from '../lib/treasury/ofx.ts';
const id='e1100000-0000-4000-8000-000000000001';
const form=(values)=>{ const f=new FormData(); for(const [k,v] of Object.entries(values)) for(const item of Array.isArray(v)?v:[v]) f.append(k,item); return f; };
const statement=`OFXHEADER:100\nDATA:OFXSGML\nVERSION:102\nCHARSET:UTF-8\n\n<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><CURDEF>BRL<BANKACCTFROM><BANKID>001<BRANCHID>123<ACCTID>456<ACCTTYPE>CHECKING</BANKACCTFROM><BANKTRANLIST><DTSTART>20261101000000<DTEND>20261130235959<STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20261128120000[-3:BRT]<TRNAMT>35.25000000<FITID>F1<NAME>Recebimento<MEMO>João &amp; Cia<REFNUM>R1</STMTTRN></BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>`;
const bytes=(s)=>new TextEncoder().encode(s);
test('commercial policy validates dates, bounded grace and explicit enrollment',()=>{
 const values={tenant_id:id,enabled:'true',block_on_overdue:'true',due_on:'2026-11-28',grace_days:'3',reason:'Política contratual'};
 assert.equal(parseSaasPolicy(form(values)).graceDays,3);
 for(const bad of [{grace_days:'91'},{grace_days:'-1'},{due_on:'2026-02-30'},{due_on:''},{enabled:'maybe'},{reason:'x'}]) assert.throws(()=>parseSaasPolicy(form({...values,...bad})));
 assert.throws(()=>parseSaasReactivation(form({...values,due_on:'2026-11-31'})));
 assert.equal(parseSaasReactivation(form(values)).tenantId,id);
});
test('billing installments keep exact values and ordered dates; historical linking is explicit',()=>{
 const values={tenant_id:id,billing_document_id:id,request_id:id,issue_date:'2026-11-28',payment_terms:'30/60 dias',mode:'generate',due_date:['2026-12-28','2027-01-28'],amount:['40,12345678','59.87654322']};
 assert.equal(parseBillingReceivable(form(values)).p_installments[0].amount,'40.12345678');
 assert.throws(()=>parseBillingReceivable(form({...values,due_date:['2026-11-01','2026-12-01']})));
 for(const amount of [['0','100'],['NaN','100'],['1.123456789','100']]) assert.throws(()=>parseBillingReceivable(form({...values,amount})));
 assert.equal(parseBillingReceivable(form({...values,mode:'existing',existing_obligation_id:id})).p_installments.length,0);
 assert.throws(()=>parseBillingReceivable(form({...values,mode:'generate',existing_obligation_id:id})));
});
test('OFX SGML parses exact signed amounts, identity, reference and stable content hash',()=>{
 const parsed=parseOfx(bytes(statement));assert.equal(parsed.bankId,'001');assert.equal(parsed.accountId,'456');assert.equal(parsed.transactions[0].amount,'35.25');assert.match(parsed.transactions[0].description,/João & Cia/);assert.equal(parsed.transactions[0].posted_on,'2026-11-28');assert.equal(parseOfx(bytes(statement)).fileHash,parsed.fileHash);
 assert.equal(parseOfx(bytes(statement.replace('35.25000000','-35.25'))).transactions[0].amount,'-35.25');
});
test('OFX rejects XXE, malformed dates, duplicate FITIDs, oversized files and other currencies',()=>{
 for(const text of [statement.replace('<OFX>','<!DOCTYPE x SYSTEM "file:///etc/passwd"><OFX>'),statement.replace('20261128120000','20260230120000'),statement.replace('35.25000000','NaN'),statement.replace('35.25000000','0'),statement.replace('BRL','USD'),statement.replace('</BANKTRANLIST>',statement.match(/<STMTTRN>[\s\S]*?<\/STMTTRN>/)[0]+'</BANKTRANLIST>'),statement.replace('</STMTTRN>','')]) assert.throws(()=>parseOfx(bytes(text)));
 assert.throws(()=>parseOfx(new Uint8Array(MAX_OFX_BYTES+1)));
});
test('OFX XML with closed tags is supported',()=>{
 const xml=statement.slice(statement.indexOf('<OFX>')).replace(/<(CURDEF|BANKID|BRANCHID|ACCTID|ACCTTYPE|DTSTART|DTEND|TRNTYPE|DTPOSTED|TRNAMT|FITID|NAME|MEMO|REFNUM)>([^<]*)/g,(_,tag,value)=>`<${tag}>${value}</${tag}>`);
 assert.equal(parseOfx(bytes('<?xml version="1.0" encoding="UTF-8"?>'+xml)).transactions.length,1);
});
