# eControll — Registro Cronológico de Desenvolvimento

> Registrar somente fatos confirmados. Dados sem evidência são **NÃO VERIFICADOS**.

| Data/Referência | Evento | Evidência | Estado |
|---|---|---|---|
| 2026-10 a 2026-11 | Fundação multiempresa, autorização, cadastros, estoque, compras, O.S. e onboarding | 22 migrations canônicas até `20261110120000` na main auditada | Versionado |
| `68b8e9005e94e2e5907c824d50bc17f5a580dbcb` | Base da Fase 1 | `origin/main` usado pelo worktree dedicado | Local/base publicada |
| 2026-11-16 | Auditoria funcional e de segurança | Leitura de código, migrations e metadados Production | Concluída sem mutação |
| 2026-11-16 | Fase 1 autorizada para desenvolvimento local | D01–D07 aprovadas pelo proprietário | Em andamento local |
| 2026-11-17 | Implementação local da Fase 1 | `20261116180000_purchase_receipt_inventory_valuation.sql`, ações e telas de compras/estoque, testes de contrato | Sem publicação/remoto |
| 2026-11-17 | Validação de aplicação | TypeScript, lint, build e 148 testes Node: PASS | Confirmado localmente |
| 2026-11-17 | Docker Desktop | Daemon `desktop-linux` respondeu (Engine 29.9.2); nenhum contexto foi reconfigurado | Confirmado localmente |
| 2026-11-17 | PostgreSQL isolado | `scripts/test-package-01-postgres.sh` passou em PostgreSQL 17.11 descartável, sem rede; concorrência cruzada específica da Fase 1 permanece pendente | PASS parcial por escopo |
| 2026-11-17 | Correções encontradas pela suíte | FK tenant-scoped de itens do pedido, ambiguidade de variável no estorno e `event_type` em avaliação inicial | Corrigidas localmente |
| 2026-11-17 | Revisão final local | TypeScript, lint, build, 148 testes Node, PostgreSQL isolado, diff e auditoria de segredos | PASS |
| 2026-11-17 | Concorrência cruzada Fase 1 | Duas execuções independentes em PostgreSQL 17.11 descartável: recebimento×transferência, recebimento×inventário e recebimento×consumo de O.S., em ambas as ordens | PASS; 12 disputas reais |
| 2026-11-17 | Hardening da contagem física | `operational_post_inventory_count` passou a adquirir o lock por produto antes do saldo e rejeitar snapshot divergente com `40001`; recontagem e postagem posterior passaram | Corrigido localmente |
| 2026-11-17 | Revisão técnica independente da Fase 1 | Revisão estática da migration, RPCs, ações, telas, ACL/RLS e plano de integração | NO-GO local: risco alto de deadlock no estorno e D05 não totalmente comprovada |
| 2026-11-17 | Estado de integração | Origem local ainda sem commit; `origin/main` local em `68b8e900…`; worktree principal sujo e fora da linha atual | Integração adiada, sem mutação Git |
| 2026-11-17 | Hardening local autorizado | Correção dos riscos de estorno concorrente, rastreabilidade D05, multiitem, interface de contagem obsoleta e plano de estoque legado | Em andamento local; sem mutação remota |
| 2026-11-17 | Hardening de locks e D05 | Helper privado de posição, ordem multiitem por produto, estorno conservador, reservas de O.S. no protocolo e mensagem `40001` na interface | PASS local; não publicado |
| 2026-11-17 | Regressão após hardening | PostgreSQL isolado repetido, 148 testes Node, lint, TypeScript, build, diff e varredura de segredos | PASS local; aguarda revisão final |
| 2026-11-17 | Auditoria independente definitiva | Leitura direta da migration, ações, telas, ACL/RLS e duas execuções novas da suíte PostgreSQL 17.11 descartável | PASS local; GO para integração local, sem mutação remota |
| 2026-11-17 | Integração local Fase 1 | Worktree limpo `codex/phase-01-integration` criado de `origin/main` em `68b8e900…`; paridade de patches conferida e regressão repetida | Versionado localmente; sem push/remoto |

### Evidência da concorrência cruzada e do hardening

- Comando (executado duas vezes em bancos novos):
  `DOCKER_BIN=/Users/nandosouza/.docker/bin/docker scripts/test-package-01-postgres.sh`.
- Cada execução criou container PostgreSQL 17.11 sem rede, com `tmpfs`, e o removeu
  pelo `trap` ao final. As seis disputas por execução foram criadas por dois
  clientes `psql` em background; o primeiro manteve o lock real do saldo durante
  750 ms e o runner observou seu `application_name` em `pg_stat_activity` com
  `wait_event=PgSleep` antes de iniciar o segundo, que disputou esse mesmo lock.
  `lock_timeout=3s` e
  `statement_timeout=8s` bloqueariam aprovação de deadlock ou espera inesperada.
- O conflito de snapshot obsoleto é o único erro esperado: SQLSTATE `40001` para
  recebimento primeiro × contagem física. Após nova leitura, a mesma contagem foi
  postada e auditada. Nenhum timeout/deadlock foi aceito como sucesso.
- O hardening acrescentou disputas reais estorno×recebimento, estorno após
  transferência (bloqueio de negócio D05 esperado), recebimentos multiitem em
  ordem inversa e estornos multiitem em ordem inversa. Cada primeira sessão foi
  observada em `pg_stat_activity` enquanto mantinha o lock real; deadlock ou
  timeout reprovariam o runner. Foram 11 disputas por execução, 22 nas duas
  execuções de hardening; somadas às 12 disputas anteriores, há 34 disputas
  observadas neste worktree.
- Regressão posterior: `node --test tests/*.test.mjs` (148/148), `npm run lint`,
  `npm run typecheck`, `npm run build`, `git diff --check` e varredura de padrões
  de segredos nos artefatos da Fase 1: PASS.

### Auditoria independente definitiva (2026-11-17)

- SHA-256 recalculado diretamente: `f8838d357e68556db1c0fa36ec333b5f0ccde7de449c1b968ca0ea3fb67318d2`.
- A auditoria executou duas novas suítes descartáveis e independentes em PostgreSQL
  17.11, cada uma com 11 disputas reais. O runner observou a primeira sessão em
  `pg_stat_activity`, aplicou `lock_timeout=3s` e `statement_timeout=8s`, e
  reprovou timeout, deadlock ou resultado diferente do esperado.
- A exceção `40001` da contagem obsoleta e as exceções `55000` de D05 após
  transferência/consumo foram esperadas e verificadas como bloqueios de negócio;
  não foram consideradas sucesso silencioso.
- Nenhuma operação remota, migration, grant, flag, commit, merge, push ou deploy
  foi executado nesta auditoria.

### Integração local auditável (2026-11-17)

- Base confirmada após `git fetch origin`: `origin/main` permaneceu em
  `68b8e9005e94e2e5907c824d50bc17f5a580dbcb`; não houve conflito remoto.
- Branch local de integração: `codex/phase-01-integration` no worktree
  `/private/tmp/econtroll-phase-01-integration`.
- Commits locais, em ordem: `b176a7e` (migration e lógica), `a397e6c`
  (interface), `def071c` (testes) e o commit de documentação desta entrada.
- Regressão no worktree novo: 148/148 Node, lint, TypeScript, build, diff,
  segredos e PostgreSQL 17.11 com concorrência real: PASS. A instalação via
  lockfile foi necessária pois o novo worktree não possuía `node_modules`.
- Sem push, deploy, migration remota, grants, flags ou mudança em Production.

### Resultado da revisão independente e correção

- Histórico confirmado: o estorno bloqueava `inventory_balances ... FOR UPDATE` antes de
  chamar `apply_inventory_valuation_delta`, enquanto recebimento, transferência
  e consumo obtêm primeiro o advisory lock e depois a linha. Em concorrência
  cruzada, isso forma uma inversão de locks e pode gerar deadlock; os 12 testes
  anteriores não incluíram estorno concorrente.
- Histórico confirmado: o estorno verificava saldo disponível e reservas, mas não provava que
  a quantidade devolvida não foi afetada por transferência, consumo ou movimento
  posterior. O bloqueio exigido pela decisão D05 ainda não está coberto nem
  implementado de forma demonstrável.
- Correção: `app_private.lock_inventory_position` centraliza locks advisory;
  recebimentos e estornos validam e pré-adquirem todas as posições por `item_id`
  antes de bloquear documentos/saldos. Transferência, contagem, reserva/consumo/
  reversão de O.S. e avaliação inicial usam a mesma posição antes do saldo.
  `assert_purchase_receipt_reversal_traceability` bloqueia reserva ativa e saída
  posterior (saída, ajuste negativo, transferência, inventário negativo ou
  consumo de O.S.). Estorno parcial repetido sem fato posterior continua válido.
- Nenhum problema de isolamento de empresa/filial, ACL ampla, `anon`,
  `service_role`, RLS/FORCE RLS ou acesso direto às novas tabelas foi encontrado
  na revisão estática. Essas conclusões não substituem os testes pendentes de
  estorno concorrente.

## Onboarding empresarial

O repositório contém onboarding em `20261110120000_company_onboarding_activation.sql`.
Resultados de convites e testes anteriores não foram repetidos neste worktree e
permanecem **NÃO VERIFICADOS** aqui.

Após cada implementação, anexar data, arquivos, migration, RPCs, testes reais,
commit quando existir, ambiente e autorizações usadas.
