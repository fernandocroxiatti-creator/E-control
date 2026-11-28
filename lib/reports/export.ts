import ExcelJS from "exceljs";
import { PDFDocument, rgb, type PDFFont } from "pdf-lib";
import fontkit from "@pdf-lib/fontkit";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import type { ReportDocument } from "./definition";

function scalar(value: string | null, type: string): string | number | Date | null {
  if (value === null) return null;
  if (type === "date") return new Date(`${value}T00:00:00Z`);
  // Excel keeps only 15 significant digits. Preserve larger exact database decimals as text.
  if ((type === "number" || type === "money") && /^-?\d+(\.\d+)?$/.test(value) && value.replace(/[-.]/g, "").replace(/^0+/, "").length <= 15) return Number(value);
  return value;
}
export async function exportXlsx(report: ReportDocument) {
  const workbook = new ExcelJS.Workbook(); workbook.creator = "eControll ERP";
  workbook.created = new Date(report.generatedAt);
  const sheet = workbook.addWorksheet("Relatório", { views: [{ state: "frozen", ySplit: 7 }], pageSetup: { orientation: "landscape", paperSize: 9, fitToPage: true, fitToWidth: 1, fitToHeight: 0, printTitlesRow: "7:7" } });
  sheet.columns = report.columns.map(c => ({ key: c.key, width: ["number", "money"].includes(c.type) ? Math.max(c.width, ...report.rows.map(r => Math.min(44, String(r[c.key] ?? "").length + 3))) : c.width }));
  const meta = [`eControll | ${report.title}`, `${report.company} · ${report.branch}`, `Período: ${report.period}`, `Filtros: ${report.filters}`, report.note, `Gerado: ${new Date(report.generatedAt).toLocaleString("pt-BR", { timeZone: "America/Sao_Paulo" })} · ${report.total} registros. Valores com mais de 15 dígitos preservados como texto.`];
  meta.forEach((text, i) => { const row = i + 1; sheet.mergeCells(row, 1, row, report.columns.length); sheet.getCell(row, 1).value = text; sheet.getRow(row).height = i === 0 ? 32 : 30; sheet.getCell(row, 1).alignment = { vertical: "middle", wrapText: true }; });
  sheet.getCell("A1").font = { name: "Calibri", size: 20, bold: true, color: { argb: "FFFFFFFF" } }; sheet.getCell("A1").fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF145743" } };
  sheet.getRow(7).values = report.columns.map(c => c.label); sheet.getRow(7).height = 28;
  sheet.getRow(7).eachCell(cell => { cell.font = { bold: true, color: { argb: "FFFFFFFF" } }; cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF245B4A" } }; cell.alignment = { vertical: "middle", wrapText: true }; });
  report.rows.forEach((record, i) => {
    const row = sheet.addRow(report.columns.map(c => scalar(record[c.key], c.type)));
    row.height = Math.max(24, ...report.columns.map(c => Math.ceil(String(record[c.key] ?? "").length / Math.max(8, c.width - 2)) * 15 + 8));
    row.eachCell({ includeEmpty: true }, (cell, index) => {
      const column = report.columns[index - 1]; cell.font = { name: "Calibri", size: 11 };
      cell.alignment = { vertical: "top", wrapText: true, horizontal: ["number", "money"].includes(column.type) ? "right" : "left" };
      cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: i % 2 ? "FFF0F6F3" : "FFFFFFFF" } };
      if (column.type === "date") cell.numFmt = "dd/mm/yyyy";
      if (column.type === "money") cell.numFmt = '"R$" #,##0.00########;[Red]("R$" #,##0.00########)';
      if (column.type === "number") cell.numFmt = "#,##0.########";
      if (["money", "number"].includes(column.type) && typeof cell.value === "string") cell.numFmt = "@";
    });
  });
  sheet.autoFilter = { from: { row: 7, column: 1 }, to: { row: Math.max(7, sheet.rowCount), column: report.columns.length } };
  sheet.headerFooter.oddFooter = "&LeControll ERP&R&P / &N";
  return new Uint8Array(await workbook.xlsx.writeBuffer());
}
function pdfText(value: string) { return value.replace(/[\u0000-\u001f\u007f]/g, " "); }
function wrap(value: string, font: PDFFont, size: number, width: number) {
  const output: string[] = []; let line = "";
  for (const word of pdfText(value).split(/\s+/)) {
    if (font.widthOfTextAtSize(line ? `${line} ${word}` : word, size) <= width) { line = line ? `${line} ${word}` : word; continue; }
    if (line) { output.push(line); line = ""; }
    for (const char of word) {
      if (line && font.widthOfTextAtSize(line + char, size) > width) { output.push(line); line = char; } else line += char;
    }
  }
  output.push(line); return output;
}
function formatted(value: string | null, type: string) {
  if (value === null) return "-";
  if (type === "date") return value.split("-").reverse().join("/");
  if (type === "money" || type === "number") {
    const [integer, fraction = ""] = value.split("."); const decimal = fraction.replace(/0+$/, "").padEnd(type === "money" ? 2 : 0, "0");
    return `${type === "money" ? "R$ " : ""}${integer.replace(/\B(?=(\d{3})+(?!\d))/g, ".")}${decimal ? `,${decimal}` : ""}`;
  }
  return value;
}
export async function exportPdf(report: ReportDocument) {
  const pdf = await PDFDocument.create(); pdf.registerFontkit(fontkit); pdf.setTitle(report.title); pdf.setAuthor("eControll ERP");
  const font = await pdf.embedFont(await readFile(join(process.cwd(), "public/fonts/NotoSans-Regular.ttf")), { subset: true });
  const W = 841.89, H = 595.28, margin = 34, usable = W - margin * 2;
  const widthSum = report.columns.reduce((s, c) => s + c.width, 0); const widths = report.columns.map(c => usable * c.width / widthSum);
  // Keep numeric values intact by borrowing width from the descriptive column.
  const descriptionIndex = report.columns.findIndex(c => c.key === "description");
  report.columns.forEach((c, i) => {
    if (["number", "money"].includes(c.type) && descriptionIndex >= 0) {
      const wanted = Math.max(widths[i], ...report.rows.map(r => font.widthOfTextAtSize(formatted(r[c.key], c.type), 8) + 14));
      const borrow = Math.min(wanted - widths[i], Math.max(0, widths[descriptionIndex] - 100)); widths[i] += borrow; widths[descriptionIndex] -= borrow;
    }
  });
  let page = pdf.addPage([W, H]); let y = H - margin;
  const text = (value: string, x: number, at: number, size = 9, color = rgb(.13, .19, .17)) => page.drawText(pdfText(value), { x, y: at, size, font, color });
  const heading = () => {
    page.drawRectangle({ x: 0, y: H - 14, width: W, height: 14, color: rgb(.08, .34, .26) });
    text(`eControll | ${report.title}`, margin, y, 18); y -= 22;
    for (const line of wrap(`${report.company} · ${report.branch}`, font, 10, usable)) { text(line, margin, y, 10); y -= 13; }
    for (const line of wrap(`${report.period} · ${report.filters}`, font, 9, usable)) { text(line, margin, y); y -= 12; }
    for (const line of wrap(report.note, font, 8, usable)) { text(line, margin, y, 8); y -= 11; }
    y -= 7; page.drawRectangle({ x: margin, y: y - 26, width: usable, height: 28, color: rgb(.14, .36, .29) });
    let x = margin; report.columns.forEach((c, i) => { wrap(c.label, font, 8, widths[i] - 12).forEach((line, j) => text(line, x + 6, y - 10 - j * 10, 8, rgb(1, 1, 1))); x += widths[i]; }); y -= 28;
  };
  const nextPage = () => { page = pdf.addPage([W, H]); y = H - margin; heading(); };
  heading();
  if (!report.rows.length) { y -= 24; text("Nenhum registro encontrado para os filtros selecionados.", margin, y); }
  for (const [index, record] of report.rows.entries()) {
    const cells = report.columns.map((c, i) => wrap(formatted(record[c.key], c.type), font, 8, widths[i] - 12));
    let offset = 0; const lineCount = Math.max(...cells.map(c => c.length));
    while (offset < lineCount) {
      if (y < 72) nextPage();
      const chunk = Math.min(lineCount - offset, Math.max(1, Math.floor((y - 58) / 11) - 1)); const height = chunk * 11 + 12;
      if (index % 2 === 0) page.drawRectangle({ x: margin, y: y - height, width: usable, height, color: rgb(.94, .97, .95) });
      let x = margin; cells.forEach((lines, i) => { lines.slice(offset, offset + chunk).forEach((line, j) => text(line, x + 6, y - 13 - j * 11, 8)); x += widths[i]; });
      y -= height; offset += chunk; if (offset < lineCount) nextPage();
    }
  }
  const pages = pdf.getPages(); pages.forEach((p, i) => { page = p; text(`${report.total} registros · Gerado em ${new Date(report.generatedAt).toLocaleString("pt-BR", { timeZone: "America/Sao_Paulo" })}`, margin, 22, 8); text(`${i + 1} / ${pages.length}`, W - 70, 22, 8); });
  return pdf.save();
}
