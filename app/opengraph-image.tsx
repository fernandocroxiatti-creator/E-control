import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ImageResponse } from "next/og";

export const runtime = "nodejs";
export const alt = "eControll — ERP de Gestão Empresarial";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

/** Public, unauthenticated Open Graph card. The brand mark is loaded from the
 * same official logo used by the application UI; it never needs Supabase. */
export default async function OpenGraphImage() {
  const logo = await readFile(join(process.cwd(), "public", "econtroll-logo.png"));
  const logoSource = `data:image/png;base64,${logo.toString("base64")}`;

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          position: "relative",
          overflow: "hidden",
          background: "#f6faf7",
          color: "#173f34",
          fontFamily: "Arial, sans-serif",
        }}
      >
        <div style={{ position: "absolute", width: 760, height: 760, borderRadius: "50%", right: -240, top: -310, background: "#d9eee1" }} />
        <div style={{ position: "absolute", width: 560, height: 560, borderRadius: "50%", right: -195, bottom: -325, border: "46px solid #b9dbc6" }} />
        <div style={{ width: "100%", padding: "74px 86px", display: "flex", flexDirection: "column", justifyContent: "space-between" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 24 }}>
            <div style={{ display: "flex", width: 106, height: 106, padding: 11, borderRadius: 25, background: "#ffffff", boxShadow: "0 14px 34px rgba(23,63,52,.13)" }}>
              <img src={logoSource} width={84} height={84} alt="eControll" style={{ objectFit: "contain" }} />
            </div>
            <div style={{ display: "flex", flexDirection: "column" }}>
              <span style={{ fontSize: 44, lineHeight: 1, fontWeight: 800, letterSpacing: -1.5 }}>eControll</span>
              <span style={{ marginTop: 9, color: "#4a6c5f", fontSize: 18, fontWeight: 700, letterSpacing: 2.4 }}>ERP · GESTÃO INTEGRADA</span>
            </div>
          </div>
          <div style={{ display: "flex", flexDirection: "column", width: 770 }}>
            <span style={{ color: "#28734e", fontSize: 23, fontWeight: 800, letterSpacing: 1.1 }}>GESTÃO EMPRESARIAL EM UM SÓ LUGAR</span>
            <span style={{ marginTop: 19, fontSize: 60, lineHeight: 1.08, fontWeight: 800, letterSpacing: -2.3 }}>Controle sua operação com clareza.</span>
            <span style={{ marginTop: 22, color: "#4a665b", fontSize: 27, lineHeight: 1.35 }}>Estoque, compras, clientes, fornecedores, serviços e operações em uma plataforma integrada.</span>
          </div>
          <div style={{ display: "flex", gap: 14, alignItems: "center", color: "#35785a", fontSize: 20, fontWeight: 700 }}>
            <span style={{ display: "flex", padding: "10px 17px", borderRadius: 999, background: "#e0f0e5" }}>Multiempresa</span>
            <span style={{ display: "flex", padding: "10px 17px", borderRadius: 999, background: "#e0f0e5" }}>Por filial</span>
            <span style={{ display: "flex", padding: "10px 17px", borderRadius: 999, background: "#e0f0e5" }}>Operação segura</span>
          </div>
        </div>
      </div>
    ),
    size,
  );
}
