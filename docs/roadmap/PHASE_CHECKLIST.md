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
- [x] Commits locais auditáveis na branch `codex/phase-01-integration`:
  `b176a7e`, `a397e6c` e `def071c`; publicação continua separada.
- [ ] Revisão pré-publicação, push e deploy autorizados separadamente.
- [ ] Aprovação e aplicação de migration Production autorizadas separadamente.

## Fases 2–9

- [ ] Fase 2 somente após aceite da Fase 1.
- [ ] Fases 3–9 somente na ordem de `MASTER_PLAN.md`.

## Registro de migrations

| Migration | Estado |
|---|---|
| Até `20261110120000` | Aplicada/confirmada anteriormente; não reaplicar |
| `20261116180000_purchase_receipt_inventory_valuation.sql` | Hardening local validado; SHA-256 `f8838d357e68556db1c0fa36ec333b5f0ccde7de449c1b968ca0ea3fb67318d2`; não aplicada em Production |
