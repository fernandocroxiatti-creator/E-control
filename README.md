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

`NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` e `NEXT_PUBLIC_SITE_URL` são usados pela integração do navegador/servidor e para os links de recuperação. Não use chaves `service_role` ou `secret` nessas variáveis. Configure também a URL local nas URLs permitidas de redirecionamento do Supabase Auth antes de testar a recuperação de senha.

O cadastro público está desativado. O login depende de uma conta provisionada por um processo administrativo autorizado. A migração multiempresa ainda não foi aplicada/validada e esta interface não disponibiliza dados ou permissões empresariais.
