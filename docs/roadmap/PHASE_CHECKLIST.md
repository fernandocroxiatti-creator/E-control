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

## Fases 2–9

- [ ] Fase 2 somente após aceite da Fase 1.
- [ ] Fases 3–9 somente na ordem de `MASTER_PLAN.md`.

## Registro de migrations

| Migration | Estado |
|---|---|
| Até `20261110120000` | Aplicada/confirmada anteriormente; não reaplicar |
| `20261116180000_purchase_receipt_inventory_valuation.sql` | Hardening de idempotência local auditado e pronto para sexto commit; SHA-256 `f7a8e4648e82cbffadcbb6d23d192912d02ba93aa4ef449dffe62502ccdbcda3`; não aplicada em Production |
