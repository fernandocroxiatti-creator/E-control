import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "eControl",
  description: "Estrutura inicial do eControl.",
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
