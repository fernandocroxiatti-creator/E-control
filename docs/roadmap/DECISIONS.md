# eControll — Decisões Técnicas e de Negócio

## Decisões permanentes implementadas

- Negação operacional por padrão; sem `service_role` como bypass.
- Estoque negativo bloqueado por padrão.
- Pedido de compra não cria estoque ou financeiro automaticamente.
- Estornos preservam histórico; não se apagam fatos.
- Aprovação, grant e disponibilidade empresarial são independentes e explícitos.

## Fase 1 — decisões aprovadas em 2026-11-16

| ID | Decisão aprovada |
|---|---|
| D01 | Custo médio ponderado móvel por empresa + filial + produto. |
| D02 | Saldo legado sem custo confiável exige avaliação inicial auditada; proibida avaliação automática por `current_cost`. |
| D03 | Recebimento parcial é permitido até a quantidade pendente do item. |
| D04 | Custo efetivo divergente é permitido somente com justificativa e auditoria. |
| D05 | Estorno parcial/total é evento reverso; bloqueia quando consumo, reserva, transferência ou movimento posterior impedirem consistência. |
| D06 | Somente pedidos `submitted` podem ser recebidos; estados incluem `partially_received` e `received`. |
| D07 | `ZGR01` é transação de recebimento, criada pendente, sem aprovação, grant ou disponibilidade automática. |
| D08 | `ZIV01` é necessária para avaliação inicial de saldo legado; também nasce pendente e sem acesso automático. |

## Política técnica de arredondamento

Quantidades usam a precisão já admitida pelo estoque. Valores e custos serão
persistidos com precisão decimal alta; cada cálculo será arredondado somente na
persistência conforme escala definida pela migration. Resíduo de valor permanece na
posição de valuation e é auditável; nunca será eliminado silenciosamente.

## Correções técnicas confirmadas em 2026-11-17

- A rastreabilidade de linhas de recebimento exige a chave candidata
  `(tenant_id,id)` em `purchase_order_items`, para que a FK composta não possa
  cruzar empresas.
- O estorno usa variável PL/pgSQL distinta dos aliases SQL, evitando ambiguidades
  de resolução que poderiam interromper a transação.
- A avaliação inicial persiste explicitamente `event_type='initial_valuation'`;
  nenhum evento é criado de forma incompleta.
- A postagem de contagem física obtém primeiro o mesmo advisory lock de
  empresa+filial+produto usado por recebimento, transferência e O.S.; se o saldo
  divergir do `recorded_quantity`, a sessão permanece aberta e falha com `40001`
  para recontagem. Isso elimina inversão de locks e sobrescrita silenciosa.
- O protocolo global da Fase 1 é: lock de idempotência quando existir; locks
  advisory de posição `(empresa, filial, produto)` em ordem lexical; linhas de
  documento; linhas de saldo. Locks reentrantes do helper são permitidos, mas
  nenhuma RPC pode inverter essa ordem.
- D05 usa política conservadora sem lote: reservas ativas e eventos posteriores
  de saída (`exit`, ajuste negativo, transferência, inventário negativo e consumo
  de O.S.) tornam o estorno não rastreável e o bloqueiam com erro de negócio.
  Entradas posteriores e estornos anteriores não substituem essa verificação;
  estorno parcial repetido só é aceito se nenhum bloqueio D05 existir.
- A interface traduz SQLSTATE `40001` de inventário obsoleto para instrução de
  atualizar e realizar nova contagem; não há retry automático.

## Pendências da revisão final (não são novas decisões aprovadas)

- Revisão final independente do hardening e da cobertura de concorrência antes
  da integração local. Transferência em lote com vários produtos não existe no
  contrato atual (a RPC é item único); não foi simulada nem criada nesta fase.
- Não alterar D01–D07 nem aprovar ZGR01/ZIV01 durante esse hardening.

## Registro de auditoria independente (2026-11-17)

- A auditoria não alterou D01–D08 nem introduziu decisão comercial nova. Ela
  confirmou que a implementação local respeita o protocolo de locks aprovado e
  que D05 permanece conservadora por ausência de rastreabilidade por lote.
- Transferência em lote continua fora do contrato atual e não é liberada por
  inferência desta auditoria.

## Registro da integração local (2026-11-17)

- A integração local em `codex/phase-01-integration` não alterou D01–D08,
  permissões, grants, flags nem o escopo das fases. Os commits `b176a7e`,
  `a397e6c` e `def071c` apenas versionam a implementação já auditada.

## Condições de rollout registradas (2026-11-17)

- Não é uma nova decisão de negócio: D01–D08 continuam vigentes. A publicação
  requer backup recuperável verificado, janela operacional e expansão por piloto.
- Avaliação inicial não pode usar `current_cost` nem ser executada por inferência.
  Cada custo exige fonte, responsável e autorização administrativa explícita.
- ZIV01 precede ZGR01 para saldos legados não zerados. Aprovação global,
  disponibilidade empresarial e grant continuam três controles independentes.
- Não existe rollback automático seguro depois de fatos novos de valuation ou
  recebimento; preservar eventos e usar correção forward-only ou recuperação
  autorizada.

## Proibido sem nova autorização

Aplicar migrations em Production; habilitar ZGR01; conceder grants; avaliar saldos
reais legados; gerar AP/financeiro; publicar, fazer push ou deploy.
