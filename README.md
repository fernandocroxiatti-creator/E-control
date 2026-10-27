# eControl

Aplicação inicial do eControl com Next.js, TypeScript, App Router e autenticação por Supabase Auth. A área autenticada é apenas de preparação; não expõe dados empresariais ou módulos do ERP.

## Requisitos

- Node.js 20.9 ou superior.
- npm.

## Executar localmente

```bash
npm install
npm run dev
```

Abra <http://localhost:3000> no navegador.

## Verificações locais

```bash
npm run lint
npm run typecheck
npm run build
```

## Configurar o Supabase Auth localmente

Copie `.env.example` para `.env.local` e informe a chave **publishable** do projeto Supabase:

```bash
cp .env.example .env.local
```

Produção exige `ECONTROLL_SUPABASE_TARGET=production`, `ECONTROLL_PROD_ENABLED=true`, `ECONTROLL_PROD_PROJECT_ID`, `ECONTROLL_PROD_SUPABASE_URL`, `ECONTROLL_PROD_SITE_URL`, `NEXT_PUBLIC_SUPABASE_URL` e `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, todos coerentes com o projeto de produção. Para Vercel Preview, basta configurar as variáveis padrão `NEXT_PUBLIC_SUPABASE_URL` e `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` com a URL e a chave publishable da HML: o resolvedor aceita somente a URL exata de HML, recusa qualquer referência à produção e mantém criação, gestão e convites desativados. `NEXT_PUBLIC_SUPABASE_ANON_KEY` não é usado. Links de recuperação usam o domínio Preview fornecido pela Vercel, limitado ao projeto `e-control`; inclua o padrão de Preview na allowlist de redirecionamento do Supabase HML. O fluxo de convite usa o papel fixo `company_owner`, que precisa estar aprovado no catálogo; o convite não cria usuários nem concede Admin Master. Nunca configure `service_role` ou chaves secretas no frontend.

O cadastro público está desativado. O login depende de uma conta provisionada por um processo administrativo autorizado. Os recursos empresariais dependem das migrations correspondentes e das flags explícitas do ambiente; o Preview usa a HML com operações de escrita desativadas.
