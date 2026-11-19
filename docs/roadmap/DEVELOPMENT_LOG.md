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
| 2026-11-17 | Revisão pré-publicação e plano de rollout | Leitura da migration, schema local, histórico e branch integrada; nenhuma consulta a dados reais | GO apenas para preparação; nenhuma mudança remota autorizada por este registro |
| 2026-11-17 | Auditoria final pré-push | Encontradas lacunas de payload divergente em movimento avaliado, transferência e valuation inicial | NO-GO para push até hardening local |
| 2026-11-17 | Hardening final de idempotência | Comparação integral normalizada, locks globais por `request_id`, testes comportamentais e 16 novas disputas reais | PASS local; aguarda nova auditoria, sem commit/remoto |
| 2026-11-17 | Auditoria independente do hardening de idempotência | Reprodução em PostgreSQL 17.11 de replay idêntico de entrada pública com custo derivado | **NO-GO:** `23505` indevido; nenhum commit/remoto |
| 2026-11-17 | Correção do replay com custo derivado | Persistência de modo de entrada de custo e cobertura comportamental/concorrente ampliada | PASS local; aguarda nova auditoria, sem commit/remoto |
| 2026-11-17 | Auditoria final pré-commit | Reexecução independente da suíte PostgreSQL 17.11, 30 cenários concorrentes reais, Node 148/148, lint, TypeScript, build, `bash -n`, diff e segredos | **GO para sexto commit local**; sem mutação remota |

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

### Plano de rollout local revisado (2026-11-17)

- A migration deve ser aplicada somente após backup lógico criptografado, checksum
  e restauração essencial comprovada em ambiente descartável. Um backup existente
  não é presumido válido sem nova verificação de integridade.
- A aplicação é atômica por estar envolvida em `begin`/`commit`; falha durante a
  migration deve deixar o schema anterior. Após `commit`, não há down migration
  segura: dados de valuation ou recebimentos novos exigem recuperação aprovada ou
  correção forward-only auditável, nunca `DROP` automático.
- Saldos legados recebem `valuation_status='pending'`. Posições pendentes com
  quantidade diferente de zero bloqueiam movimentos até avaliação inicial ZIV01;
  posições zeradas podem ser valoradas pelo primeiro inbound com custo explícito.
- Não aprovar ZIV01/ZGR01, módulos, disponibilidade ou grants até a migration,
  suas verificações de ACL/RLS e a seleção explícita de empresa/filial piloto.

### Correção final de idempotência (2026-11-17)

- Causa confirmada: `inventory_movements`, `inventory_transfers` e
  `inventory_valuation_events` já protegiam duplicidade física por chave única,
  mas alguns retornos idempotentes não comparavam todo o comando original.
- Correção local: movimentos com valuation comparam filial, produto, tipo,
  quantidade, custo de entrada, referência normalizada, documento de origem e
  responsável; transferências comparam origem, destino, produto, quantidade,
  referência e responsável; ZIV01 compara filial, produto, custo, justificativa
  normalizada, tipo do evento e responsável. O snapshot de quantidade de ZIV01
  é fato gerado pelo servidor, não campo de entrada do cliente.
- Normalização legítima: referência e justificativa usam `btrim` e vazio vira
  `NULL` apenas para referência; quantidades acima de quatro e custos acima de
  oito casas decimais são rejeitados antes de persistência, sem arredondamento
  silencioso. Divergência responde `23505`.
- A suíte local adicionou 16 disputas cross-session: seis de movimento avaliado,
  cinco de transferência e cinco de valuation inicial. Em cada uma, a primeira
  sessão foi observada em `pg_stat_activity` durante pausa de trigger de teste;
  replay igual foi aceito uma vez e divergente foi capturado explicitamente como
  `unique_violation` (`23505`). Não houve timeout ou deadlock aceito.
- Os cinco commits anteriores permanecem preservados, em ordem:
  `b176a7e`, `a397e6c`, `def071c`, `a9e3ec5`, `0073dd0`. Esta correção ainda não
  possui commit, push, deploy ou mutação remota.

### Auditoria independente do hardening de idempotência (2026-11-17)

- Achado alto confirmado: `public.operational_record_inventory_movement` chama
  `apply_inventory_valuation_delta` com `p_unit_cost = NULL` para uma entrada
  cujo custo é derivado da média da filial. No replay idêntico, o comparador
  confronta esse `NULL` com `existing.unit_cost_applied` não nulo e lança
  `23505`, embora o payload do cliente seja igual. Não duplica fatos, mas viola
  a idempotência e a disponibilidade do comando.
- A reprodução foi executada no mesmo fluxo autenticado da fixture em PostgreSQL
  17.11 descartável; o erro veio explicitamente da comparação de payload da
  função privada, não de lock, RLS, ACL ou restrição única incidental.
- O runner é confiável quanto ao código de saída: sem a sonda de falha terminou
  com `RUNNER_EXIT_CODE=0`; com a reprodução obrigatória terminou com
  `RUNNER_EXIT_CODE=3`. A variável reservada `status` que afetou uma coleta
  anterior pertencia ao invólucro zsh externo, não ao runner bash.
- A auditoria identificou como cobertura necessária replay com custo derivado,
  referência `NULL`/vazia/espaçada e escopo de `request_id` entre operações.
  Essa cobertura foi adicionada pela correção seguinte. Nenhuma decisão D01–D08
  foi modificada.

### Correção do replay com custo derivado (2026-11-17)

- `inventory_movements.unit_cost_input_mode` agora persiste `explicit` quando a
  função de valuation recebe custo e `derived` quando o custo foi omitido e a
  média móvel bloqueada foi usada. Fatos legados ficam `NULL` e não são
  reaproveitados silenciosamente como replays.
- O retorno idempotente compara modo, além de empresa, filial, produto, tipo,
  quantidade, referência normalizada, documento e ator. No modo `explicit`, o
  custo informado continua sendo comparado sem arredondamento silencioso; no
  modo `derived`, o custo calculado persistido não é comparado com o `NULL` do
  payload. Alternar entre os modos para o mesmo request falha com `23505`.
- A unicidade de `request_id` é por `(empresa, operação)`, por exemplo, ledger
  de movimento, transferência e valuation têm constraints/tabelas próprias e
  locks advisory com namespaces próprios. Reuso entre operações não retorna nem
  altera fatos de outro tipo; o teste local documenta esse contrato.
- Foram adicionados testes para replay derivado sequencial e concorrente,
  alternância derivado↔explícito, custo explícito divergente, referência
  `NULL`/vazia/espaçada/equivalente/diferente, namespace entre operações e
  ausência de fatos duplicados. Node 148/148, lint, TypeScript, build e
  `git diff --check`: PASS local. A evidência PostgreSQL desta correção deve
  ser repetida: a auditoria posterior encontrou um defeito na barreira do
  runner, descrito abaixo.
- SHA atual da migration: `f7a8e4648e82cbffadcbb6d23d192912d02ba93aa4ef449dffe62502ccdbcda3`.

### Auditoria independente final do custo derivado (2026-11-17)

- A execução isolada aplicou todas as migrations e passou pelos cenários
  comportamentais anteriores à concorrência de replays, mas terminou com exit
  code `1` na barreira `movement-derived-same`.
- Causa comprovada no runner: `run_phase01_pair` usa o nome integral da dupla
  como `application_name`; PostgreSQL o trunca a 63 bytes, enquanto
  `wait_phase01_pause` procura o texto original. A falha é do mecanismo de
  observação da barreira, não uma evidência de deadlock, timeout ou falha do
  ledger.
- Consequência: o resultado PostgreSQL completo não pode ser marcado PASS até
  que o rótulo seja limitado de forma determinística e todos os cenários sejam
  repetidos com exit code `0`. Nenhuma alteração remota, commit ou Fase 2 foi
  realizada.

### Correção da barreira PostgreSQL e cobertura entre namespaces (2026-11-17)

- O runner passou a gerar `application_name` no formato ASCII
  `p01-<cenário>-<sequência>`. O tamanho é validado em bytes por `LC_ALL=C` e
  limitado a 63, inclusive para o rótulo da segunda sessão. Cada rótulo é único
  na execução e a sonda pesquisa exatamente o mesmo valor em
  `pg_stat_activity`.
- A barreira também testa uma sessão inexistente sem falso PASS e rejeita
  identificadores duplicados ou acima do limite. As falhas de `psql`, timeout ou
  deadlock continuam propagadas por `set -euo pipefail` e pelos status de
  processos aguardados explicitamente.
- Foram acrescentadas duas disputas reais com o mesmo `request_id` em
  namespaces distintos: movimento→transferência e transferência→movimento. Em
  ambas, a primeira sessão foi observada no lock, cada operação persistiu um
  único fato próprio e o saldo agregado do item conservou quantidade `22` e
  valuation `222`.
- Duas execuções normais completas em PostgreSQL 17.11 descartável, sem rede,
  terminaram com exit code `0`. Cada uma observou 30 disputas reais, incluindo
  recebimento, D05, inventário, O.S., multiitem, replays explícitos/derivados,
  transferência, valuation e os dois cenários entre namespaces. Os únicos
  erros impressos foram os bloqueios de negócio esperados `40001` e `55000`.
- A migration permaneceu inalterada, com SHA-256
  `f7a8e4648e82cbffadcbb6d23d192912d02ba93aa4ef449dffe62502ccdbcda3`.
  Os cinco commits anteriores foram preservados; não houve commit, push,
  deploy, alteração remota ou início da Fase 2.

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

### Auditoria final pré-commit (2026-11-17)

- A suíte PostgreSQL isolada foi reexecutada em container descartável e sem
  rede, com exit code `0`. O runner observou 30 contenções reais via
  `pg_stat_activity`/`PgSleep`; timeout, deadlock e erro inesperado continuam
  reprovando a execução.
- Node passou 148/148; lint, TypeScript, build, `bash -n`, `git diff --check` e
  a auditoria de segredos passaram. O único marcador de senha no runner é a
  credencial fixa do PostgreSQL temporário e sem rede.
- O SHA-256 da migration foi reconfirmado como
  `f7a8e4648e82cbffadcbb6d23d192912d02ba93aa4ef449dffe62502ccdbcda3`.
  Nenhuma alteração remota, de Production ou da Fase 2 foi executada.

Após cada implementação, anexar data, arquivos, migration, RPCs, testes reais,
commit quando existir, ambiente e autorizações usadas.

### Governança empresarial limitada da Fase 1 (2026-11-19)

- Causa confirmada: `role_permission_grants` é global por papel. Um grant de
  recebimento para `company_owner` liberaria todas as empresas com o mesmo
  papel, mesmo quando a disponibilidade da transação fosse empresarial.
- Correção local: `20261118190000_company_scoped_permission_governance.sql`
  cria um grant aditivo por `(tenant_id, branch_id, role_key, permission_key)`.
  Ele só é considerado com filial explícita, vínculo ativo, papel/permissão
  aprovados e acesso autorizado à filial. Nesta entrega, a RPC aceita somente
  `company_owner` com `transaction.purchasing.receipt.manage` (ZGR01), evitando
  que a infraestrutura do piloto habilite outras transações.
- As decisões Master de catálogo, grant e disponibilidade passam a exigir
  justificativa de 10–1000 caracteres, persistida na auditoria. Não há grant,
  disponibilidade ou aprovação automática.
- Verificações locais: Node 151/151, TypeScript, lint, build, `bash -n`,
  `git diff --check` e PostgreSQL 17.11 isolado com concorrência real: PASS.
  Sem commit, push, deploy, migration ou alteração remota.
- Reexecução final: a fixture confirmou também a revogação persistida e sua
  justificativa na auditoria. A suíte PostgreSQL descartável terminou com
  exit code `0` e observou 32 barreiras reais de concorrência; os bloqueios de
  inventário obsoleto e D05 foram os resultados de negócio esperados.
- SHA-256 local: `fef0ad3bd9001bba1c3731718ad91ed04cd650adce132106e254ff2e9cb93ef6`.

### Revisão final e preparação de release da governança (2026-11-19)

- Auditoria local confirmou que a nova RPC é limitada no banco a
  `company_owner` + `transaction.purchasing.receipt.manage` (ZGR01). Papel,
  permissão, empresa, filial, vínculo, aprovação e disponibilidade continuam
  sendo verificados separadamente; ZIV01 e qualquer permissão fora do escopo
  falham fechadas.
- A compatibilidade foi examinada por busca de consumidores: somente as Server
  Actions Master usam as três assinaturas administrativas substituídas. A suite
  aplica e exercita o contrato antigo antes da migration e prova que, depois,
  as assinaturas antigas deixam de existir, sem caminho de escrita sem razão.
- A estratégia aprovada localmente é code-first/fail-closed: publicar a
  interface já validada, mantê-la indisponível para mutações até a migration e
  então aplicar a migration em janela administrativa. Não existe fallback
  compatível que aceite mutação sem justificativa.
- Regressão final: PostgreSQL 17.11 descartável (32 barreiras reais; exit `0`),
  Node 151/151, lint, TypeScript, build, `bash -n`, `git diff --check` e
  varredura de segredos: PASS. Nenhuma operação remota foi executada.
