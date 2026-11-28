# Preflight Production e correção de compatibilidade

O preflight de publicação encontrou que as constraints reais do catálogo e das permissões aceitam `pending_approval`, `approved` e `retired`. Cinco migrations do pacote usavam `pending`; o harness simplificado anterior não reproduzia essas constraints. Nenhuma migration foi aplicada remotamente e a promoção de `main` foi interrompida antes de qualquer mudança de banco.

A correção altera somente os valores iniciais das permissões/transações propostas, mantendo a aprovação manual. Não modifica as constraints de Production. O bootstrap de testes passa a reproduzir as constraints reais; os asserts de catálogo foram ajustados ao valor canônico. Estados `pending` de assinaturas, usuários ou conciliação não foram alterados.

## Validação da correção

- As dez migrations, na ordem do manifesto, foram aplicadas com sucesso exclusivamente a uma restauração isolada do backup atual de Production, em PostgreSQL Supabase 17.11 sem rede.
- No snapshot restaurado: zero bloqueios comerciais inesperados, zero assinaturas/políticas criadas, nenhum grant global criado e contagem de grants empresariais preservada. ZIV01 sem habilitação.
- Onze tabelas novas com RLS forçada e sem acesso direto por anon, authenticated ou service_role.
- Regressão PostgreSQL integral passou com as constraints reais incorporadas, incluindo concorrência.
- 201 testes Node, lint, TypeScript e build passaram.
- A restauração essencial valida estrutura e dados; não afirma equivalência integral dos privilégios internos gerenciados pelo Supabase.

## Estado da publicação

Backup criptografado via Keychain, checksum e restauração essencial isolada concluídos com sucesso. A branch `codex/local-erp-completion` foi publicada até `e8a26f40ac60ef0b65ef44821a749bf034b85cf6`, com deploy de `codex/**` desabilitado no repositório. `main`/Production permanecem na base `6718657967afa5e6a614c396a4e7df42170ec894`.

O manifesto revisado mantém os mesmos dez nomes; cinco hashes mudaram. Sua aplicação remota e a publicação desta correção aguardam autorização complementar específica. Aprovações de catálogo e grants piloto devem ser autorizados separadamente, em solicitação agrupada. Não houve concessões reais, liberação ZIV01 ou GO comercial.
