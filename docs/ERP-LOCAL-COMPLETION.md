# Implementação local de Tesouraria, Gestão e SaaS

Base: `6718657`. Branch: `codex/local-erp-completion`.

Os worktrees originais de Tesouraria, Analytics, Caixa/Relatórios e SaaS foram preservados. As três migrations não versionadas encontradas foram copiadas para integração e corrigidas; a migration SaaS recebeu timestamp distinto para evitar colisão com Tesouraria. Nenhuma migration foi aplicada a Supabase remoto.

## Funcionalidades entregues

| Área | Comportamento local |
| --- | --- |
| Contas bancárias | Cadastro com saldo inicial, consulta de saldo, edição do nome e inativação condicionada a saldo zero e movimentos conciliados. |
| Transferências | Duas partidas atômicas, mesma empresa e filial, idempotência por solicitação e bloqueio ordenado das contas. |
| Movimentos | Entradas e saídas bancárias independentes de baixas financeiras, com auditoria. |
| Conciliação | Conferência manual de data, valor assinado e referência única de extrato por conta; desfazimento com justificativa e auditoria. |
| Fluxo de caixa | Realizado pelas baixas financeiras válidas; previsão pelos saldos de parcelas abertas e seus vencimentos. Estornos excluídos. Não soma novamente caixa, bancos e transferências. |
| DRE | Classificação explícita das obrigações em receita, dedução, custo, despesa e resultado financeiro; data de competência; alerta de obrigações não classificadas. |
| Dashboard e exportação | Saldos financeiros, resultado classificado e fluxo diário; exportação CSV com autorização própria, contexto empresarial, período e proteção contra fórmulas. |
| Planos e assinaturas | Catálogo persistente, limites de capacidade, ciclo pending/active/past_due/suspended/cancelled, histórico e auditoria Master. |
| Onboarding | Fluxo existente de criação, convite e ativação preservado, integrado à visão de empresas/assinaturas e coberto pela regressão de PostgreSQL. |
| Transações | ZTR02–ZTR05 e ZGE01–ZGE02 cadastradas pendentes, resolvidas pelo servidor e disponíveis para revisão manual no catálogo Master. |

Rotas: `/operacional/bancos`, `/operacional/gestao`, `/operacional/gestao/exportar` e `/master/planos`. Navegação operacional atualizada.

## Segurança

- Tabelas novas com RLS forçada e sem privilégios diretos para public, anon, authenticated ou service_role.
- RPCs com search_path vazio, ACL explícita, sessão autenticada, escopo empresarial/filial e aprovação/disponibilidade/grant verificados no banco.
- Server Actions usam cliente SSR do usuário, lista fixa de operações e validação dos campos. Escritas SaaS exigem Master e flag de governança do ambiente.
- Assinaturas não concedem grants, não ativam empresas e não alteram a liberação operacional.
- Nenhuma concessão Master real foi executada. Fixtures Master/grants existem apenas no PostgreSQL local descartável.
- ZIV01 não foi alterada nem liberada. G1 e homologação empresarial continuam sendo decisões manuais.
- Revisão dos arquivos candidatos e do bundle do navegador sem identificação de credenciais privadas. Nenhum arquivo de ambiente, conteúdo de `work/` ou evidência privada integra o commit.

## Validações

- `npm run lint`: passou.
- `npm run typecheck`: passou.
- `npm run build`: passou (Next.js 16.4.6).
- `node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON --experimental-strip-types --test tests/*.test.mjs`: 193 testes passaram.
- `bash scripts/test-package-01-postgres.sh`: passou em PostgreSQL 17.11 descartável, sem rede, usando harness Auth/Foundation.
- Inclui regressões anteriores de onboarding, permissões, compras, estoque, vendas, faturamento e caixa; novos testes de idempotência, conciliação, isolamento de tenant/filial, módulo desativado, exportação sem permissão, estornos, estados SaaS e ACL.
- Smoke HTTP local sem configuração Supabase: bancos e gestão redirecionaram ao login (307), exportação bloqueou (403), Master exibiu somente indisponibilidade de autorização, sem formulário de mutação.
- Concorrência bancária: duas sessões reais, transferências em sentidos opostos, espera de lock observada; quatro partidas persistidas e saldo líquido zero em cada conta.

## Limites e homologação pendente

A homologação automatizada local passou; isso não equivale a homologação operacional em Supabase/Vercel com usuários reais. Não houve publicação, deploy, aplicação remota, alteração externa ou liberação de empresa.

A DRE é gerencial sobre obrigações classificadas, não escrituração contábil. Faturamento comercial continua sem gerar automaticamente obrigação financeira, conforme o comportamento da base publicada. A conciliação é manual; não há conexão com banco nem importação OFX. O SaaS é gestão comercial manual: sem gateway, cobrança recorrente, bloqueio operacional por inadimplência ou aplicação contínua de limites após ativação. O teste local não cobre entrega real de emails, sessão de usuário no Supabase remoto nem validação visual autenticada das novas telas.

Antes da publicação, o proprietário precisa aprovar especificamente o conjunto que altera banco, permissões e funções administrativas. A aplicação de cada migration remota exige autorização separada. Depois disso, conferir integração GitHub–Vercel, variáveis sem expor valores, URLs de autenticação, deploy READY e fluxos autenticados por filial. Não liberar ZIV01 nem operações empresariais reais por consequência do deploy.
