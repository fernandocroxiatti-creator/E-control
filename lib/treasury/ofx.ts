import { createHash } from "node:crypto";

export const MAX_OFX_BYTES = 2 * 1024 * 1024;
export const MAX_OFX_TRANSACTIONS = 2000;
export type OfxTransaction = { fit_id: string; posted_on: string; amount: string; description: string; reference: string | null };
export type OfxStatement = { fileHash: string; bankId: string; branchId: string; accountId: string; accountType: string; currency: "BRL"; from: string; to: string; transactions: OfxTransaction[] };

function decodeEntities(value: string) {
  if (/&(?!amp;|lt;|gt;|quot;|apos;|#\d{1,7};|#x[\da-f]{1,6};)/i.test(value)) throw new Error("Extrato contém entidade de texto não suportada.");
  return value.replace(/&(amp|lt|gt|quot|apos|#\d{1,7}|#x[\da-f]{1,6});/gi, (_, entity: string) => {
    const named: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };
    if (named[entity.toLowerCase()]) return named[entity.toLowerCase()];
    const code = entity.toLowerCase().startsWith("#x") ? Number.parseInt(entity.slice(2), 16) : Number(entity.slice(1));
    if (!Number.isInteger(code) || code < 32 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) throw new Error("Extrato contém caractere inválido.");
    return String.fromCodePoint(code);
  });
}
function value(block: string, tag: string, optional = false) {
  const matches = [...block.matchAll(new RegExp(`<${tag}\\s*>([^<\\r\\n]*)`, "gi"))];
  if (matches.length !== 1) { if (optional && matches.length === 0) return ""; throw new Error(`Campo OFX ${tag} ausente ou repetido.`); }
  return decodeEntities(matches[0][1].trim());
}
function aggregate(block: string, tag: string) {
  const matches = [...block.matchAll(new RegExp(`<${tag}\\s*>([\\s\\S]*?)<\\/${tag}\\s*>`, "gi"))];
  if (matches.length !== 1) throw new Error(`Extrato deve conter exatamente um bloco ${tag}.`);
  return matches[0][1];
}
function identifier(text: string, label: string, max = 128) {
  if (!text || text.length > max || /[\u0000-\u001f\u007f]/.test(text)) throw new Error(`${label} inválido no extrato.`);
  return text;
}
function ofxDate(text: string) {
  if (!/^\d{8}(?:\d{6}(?:\.\d{1,6})?(?:\[[+-]?\d{1,2}(?:\.\d{1,2})?(?::[A-Za-z]{1,8})?\])?)?$/.test(text)) throw new Error("Data OFX inválida.");
  const result = `${text.slice(0, 4)}-${text.slice(4, 6)}-${text.slice(6, 8)}`;
  if (!Number.isFinite(Date.parse(result)) || new Date(result).toISOString().slice(0, 10) !== result) throw new Error("Data OFX inexistente.");
  if (text.length >= 14 && (Number(text.slice(8, 10)) > 23 || Number(text.slice(10, 12)) > 59 || Number(text.slice(12, 14)) > 59)) throw new Error("Horário OFX inválido.");
  return result;
}
function decimal(text: string) {
  if (!/^-?\d{1,15}(?:\.\d{1,8})?$/.test(text)) throw new Error("Valor OFX inválido; use ponto decimal e até oito casas.");
  const [integer, fraction = ""] = text.replace(/^-/, "").split(".");
  const units = BigInt(integer) * BigInt(100000000) + BigInt(fraction.padEnd(8, "0"));
  if (!units) throw new Error("Movimento OFX com valor zero não é conciliável.");
  return `${text.startsWith("-") ? "-" : ""}${BigInt(integer)}${fraction.replace(/0+$/, "") ? `.${fraction.replace(/0+$/, "")}` : ""}`;
}

/** Bounded OFX 1 SGML / OFX 2 XML bank statements; never resolves XML entities or external resources. */
export function parseOfx(bytes: Uint8Array): OfxStatement {
  if (bytes.byteLength < 50 || bytes.byteLength > MAX_OFX_BYTES) throw new Error("Arquivo OFX deve ter entre 50 bytes e 2 MB.");
  const header = new TextDecoder("ascii").decode(bytes.slice(0, 512));
  const declared = /(?:CHARSET\s*:\s*|encoding\s*=\s*["'])([A-Za-z0-9_-]+)/i.exec(header)?.[1]?.toUpperCase();
  if (declared && !["1252", "WINDOWS-1252", "ISO-8859-1", "8859-1", "UTF-8", "UTF8", "NONE", "US-ASCII"].includes(declared)) throw new Error("Codificação OFX não suportada. Utilize UTF-8 ou Windows-1252.");
  let text: string;
  try { text = new TextDecoder(declared && ["1252", "WINDOWS-1252", "ISO-8859-1", "8859-1"].includes(declared) ? "windows-1252" : "utf-8", { fatal: true }).decode(bytes); }
  catch { throw new Error("Codificação inválida no arquivo OFX."); }
  if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(text) || /<!DOCTYPE|<!ENTITY|<!\[CDATA\[/i.test(text) || /<[A-Za-z]+:/.test(text)) throw new Error("Estrutura OFX não suportada ou insegura.");
  if ((text.match(/<STMTTRN\s*>/gi)?.length ?? 0) > MAX_OFX_TRANSACTIONS) throw new Error("Extrato excede 2.000 movimentos. Divida o período no banco.");
  const root = aggregate(text, "OFX");
  const statement = aggregate(root, "STMTRS");
  const account = aggregate(statement, "BANKACCTFROM");
  const list = aggregate(statement, "BANKTRANLIST");
  const currency = value(statement, "CURDEF");
  if (currency !== "BRL") throw new Error("Somente extratos bancários em BRL são aceitos.");
  const accountType = value(account, "ACCTTYPE").toUpperCase();
  if (!["CHECKING", "SAVINGS", "MONEYMRKT"].includes(accountType)) throw new Error("Tipo de conta OFX não suportado.");
  const from = ofxDate(value(list, "DTSTART")); const to = ofxDate(value(list, "DTEND"));
  if (from > to || Date.parse(to) - Date.parse(from) > 366 * 86400000) throw new Error("Período OFX inválido ou superior a 367 dias.");
  const blocks = [...list.matchAll(/<STMTTRN\s*>([\s\S]*?)<\/STMTTRN\s*>/gi)];
  if (!blocks.length || blocks.length !== (list.match(/<STMTTRN\s*>/gi)?.length ?? 0)) throw new Error("Extrato sem movimentos válidos ou com blocos incompletos.");
  const seen = new Set<string>();
  const transactions = blocks.map((match): OfxTransaction => {
    const block = match[1]; const fitId = identifier(value(block, "FITID"), "FITID");
    if (seen.has(fitId)) throw new Error("FITID duplicado dentro do arquivo OFX."); seen.add(fitId);
    const postedOn = ofxDate(value(block, "DTPOSTED"));
    if (postedOn < from || postedOn > to) throw new Error("Movimento fora do período declarado no extrato.");
    const amount = decimal(value(block, "TRNAMT"));
    const type = value(block, "TRNTYPE");
    if (!/^[A-Z_]{2,30}$/i.test(type)) throw new Error("Tipo de movimento OFX inválido.");
    const description = [value(block, "NAME", true), value(block, "MEMO", true)].filter(Boolean).join(" · ") || type;
    if (description.length > 1000) throw new Error("Descrição do movimento excede 1.000 caracteres.");
    const reference = value(block, "REFNUM", true) || value(block, "CHECKNUM", true) || null;
    if (reference) identifier(reference, "Referência");
    return { fit_id: fitId, posted_on: postedOn, amount, description, reference };
  });
  return { fileHash: createHash("sha256").update(bytes).digest("hex"), bankId: identifier(value(account, "BANKID"), "Banco", 32), branchId: value(account, "BRANCHID", true), accountId: identifier(value(account, "ACCTID"), "Conta"), accountType, currency, from, to, transactions };
}
