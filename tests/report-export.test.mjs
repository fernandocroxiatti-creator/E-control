import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import ExcelJS from 'exceljs';
import { PDFDocument } from 'pdf-lib';
import { exportXlsx, exportPdf } from '../lib/reports/export.ts';
import { columnsFor, displayCell } from '../lib/reports/definition.ts';
const report={title:'Relatório financeiro',company:'Empresa de homologação',branch:'001 - Matriz',period:'2026-11-01 a 2026-11-30',filters:'Todas as situações',note:'Dados sintéticos para validação. Valores em BRL; posição atual dos saldos.',generatedAt:'2026-11-28T12:00:00Z',columns:columnsFor('finance'),total:70,rows:Array.from({length:70},(_,i)=>({id:String(i),date:'2026-11-28',reference:i===0?'=HYPERLINK("bad")':String(i+1),description:i===1?'Descrição longa com acentuação: prestação de serviços, peças e manutenção. '.repeat(12):`Cliente São José ${i+1}`,status:'Em aberto',quantity:null,amount:i===0?'123456789012345.12345678':'1234.56',balance:'400.25'}))};
test('XLSX preserves exact large decimals, dates, filters, frozen header and text formulas',async()=>{
 const bytes=await exportXlsx(report);const workbook=new ExcelJS.Workbook();await workbook.xlsx.load(bytes);const sheet=workbook.worksheets[0];
 assert.equal(sheet.getCell('B8').value,'=HYPERLINK("bad")');assert.equal(sheet.getCell('E8').value,'123456789012345.12345678');assert.equal(sheet.getCell('E9').value,1234.56);assert.ok(sheet.getCell('A8').value instanceof Date);assert.equal(sheet.views[0].ySplit,7);assert.ok(sheet.autoFilter);assert.equal(sheet.rowCount,77);
 if(process.env.ECONTROLL_ARTIFACT_TEST_DIR){await mkdir(process.env.ECONTROLL_ARTIFACT_TEST_DIR,{recursive:true});await writeFile(`${process.env.ECONTROLL_ARTIFACT_TEST_DIR}/finance.xlsx`,bytes);}
});
test('professional PDF paginates long rows and remains readable as a document',async()=>{
 const bytes=await exportPdf(report);const pdf=await PDFDocument.load(bytes);assert.ok(pdf.getPageCount()>2);assert.equal(pdf.getTitle(),report.title);assert.equal(pdf.getPages()[0].getWidth(),841.89);
 if(process.env.ECONTROLL_ARTIFACT_TEST_DIR){await mkdir(process.env.ECONTROLL_ARTIFACT_TEST_DIR,{recursive:true});await writeFile(`${process.env.ECONTROLL_ARTIFACT_TEST_DIR}/finance.pdf`,bytes);}
});
test('report formatting retains decimals and actual zeros',()=>{
 assert.equal(displayCell('123456789012345.12345678','money'),'R$ 123.456.789.012.345,12345678');assert.equal(displayCell(null,'money'),'—');assert.equal(displayCell('0','money'),'R$ 0,00');
});
