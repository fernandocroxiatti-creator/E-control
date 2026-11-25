# eControll — Checklist de Fases

Legenda: `[ ]` pendente, `[~]` em andamento, `[x]` concluído com evidência.

## Pré-tarefa

- [x] Ler os cinco documentos de controle.
- [x] Verificar branch, worktree e alterações preexistentes.
- [x] Isolar a Fase 1 em worktree baseado na main publicada.

## Fase 1 — Recebimento, estoque e custo médio

- [x] Auditoria de compras, estoque, custo e O.S.
- [x] D01–D07 aprovadas e registradas.
- [x] Migration incremental, RPCs e interface locais (envio, recebimento, estorno e avaliação inicial).
- [x] Testes SQL isolados: parcial, total, retry, excesso, divergência de custo, estorno, valuation, isolamento e ACLs — PostgreSQL 17.11 descartável.
- [x] Concorrência cruzada Fase 1: duas execuções independentes, com sessões reais,
  barreira por contenção deliberada, `lock_timeout=3s`, `statement_timeout=8s` e
  ambas as ordens para recebimento×transferência, recebimento×inventário e
  recebimento×consumo de O.S. Nenhum deadlock, timeout ou duplicidade aceito.
- [x] Testes Node, lint, TypeScript e build; auditoria de segredos e revisão de diff.
- [x] Revisão de diff e critérios de aceite locais.
- [x] Hardening e testes de estorno concorrente: helper de locks ordenados,
  pré-lock multiitem por produto, D05 conservadora, `40001` compreensível e
  fixtures reais de estorno/recebimento/transferência/multiitem — PostgreSQL
  17.11 descartável, duas execuções finais sem deadlock ou timeout.
- [x] Nova revisão independente do hardening, riscos legados e plano de integração —
  SHA conferido, duas novas execuções PostgreSQL concorrentes, 148 testes Node,
  lint, TypeScript, build, diff e segredos: PASS local em 2026-11-17.
- [~] Planejamento de rollout legado para Production — necessário antes de uma
  autorização de migration; não faz parte da integração local.
- [x] Plano pré-publicação local: ordem, backup, recuperação, piloto, controles
  ZIV01/ZGR01 e aceite documentados; nenhuma etapa remota foi executada.
- [x] Commits locais auditáveis na branch `codex/phase-01-integration`:
  `b176a7e`, `a397e6c`, `def071c`, `a9e3ec5` e `0073dd0`; publicação continua separada.
- [x] Correção local de idempotência para custo derivado: modo de entrada de
  custo persistido, replay derivado idêntico, alternância derivado↔explícito,
  custo explícito divergente, referência normalizada e namespace por operação
  implementados e confirmados em concorrência real. A barreira usa
  `application_name` de até 63 bytes, rejeita ausência de sessão e passou em
  duas execuções PostgreSQL 17 descartáveis, incluindo as duas ordens de
  movimento×transferência com mesmo `request_id`.
- [x] Auditoria final pré-commit: PostgreSQL 17.11 isolado, 30 cenários
  concorrentes reais, Node 148/148, lint, TypeScript, build, `bash -n`, diff e
  auditoria de segredos aprovados; **GO apenas para o sexto commit local**.
- [ ] Aprovação e aplicação de migration Production autorizadas separadamente.
- [ ] Backup Production criptografado, checksum e restauração essencial
  revalidados imediatamente antes da migration.
- [ ] Inventário somente leitura dos saldos pendentes e aprovação da janela
  operacional para avaliação inicial.
- [ ] Aprovação, disponibilidade e grant ZIV01 apenas para piloto.
- [ ] Aprovação, disponibilidade e grant ZGR01 apenas após valuations aceitas.
- [ ] Aceite do piloto, expansão gradual e relatório de auditoria.
- [x] Correção local de governança: grant aditivo por empresa/filial e
  justificativa auditável; Node 151/151, TypeScript, lint, build e PostgreSQL
  isolado PASS em 2026-11-19. A suíte final confirmou revogação auditada e
  32 barreiras de concorrência reais, com exit code `0`.
- [ ] Revisão/autorização de publicação da migration
  `20261118190000_company_scoped_permission_governance.sql`; esta correção não
  autoriza aprovação nem concessão remota.
- [x] Compatibilidade verificada: somente Server Actions Master consomem as
  assinaturas substituídas; teste isolado prova que as assinaturas sem
  justificativa não permanecem executáveis após a migration. O rollout exige
  janela administrativa coordenada, sem fallback inseguro.
- [x] Revisão final local: grants de piloto fechados a `company_owner` + ZGR01,
  PostgreSQL isolado com 32 barreiras (exit `0`), Node 151/151, lint,
  TypeScript, build, `bash -n`, diff e segredos: PASS.
- [x] Diagnóstico do piloto: disponibilidade empresarial de BP01, MM01–MM03,
  SV01, ME21N, ME23N e ZGR01 confirmada pelo painel oficial; ZIV01 permanece
  não habilitada.
- [~] Extensão local de grants empresariais mínimos para cadastros e compras:
  migration `20261124110000_company_scoped_pilot_operational_entitlements.sql`,
  Node 156/156, lint, TypeScript, build e PostgreSQL isolado PASS; pendente de
  revisão, commit, publicação e autorização remota específica.

## Fases 2–9

- [ ] Fase 2 somente após aceite da Fase 1.
- [ ] Fases 3–9 somente na ordem de `MASTER_PLAN.md`.

## Registro de migrations

| Migration | Estado |
|---|---|
| Até `20261110120000` | Aplicada/confirmada anteriormente; não reaplicar |
| `20261116180000_purchase_receipt_inventory_valuation.sql` | Aplicada em Production no rollout anterior informado; SHA-256 `f7a8e4648e82cbffadcbb6d23d192912d02ba93aa4ef449dffe62502ccdbcda3`. Nesta execução não houve nova consulta ou mutação remota. |
| `20261118190000_company_scoped_permission_governance.sql` | Aplicada em Production no rollout de governança registrado; SHA-256 `6a8ad42e233ee6742f6ae19690caab4e8b3cf041e157dd58862d804fd8b2660e`. Não cria grants, disponibilidade ou aprovações automaticamente. |
| `20261124110000_company_scoped_pilot_operational_entitlements.sql` | Aplicada em Production no rollout confirmado de 2026-11-24; SHA-256 `876793f2d8028569d583cc79b54a06d84d34bd6b16d5456ee77fad808cce0d13`. Não cria grants, disponibilidade, aprovações ou vínculos automaticamente. |

## Governança legada — preparação local 2026-11-24

- [x] Mapear grants globais operacionais legados sem expor dados pessoais.
- [x] Confirmar que a remoção direta causaria regressão para vínculos ativos.
- [x] Confirmar incompatibilidade entre cadastros sem filial e grants estritos
  por filial.
- [x] Documentar arquitetura de transição e pós-condições fail-closed.
- [x] Aprovar a política de escopo empresa versus filial (D12).
- [x] Implementar migration incremental e testes isolados.
- [x] Reproduzir e corrigir a normalização de grants piloto pré-existentes;
  rollback remoto anterior confirmado sem alteração parcial.
- [x] Reproduzir grants de catálogo scoped sem fallback global e normalizá-los
  somente sob a política D12, com auditoria.
- [x] Verificar SHA-256 da migration local corrigida:
  `6dfb45d15278694af727bafc06ffd5a97ea9ecc9cc316aa119222938144b8a59`.
- [ ] Concluir revisão final, commit local e publicação coordenada com backup
  atual antes da migration remota.
