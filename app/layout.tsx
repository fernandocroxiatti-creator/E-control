import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://www.econtroll.com.br"),
  title: "eControll | ERP de Gestão Empresarial",
  description: "Simplifique a gestão da sua empresa com o eControll. Controle estoque, compras, clientes, fornecedores, serviços e operações em uma plataforma integrada.",
  alternates: {
    canonical: "/",
  },
  openGraph: {
    type: "website",
    locale: "pt_BR",
    url: "/",
    title: "eControll | ERP de Gestão Empresarial",
    description: "Simplifique a gestão da sua empresa com o eControll. Controle estoque, compras, clientes, fornecedores, serviços e operações em uma plataforma integrada.",
    images: [{
      url: "/opengraph-image",
      width: 1200,
      height: 630,
      alt: "eControll — ERP de Gestão Empresarial",
    }],
  },
  twitter: {
    card: "summary_large_image",
    title: "eControll | ERP de Gestão Empresarial",
    description: "Simplifique a gestão da sua empresa com o eControll. Controle estoque, compras, clientes, fornecedores, serviços e operações em uma plataforma integrada.",
    images: [{ url: "/opengraph-image", alt: "eControll — ERP de Gestão Empresarial" }],
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="pt-BR">
      <body>{children}</body>
    </html>
  );
}
