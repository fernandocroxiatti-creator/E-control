# eControll — Estado Atual Verificado

Atualizado em 2026-11-17.

## Atualização factual — 2026-11-24

- `origin/main` e Production estão no commit `71d13a1e0398e3bc85cde50de3c3d14d1d2fac4d`.
- A tela Master de acessos por empresa foi corrigida para distinguir empresa não
  selecionada de indisponibilidade real; a correção não alterou autorização.
- A migration `20261124110000_company_scoped_pilot_operational_entitlements.sql`
  está aplicada. O piloto recebeu somente os grants scoped mínimos aprovados;
  ZIV01 continua bloqueada. A autorização efetiva dos cadastros ainda depende
  de grants globais legados porque as RPCs de cadastro não recebem filial.

Esta atualização factual prevalece sobre registros históricos locais de
planejamento que descrevem migrations anteriores como pendentes. Eles registram
o estado no momento em que foram escritos, não o estado publicado atual.

## Transição de grants globais legados — implementação local 2026-11-25

- D12 aprovou grants de empresa para cadastros compartilhados e grants de filial
  para operações com contexto operacional.
- A migration local `20261124120000_transition_legacy_operational_grants.sql`
  materializa somente a cobertura já efetiva, registra auditoria e falha antes
  de remover um fallback global se a equivalência não puder ser provada.
- As duas primeiras tentativas remotas falharam fechadas e foram revertidas
  integralmente pelo `BEGIN`/`COMMIT`: grants piloto preexistentes de cadastros
  ainda estavam no formato filial, inclusive três sem fallback global legado.
  A correção local implementa D12 explicitamente: materializa a tupla de
  empresa somente para uma grant scoped já existente, registra auditoria e
  elimina a tupla filial antecedente. Ela não cria cobertura para empresa sem
  grant prévio.
- SHA-256 local verificado após a correção final:
  `6dfb45d15278694af727bafc06ffd5a97ea9ecc9cc316aa119222938144b8a59`.
- Evidências locais: PostgreSQL descartável PASS; Node 160/160 PASS;
  TypeScript, lint e build PASS. A migration **não** foi publicada, aplicada ou
  testada com dados de Production nesta etapa.

- Worktree de origem preservado: `/private/tmp/econtroll-phase-01-receiving`.
- Worktree de integração: `/private/tmp/econtroll-phase-01-integration`.
- Branch de integração: `codex/phase-01-integration`, criada de `origin/main`
  após fetch em `68b8e9005e94e2e5907c824d50bc17f5a580dbcb`.
- Commits locais de integração preservados: `b176a7e` (lógica e migration),
  `a397e6c` (interface), `def071c` (testes), `a9e3ec5` (histórico) e
  `0073dd0` (rollout). O hardening de idempotência atual ainda não possui commit.
- Production possui as migrations de Fase 1 e a extensão de grants de piloto
  registradas até `20261124110000`; esta preparação não aplicará migration,
  dados, flags ou permissões remotas.

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
  `f7a8e4648e82cbffadcbb6d23d192912d02ba93aa4ef449dffe62502ccdbcda3`.
- `ZGR01` e `ZIV01` permanecem em aprovação pendente; a migration não cria grants
  de papel nem disponibilidade empresarial.
- A interface usa RPCs novas apenas quando a transação é autorizada; a ausência da
  migration é apresentada como indisponibilidade, sem salvar dados simulados.
- Compras agora prevê envio explícito do pedido, recebimento parcial/total e
  solicitação de estorno com confirmação. Estoque prevê consulta de valuation e
  avaliação inicial; ambos continuam protegidos até aprovação de ZGR01/ZIV01.
- PostgreSQL 17.11 isolado passou nos cenários já cobertos, em container
  descartável e sem rede, inclusive concorrências cruzadas. Porém a auditoria
  independente encontrou um replay idêntico de entrada com custo derivado que
  falha indevidamente com `23505`; a Fase 1 permanece bloqueada localmente até
  a correção e nova regressão. Nenhum comando remoto foi emitido e Production
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
possui plano de rollout local revisado. Não está publicada ou aplicada em
Production.

## Hardening final de idempotência — corrigido localmente, aguarda auditoria

- O retorno idempotente agora exige payload normalizado igual. Movimento avaliado
  compara filial, produto, tipo, quantidade, custo de entrada, referência,
  documento de origem e responsável. Transferência compara origem, destino,
  produto, quantidade, referência e responsável. ZIV01 compara filial, produto,
  custo, justificativa, tipo e responsável; a quantidade é snapshot imutável do
  servidor e não entrada do cliente.
- Referência é `btrim` com vazio convertido para `NULL`; justificativa é somente
  `btrim`. Quantidade com mais de quatro ou custo com mais de oito casas decimais
  é rejeitado, para que precisão descartada nunca pareça um replay igual.
- Locks advisory por `(empresa, request_id)` precedem locks de posição. Assim,
  payload divergente concorrente chega à comparação explícita e falha em `23505`,
  em vez de competir silenciosamente pela restrição única.
- A cobertura de replay inclui custo, referência, filial, produto, quantidade
  e justificativa divergentes. A barreira foi corrigida para rótulos de no
  máximo 63 bytes e duas execuções completas terminaram com exit code `0`, sem
  timeout, deadlock ou duplicidade aceitos.
- A rota pública sem custo informado persiste `unit_cost_input_mode='derived'`;
  a rota valorada persiste `explicit`. A comparação exige o mesmo modo, compara
  custo apenas quando ele foi informado e não reaplica valuation no replay.
- Referência `NULL`, vazia e somente espaços equivalem a `NULL`; referência com
  conteúdo usa `btrim` e divergência semântica falha com `23505`. `request_id`
  é namespace por operação e empresa, testado sem mistura de fatos.

## Evidência da auditoria independente anterior

- SHA-256 recalculado diretamente: `f8838d357e68556db1c0fa36ec333b5f0ccde7de449c1b968ca0ea3fb67318d2`.
- Registros anteriores reportaram duas execuções da suíte PostgreSQL 17.11
  descartável. A auditoria atual não as reutiliza como evidência conclusiva:
  a execução independente interrompeu-se na barreira de replay derivado por
  truncamento de `application_name`, antes de concluir todos os cenários.
- `node --test tests/*.test.mjs` (148/148), lint, TypeScript, build,
  `git diff --check` e varredura de segredos passaram. Os avisos ESM do Node são
  pré-existentes, sem falha de teste.
- A revisão anterior não encontrou acesso direto às tabelas novas, `EXECUTE` para anon ou
  service_role, concessão automática de ZGR01/ZIV01, nem efeito financeiro.
- Riscos residuais não bloqueantes da integração local: transferência em lote
  continua fora do contrato; a tipagem de leitura de histórico ainda não nomeia
  os tipos novos de recebimento/estorno para apresentação especializada. Ambos
  devem ser tratados antes de prometer essas capacidades adicionais, mas não
  alteram a autorização, o ledger ou a consistência já testados.

## Auditoria final de custo derivado — barreira corrigida localmente

- O truncamento de `application_name` foi eliminado com identificadores curtos,
  únicos e validados em bytes. A ausência de sessão é verificada sem falso PASS
  e toda sessão de contenção observada usa o mesmo identificador configurado no
  cliente `psql`.
- Duas execuções normais da suíte PostgreSQL 17.11 descartável passaram com
  exit code `0`. Cada uma exerceu 30 disputas reais, inclusive replays
  derivados e as duas ordens de movimento × transferência com o mesmo
  `request_id` em namespaces distintos. Nenhuma mudança foi feita em
  Production; a aprovação ainda depende de nova auditoria independente.

## Auditoria final pré-commit aprovada (2026-11-17)

- Auditoria independente repetiu a suíte PostgreSQL 17.11 descartável com exit
  code `0`: 30 cenários concorrentes reais, inclusive replay explícito e
  derivado, conflitos `23505`, D05, inventário, O.S. e namespaces distintos de
  `request_id`.
- `node --test tests/*.test.mjs` passou 148/148; lint, TypeScript, build,
  `bash -n`, `git diff --check` e a varredura de segredos também passaram.
- A revisão não encontrou concessão automática, efeito financeiro, ACL ampla,
  acesso por `anon`/`service_role`, quebra de RLS/FORCE RLS nem alteração
  remota. A Fase 2 não foi iniciada.
- Estado: **GO somente para o sexto commit local**. Push, deploy, migration e
  qualquer ativação em Production continuam fora do escopo.

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

## Plano pré-publicação e rollout (não executado)

1. Revalidar `origin/main`, histórico e os quatro commits antes de qualquer push;
   publicar código apenas por autorização separada. O código falha fechado quando
   a migration ainda não existe, portanto pode precedê-la sem simular gravações.
2. Antes da migration, criar backup lógico criptografado, conferir checksum,
   catálogo e restauração essencial em PostgreSQL descartável. Registrar horário,
   versão e hash sem registrar credenciais.
3. Durante janela operacional, aplicar somente a migration da Fase 1 e conferir
   histórico, objetos, RLS/FORCE RLS, ACLs, `SECURITY DEFINER`, `search_path`,
   ausência de grants/availabilities automáticos e inexistência de efeitos
   financeiros. `ALTER TABLE` de constraints e índices pode bloquear escritores;
   a janela precisa impedir movimentos concorrentes.
4. Em leitura, inventariar por empresa, filial e produto as posições
   `valuation_status='pending' and quantity <> 0`. Não estimar a quantidade de
   Production antes dessa consulta autorizada. Definir fonte documental do custo,
   responsável e evidência para cada avaliação inicial.
5. Após autorização administrativa específica, aprovar ZIV01 globalmente,
   disponibilizá-la somente para a empresa/filial piloto e conceder somente o
   grant de valuation ao papel piloto. Registrar cada avaliação e validar que
   todas as posições não zeradas necessárias ficaram `valued` com valor e média
   não negativos. Não usar `catalog_items.current_cost` como substituto.
6. Somente depois do inventário aprovado, autorizar separadamente ZGR01, módulo
   PUR, disponibilidade empresarial e grant de recebimento para o mesmo piloto.
   Validar recebimento/estorno com dados operacionais previamente autorizados.
7. Expandir por empresa e filial apenas após aceite documentado. Nenhuma etapa
   cria contas a pagar, financeiro, caixa ou concessão global.

## Recuperação e interrupção (não executadas)

- Falha antes do `commit` da migration: interromper e preservar o banco anterior;
  diagnosticar sem reaplicar parcialmente.
- Falha após `commit` e antes de ativações: manter ZGR01/ZIV01 sem grants e
  disponibilidade; o código permanece fail-closed. Não tentar remover colunas ou
  objetos automaticamente.
- Avaliação inicial errada ou incompleta: interromper a expansão. A RPC aceita
  apenas posição `pending`, portanto correção de uma avaliação já gravada exige
  procedimento auditado e autorização nova; não sobrescrever custo.
- Inconsistência: suspender movimentos do piloto, conservar auditoria/eventos,
  comparar saldo, valor, média e movimentos; decidir entre correção forward-only
  aprovada e recuperação pelo backup. Restaurar backup após novas operações perde
  fatos posteriores e não é rollback automático.
- Indisponibilidade de interface: reverter somente o deploy de código se o banco
  permanecer compatível; isso não reverte semântica ou dados da migration.

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

## Atualização local — governança de ZGR01 (2026-11-19)

- Contexto informado e preservado: empresa/filial piloto ativas; ZGR01 e ZIV01
  pendentes, sem disponibilidade nem grant de recebimento. Esta execução não
  consultou nem modificou dados empresariais remotos.
- A nova migration é local e não aprova ZGR01, não aprova ZIV01, não cria
  disponibilidade nem cria grants. Ela somente cria o mecanismo auditável de
  grant por empresa e filial.
- Próximo marco: revisão independente e autorização explícita para versionar e
  publicar o código e a migration; aplicação remota exige autorização distinta.

## Compatibilidade de rollout da governança (2026-11-19)

- Os únicos consumidores de produção das três RPCs administrativas são as
  Server Actions em `app/actions/master-access-governance.ts`. A fixture antiga
  usa assinaturas de três argumentos apenas antes da migration no PostgreSQL
  descartável; nenhuma rota operacional, recepção, estoque ou O.S. depende delas.
- Não há expand/contract seguro para manter as assinaturas antigas mutáveis:
  elas não recebem justificativa e preservá-las permitiria mudança administrativa
  sem auditoria obrigatória. As assinaturas antigas são removidas; a suite prova
  que ficam indisponíveis após a migration.
- O rollout requer janela administrativa coordenada: deploy da interface e
  migration devem ocorrer sem operar a tela Master de governança entre as duas
  etapas. Operações empresariais e ZGR01/ZIV01 permanecem bloqueadas durante a
  janela. Não há fallback com `service_role`, justificativa implícita ou grant
  global.
- Ordem recomendada: publicar código validado primeiro e confirmar READY;
  enquanto a migration estiver ausente, as mutações Master falham fechadas.
  Só então aplicar a migration autorizada, executar verificações de segurança e
  liberar a tela administrativa. Se o deploy falhar, a migration não é aplicada;
  se a migration já tiver sido confirmada, a contenção é corrigir/publicar uma
  versão compatível — não restaurar funções antigas sem justificativa.

## Fase 2 — estado local atual (2026-11-23)

- Branch/worktree isolado: `codex/phase2-direct-purchase-work-order`.
- Migration local pendente de revisão e de autorização remota:
  `20261123190000_direct_purchase_work_order.sql`, SHA-256
  `677b981c2ed2615572e1c43ce4e2e76452fce39c7e3ff7398c75a0cfcf8f4af6`.
- A interface e as Server Actions falham fechadas enquanto os read/write RPCs
  não existirem. A autorização operacional continua dependente de ZOS02/ZOS03,
  vínculo, papel, filial e disponibilidade já existentes; esta fase não cria
  catálogo, grant ou disponibilidade novos.
- A operação segura nesta entrega é somente registrar custo direto em O.S.
  aberta/em andamento. A migration incremental local
  `20261123200000_direct_purchase_work_order_reversal.sql` registra o contrato
  de estorno imutável, mas o deixa bloqueado com `55000`: não existe fonte
  confiável de faturamento da O.S. para provar a pré-condição D11. Não há
  reflexo em estoque, compra formal ou financeiro. SHA-256 local:
  `15a5ecab36c35751f0cfa28cdcb95db5c2209ad0c2f78e164ee8a8c47b5c8266`.
- Próximo marco: revisão local do diff e, somente após a Fase 5 oferecer o
  contrato de faturamento, decisão específica para substituir o bloqueio por
  verificação confiável e testar o caminho de sucesso.
- A regressão PostgreSQL completa da Fase 1/Fase 2 foi encerrada localmente em
  2026-11-23: PostgreSQL 17.11 descartável, exit `0`, 108 segundos e 36
  barreiras reais observadas. O log local não contém deadlock, timeout ou falha
  inesperada; containers temporários foram limpos. Isto não habilita o estorno
  D11 nem autoriza publicação ou alterações remotas.
