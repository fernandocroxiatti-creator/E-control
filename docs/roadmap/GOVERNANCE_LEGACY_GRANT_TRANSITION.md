# Transição de grants operacionais legados

Atualizado em 2026-11-25. Documento de projeto local; não autoriza migration,
grant, disponibilidade, alteração de Production ou remoção de acessos.

## Achado comprovado

`role_permission_grants` contém grants globais de `company_owner` para BP01,
MM01, SV01, ME21N e ME23N (e também MIGO). A autorização publicada aceita o
grant global **ou** o grant empresarial. Cinco dos grants inicialmente
priorizados alcançam, de forma agregada, duas empresas ativas, dois vínculos
ativos e duas atribuições de papel ativas cada. Portanto, a remoção direta dos
grants globais causaria regressão operacional.

Há também uma lacuna de escopo: `company_role_permission_grants` exige
`branch_id not null`, mas as RPCs de cadastros BP01/MM01/SV01 chamam
`assert_operational_permission` sem filial. O `has_tenant_permission` atual só
consulta o grant empresarial quando recebe uma filial. Assim, os grants scoped
de cadastros não substituem os legados para essas RPCs; os globais ainda são o
motivo efetivo de autorização.

## Política aprovada (D12)

1. Permissões de cadastro compartilhado (partes, produtos e serviços) passam a
   ser de **escopo empresa**. Elas exigem grant por empresa, nunca herdam uma
   filial arbitrária.
2. Permissões que operam saldo, documento ou evento numa filial continuam de
   **escopo filial**: estoque, inventário, transferências, compras,
   recebimentos, O.S. e futuras operações financeiras.
3. Uma operação sem filial só pode ser satisfeita por grant de escopo empresa.
   Uma operação com filial pode usar grant de empresa quando a permissão for de
   escopo empresa; para permissão de escopo filial, exige correspondência exata
   de empresa e filial.
4. Aprovação global de catálogo, disponibilidade empresarial e grant continuam
   controles independentes. Nenhuma etapa concede disponibilidade ou grant
   automaticamente a empresas atuais ou futuras.

Esta política foi aprovada para implementação local. Publicação, aplicação da
migration e qualquer grant remoto continuam sujeitos ao rollout coordenado.

## Implementação incremental local

- Migration: `20261124120000_transition_legacy_operational_grants.sql`.
- SHA-256 local: `a7e0d89de8e24228ea254cc3ef14b63be752f40e263bcbf97294aa153cbc8f24`.

Durante a primeira aplicação controlada, a verificação final detectou grants
piloto existentes de cadastros ainda persistidos por filial. A transação foi
integralmente revertida, sem registrar a migration. A correção normaliza uma
linha dessas somente depois de existir a mesma tupla em escopo empresa; cada
normalização recebe o evento auditável
`master_legacy_scoped_grant.normalized`.

1. Acrescentar à definição de permissão um escopo canônico (`company` ou
   `branch`) e classificar explicitamente cada permissão operacional existente.
2. Evoluir a tabela de grants empresariais para suportar grant de empresa sem
   `branch_id`, preservando integridade tenant/filial para grants de filial e
   unicidade que trate `NULL` como um único escopo de empresa.
3. Reescrever `has_tenant_permission` e o setter Master para validar o escopo
   definido, vínculo ativo, papel aprovado, acesso à filial quando aplicável,
   aprovação global e disponibilidade empresarial. As funções continuam
   `SECURITY DEFINER`, com `search_path` vazio, `row_security=off`, owner
   `postgres` e ACLs fechadas.
4. Materializar grants scoped equivalentes aos grants globais legados antes de
   remover o fallback global. Para escopo empresa, uma linha por empresa que
   tenha atribuição ativa do papel. Para escopo filial, somente filiais ativas
   efetivamente alcançáveis pelas atribuições de papel e acessos de filial.
5. Validar pós-condições: toda autorização legítima prévia tem cobertura
   scoped; nenhuma empresa/filial adicional é coberta; o log administrativo
   registra justificativa e origem da transição.
6. Apenas após essas pós-condições, retirar os grants globais operacionais
   selecionados e alterar o setter global para rejeitar novos
   `transaction.*` operacionais. Grants não operacionais e históricos ficam
   fora do pacote até revisão específica.

## Contenção e recuperação

- A migration deve falhar fechada antes de remover qualquer grant global se não
  puder provar cobertura scoped completa.
- Não há `DELETE` amplo por papel. Cada permissão é migrada em lote auditável e
  reversível antes da remoção do fallback.
- Uma falha posterior é recuperada restaurando somente o grant legado afetado
  por procedimento Master auditado ou por migration forward-only aprovada; não
  há rollback destrutivo de auditoria.
- A janela administrativa deve impedir decisões concorrentes de grants durante
  a materialização, sem interromper operações empresariais já autorizadas.

## Cobertura local executada

- Cadastro permitido apenas à empresa que recebeu grant de empresa: PASS em
  PostgreSQL descartável.
- Outra empresa com `company_owner` negada: PASS.
- Operação de filial permitida somente na filial concedida e negada em outra:
  PASS.
- Migração de legado preserva cobertura, sem duplicidade, e rejeita novo grant
  global operacional: PASS.
- Regressão de ZGR01, ZIV01 bloqueada, idempotência e RLS/FORCE RLS: PASS na
  suíte isolada.
- Ausência de efeitos financeiros e de grants automáticos: PASS.
- Node 160/160, TypeScript, lint e build: PASS.

Pendência: revisão final do diff, commit local e rollout coordenado. Nenhuma
verificação acima constitui evidência de aplicação em Production.
