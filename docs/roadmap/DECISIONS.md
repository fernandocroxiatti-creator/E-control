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

## Hardening de idempotência (2026-11-17)

- Não é decisão comercial nova e não altera D01–D08. O contrato técnico de
  `request_id` foi explicitado: payload normalizado igual é replay; divergência
  é `23505`, nunca retorno silencioso de um fato diferente.
- Normalização aprovada para esta implementação: `btrim` em referência e razão;
  referência vazia equivale a `NULL`. Quantidade aceita no ledger tem no máximo
  quatro casas decimais e custo informado no máximo oito; excesso de precisão é
  inválido, não arredondado para comparação.
- O custo médio, `unit_cost`, `total_value`, snapshot de valuation e auditoria
  persistidos continuam imutáveis. O snapshot de quantidade de ZIV01 é produzido
  pelo saldo bloqueado pelo servidor, não um campo reutilizável do cliente.
- Os cinco commits anteriores permanecem: `b176a7e`, `a397e6c`, `def071c`,
  `a9e3ec5`, `0073dd0`. O hardening atual é alteração local não versionada e
  requer nova auditoria antes de qualquer push.

## Achado da auditoria independente de idempotência (2026-11-17)

- D01–D08 permanecem inalteradas. A implementação atual não pode ser aprovada:
  quando uma entrada pública não envia custo e o banco deriva a média móvel,
  o replay igual deve comparar a ausência de custo informado como ausência de
  campo de payload, não como divergência em relação ao custo calculado e
  persistido. Hoje ela falha com `23505`.
- A próxima correção deve preservar a comparação obrigatória de custo para
  endpoints que o recebem do cliente e acrescentar testes para custo derivado,
  `NULL`/vazio/espaços em referência e escopo de `request_id` entre operações.
  Isso é correção de contrato técnico, não uma nova decisão de negócio.

## Correção técnica de custo derivado (2026-11-17)

- Não altera D01–D08. `unit_cost_input_mode` registra a intenção recebida:
  `explicit` para custo fornecido e `derived` para custo omitido. O modo integra
  o payload canônico de idempotência; portanto uma chamada derivada e outra
  explícita nunca são consideradas equivalentes apenas porque chegam ao mesmo
  valor numérico.
- No modo derivado, o custo aplicado continua sendo snapshot imutável e auditável
  da média móvel bloqueada, mas não é campo comparado ao `NULL` do replay. No
  modo explícito, custo com mais de oito casas é rejeitado e o valor original é
  comparado integralmente.
- `request_id` é único por `(tenant, operação)` — não globalmente entre tabelas.
  A implementação e os testes tratam reuso entre movimento e transferência como
  comandos independentes, sem compartilhamento de resultado ou mutação cruzada.

## Registro factual da auditoria final de custo derivado (2026-11-17)

- Não é decisão comercial nova e não altera D01–D08. A auditoria identificou
  que o runner de concorrência precisa limitar deterministicamente o
  `application_name` usado como barreira a 63 bytes ou menos. Até nova execução
  com código de saída zero, a cobertura concorrente adicionada para custo
  derivado permanece pendente de confirmação independente.

## Correção factual da barreira de concorrência (2026-11-17)

- Não altera D01–D08. O runner usa agora um `application_name` ASCII curto,
  determinístico e único por execução, validado em bytes contra o limite de 63
  do PostgreSQL. A barreira exige exatamente uma sessão em `PgSleep`; uma
  sessão inexistente é rejeitada explicitamente.
- Dois cenários reais usam o mesmo `request_id` em movimento e transferência,
  nas duas ordens de contenção. O contrato continua sendo namespace por
  empresa+operação, sem reaproveitamento de fato entre tabelas.

## Auditoria final pré-commit aprovada (2026-11-17)

- A auditoria independente confirmou, sem alterar D01–D08, que o modo
  `explicit`/`derived`, o namespace `(empresa, tipo de operação)`, a
  normalização de payload e a barreira PostgreSQL corrigida preservam o contrato
  de idempotência.
- Foram aprovados 30 cenários concorrentes reais em PostgreSQL isolado, além de
  Node 148/148, lint, TypeScript, build, `bash -n`, diff e auditoria de
  segredos. Production permanece inalterada e a Fase 2 não foi iniciada.

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

## D09 — Grant operacional empresarial e justificativa obrigatória (2026-11-19)

- Aprovar ZGR01 e sua permissão continua sendo decisão global de catálogo; não
  concede uso a uma empresa. A disponibilidade continua empresarial.
- O grant operacional adicional da Fase 1 é limitado à tupla `(empresa, filial,
  company_owner, transaction.purchasing.receipt.manage)` e só é avaliado em
  chamadas com filial explícita. Ele não pode substituir vínculo ativo, acesso
  de filial, papel/permissão aprovados ou disponibilidade empresarial.
- A alteração proposta exige justificativa textual de 10–1000 caracteres para
  aprovação, grant e disponibilidade, persistida na auditoria. É decisão de
  implementação local; não autoriza aplicação remota nem liberação do piloto.

## Proposta de implementação pendente — 2026-11-24

- Sem criar nova decisão comercial, a extensão local proposta preserva D09 e
  permite, somente por empresa+filial e para `company_owner`, os grants mínimos
  de BP01, MM01–MM03, SV01, ME21N, ME23N e ZGR01. Cada grant continua exigindo
  aprovação global, disponibilidade empresarial, vínculo ativo, filial ativa e
  justificativa auditável.
- ZIV01, inventário, transferência, O.S., financeiro e papéis diferentes de
  `company_owner` permanecem fora da lista permitida. A proposta não autoriza
  publicação ou aplicação em Production.
