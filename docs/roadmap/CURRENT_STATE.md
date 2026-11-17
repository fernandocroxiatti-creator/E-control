# eControll — Estado Atual Verificado

Atualizado em 2026-11-17.

- Worktree de origem preservado: `/private/tmp/econtroll-phase-01-receiving`.
- Worktree de integração: `/private/tmp/econtroll-phase-01-integration`.
- Branch de integração: `codex/phase-01-integration`, criada de `origin/main`
  após fetch em `68b8e9005e94e2e5907c824d50bc17f5a580dbcb`.
- Commits locais de integração: `b176a7e` (lógica e migration), `a397e6c`
  (interface) e `def071c` (testes). A documentação desta atualização será
  versionada separadamente.
- Production possui migrations confirmadas até `20261110120000`; esta tarefa não
  aplicará migration, dados, flags ou permissões remotas.

## Fundação reutilizada

- `purchase_orders` e `purchase_order_items`: rascunho, edição e consulta.
- `inventory_balances` e `inventory_movements`: quantidade por filial, movimentos
  idempotentes, locks e bloqueio de saldo negativo.
- `catalog_items.current_cost` e `catalog_item_cost_history`: custo de catálogo,
  não valuation por filial.
- Transferência, inventário e consumo/reversão de O.S. já são RPCs auditadas.

## Lacuna da Fase 1

Não existem recebimentos, estornos de recebimento, valor de estoque, custo médio
por filial ou custo snapshot por movimento. A Fase 1 criará esses fatos sem gerar
contas a pagar, financeiro, caixa, venda, faturamento ou dados de Production.

## Implementação local pendente de aceite

- Migration local `20261116180000_purchase_receipt_inventory_valuation.sql` adiciona
  recebimentos parciais, estornos, custo médio móvel por filial e avaliação inicial
  auditada de saldo legado. SHA-256 local atual:
  `f8838d357e68556db1c0fa36ec333b5f0ccde7de449c1b968ca0ea3fb67318d2`.
- `ZGR01` e `ZIV01` permanecem em aprovação pendente; a migration não cria grants
  de papel nem disponibilidade empresarial.
- A interface usa RPCs novas apenas quando a transação é autorizada; a ausência da
  migration é apresentada como indisponibilidade, sem salvar dados simulados.
- Compras agora prevê envio explícito do pedido, recebimento parcial/total e
  solicitação de estorno com confirmação. Estoque prevê consulta de valuation e
  avaliação inicial; ambos continuam protegidos até aprovação de ZGR01/ZIV01.
- PostgreSQL 17.11 isolado passou em container descartável e sem rede, inclusive
  duas execuções independentes das concorrências cruzadas. A migration e a suíte
  continuam somente locais; nenhum comando remoto foi emitido e Production
  permanece inalterada.

## Concorrência validada

- Recebimento × transferência: locks por produto/filial serializaram ambas as
  ordens; quantidade total e valor total foram preservados, sem movimentos
  duplicados.
- Recebimento × inventário: recebimento anterior tornou a contagem obsoleta e a
  postagem falhou com `40001`; após recontagem, a postagem foi auditada. Na ordem
  inversa, a contagem foi postada e o recebimento posterior preservou valuation.
- Recebimento × consumo de O.S.: reserva consumida uma vez, sem saldo negativo,
  com custo snapshot e auditoria preservados em ambas as ordens.

## Hardening concluído; revisão final ainda pendente

- **Ordem global:** idempotência/documento quando aplicável → advisory locks
  `(empresa, filial, produto)` em ordem determinística → linhas documentais →
  saldo. O helper privado é usado por recebimento, estorno, movimentação,
  transferência, contagem, reserva/consumo/reversão de O.S. e valuation inicial.
- **D05 conservadora:** o estorno consulta o fato original, estornos anteriores,
  reservas ativas e saídas posteriores. Reserva ativa ou saída posterior bloqueia
  explicitamente com `55000`; recebimentos posteriores e estornos anteriores não
  bloqueiam estorno parcial restante. Não há suposição de lote.
- **Interface:** `40001` de contagem obsoleta informa recontagem, sem retry.
- **Risco de rollout legado:** a migration marca todos os saldos existentes como
  `pending`, bloqueando movimentos até uma avaliação inicial ZIV01 por
  empresa+filial+produto. Isso é intencional por D02, mas exige inventário,
  plano de janela operacional e aprovação prévia antes de Production.

Fase 1 permanece local, foi **integrada e versionada em branch dedicada** e
está pronta somente para revisão pré-publicação autorizada. Não está publicada
ou aplicada em Production.

## Evidência da auditoria independente definitiva

- SHA-256 recalculado diretamente: `f8838d357e68556db1c0fa36ec333b5f0ccde7de449c1b968ca0ea3fb67318d2`.
- Duas execuções novas da suíte PostgreSQL 17.11 descartável passaram, cada uma
  com 11 disputas cross-session reais. Locks, timeout e as invariantes de
  quantidade, valor, custo e auditoria foram verificados pelo runner.
- `node --test tests/*.test.mjs` (148/148), lint, TypeScript, build,
  `git diff --check` e varredura de segredos passaram. Os avisos ESM do Node são
  pré-existentes, sem falha de teste.
- A revisão não encontrou acesso direto às tabelas novas, `EXECUTE` para anon ou
  service_role, concessão automática de ZGR01/ZIV01, nem efeito financeiro.
- Riscos residuais não bloqueantes da integração local: transferência em lote
  continua fora do contrato; a tipagem de leitura de histórico ainda não nomeia
  os tipos novos de recebimento/estorno para apresentação especializada. Ambos
  devem ser tratados antes de prometer essas capacidades adicionais, mas não
  alteram a autorização, o ledger ou a consistência já testados.

## Plano de ativação de estoque legado (não executado)

1. Inventariar posições `valuation_status='pending'` por empresa, filial e produto;
   bloquear a janela para movimentos nesses itens e comunicar impacto aos usuários.
2. Aprovar explicitamente ZIV01, disponibilidade empresarial e grants necessários;
   não usar `catalog_items.current_cost` como atalho.
3. Executar avaliação inicial auditada para cada posição com quantidade não nula,
   registrar evidência de custo e validar quantidade, valor e média antes/depois.
4. Liberar somente posições `valued`; manter pendências bloqueadas e corrigir a
   origem antes de reabrir movimentos. Em caso de anomalia, suspender a janela e
   usar estorno auditável/recuperação aprovada, nunca exclusão.

## Limite conhecido do contrato atual

- `operational_create_inventory_transfer` representa uma transferência por item.
  Os testes exercitam contenção entre documentos e posições compartilhadas, mas
  uma transferência em lote de vários produtos não existe e não foi simulada.
  Caso seja necessária comercialmente, exige contrato idempotente próprio e uma
  decisão antes de ser incluída em fase posterior.

## Situação de integração verificada

- A branch de origem é `codex/purchase-receiving-valuation`, sem commit local da
  Fase 1; suas alterações continuam preservadas neste worktree.
- A referência local `origin/main` e a origem da Fase 1 apontam para
  `68b8e9005e94e2e5907c824d50bc17f5a580dbcb`. A `main` local está desatualizada
  em `dce5227…`; não é destino seguro sem `fetch` e nova verificação.
- O worktree principal está sujo e em `codex/admin-master-v2-integration`; não
  deve ser limpo, rebaseado ou usado para integrar a Fase 1.
- Após o hardening e a auditoria aprovados, a integração deve ocorrer em worktree novo e
  limpo, criado da `origin/main` recém-atualizada, e repetir toda a regressão.
- A integração local ocorreu no worktree dedicado acima; a `main` local e o
  worktree principal sujo permanecem inalterados. A próxima etapa exige revisão
  pré-publicação, não push automático.
