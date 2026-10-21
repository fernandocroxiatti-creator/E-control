import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "eControll",
  description: "Estrutura inicial do eControll.",
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
