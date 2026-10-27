# EC-AUTH-01 — Contrato local de autorização empresarial

Este documento descreve a migração candidata `20261022130000_company_authorization_foundation.sql`.
Ela foi criada localmente e **não foi executada** em PostgreSQL nem no Supabase hospedado.

## Identidade e autoridade

- RPCs de aplicação exigem `auth.role() = 'authenticated'` e derivam o ator somente de `auth.uid()`.
- `p_tenant_id` identifica o recurso solicitado; não prova autoridade. O banco revalida uma membership ativa e a cadeia persistente de papel e permissão para o mesmo usuário e tenant.
- A migração adiciona somente `branch.manage` em `pending_approval`. Não aprova a definição, cria papel, atribui permissão nem cria membership. Até uma futura aprovação e atribuição autorizada, os caminhos de gerente empresarial negam leitura administrativa e escrita.
- Admin Master não é convertido em administrador empresarial e não recebe acesso operacional por esta migração.

## Contratos disponíveis após aplicação e validação

- **Visualizar empresa:** usuário com membership ativa continua coberto pela política existente; futuramente, um administrador empresarial com a cadeia `branch.manage` aprovada poderá ver somente metadados do tenant autorizado.
- **Listar filiais:** usuário continua sujeito ao escopo de `app_private.can_access_branch`; um gerente com permissão aprovada poderá listar metadados apenas do tenant correspondente.
- **Criar filial:** `public.create_branch(tenant_id, request_id, code, name)` exige sessão autenticada, membership ativa e cadeia de autorização aprovada do `auth.uid()` no tenant indicado. Membership, empresa, papel, atribuição, concessão e definição são bloqueados contra alterações concorrentes até o fim da transação.
- **Idempotência e auditoria:** o par ator/tenant/chave de solicitação é único; repetição com mesmos dados retorna o mesmo ID, e reutilização com conteúdo diferente falha. Criação, registro idempotente e evento `branch.provisioned` pertencem à mesma transação.
- **Auditoria de autorização:** triggers `FOR EACH ROW`, `ENABLE ALWAYS`, registram mudanças em memberships, acessos a filiais, atribuições e catálogo de papéis/permissões. A identidade do ator vem de `auth.uid()` quando há sessão; sessões SQL são registradas como operador de banco, sem impersonação.
- **Administrar usuários e papéis:** não disponibilizado. As rotinas antigas baseadas em `p_actor_user_id` deixam de ser executáveis por `service_role`; novos contratos aguardam definição e validação do fluxo EC-ADM-02.

## Limites e verificação necessária

As políticas e funções usam `SECURITY DEFINER`, `search_path` vazio e `row_security=off`, com owner `postgres`; a migração valida essas condições e restringe `EXECUTE` a `authenticated` nos pontos necessários. O schema `app_private` não deve ser adicionado aos schemas expostos da Data API.

Testes estáticos locais não demonstram validade de JWT, comportamento do PostgREST, efetividade de RLS, bloqueio de revogação concorrente ou atomicidade no PostgreSQL. Esses pontos exigem aplicação e testes em um Supabase isolado, com identidades sintéticas. Até lá, o formulário da aplicação deve continuar sem escrita habilitada e G1 permanece NO-GO.

A permissão `branch.manage` deve continuar pendente até existir uma validação transacional dos limites contratados de filiais; esta migração não modela nem verifica quotas. A aprovação do papel ou da permissão não deve anteceder essa implementação.

## Preparação do primeiro administrador — EC-AUTH-02

A tela `/master/administradores` apresenta apenas o fluxo aprovado em EC-ADM-02. Empresa, e-mail e envio permanecem desabilitados: a interface não consulta empresas, Supabase Auth ou envia mensagens. Ainda não há contrato implementado para armazenar e consumir convites, vincular uma identidade Auth existente ou criar o vínculo empresarial após o aceite.

Uma implementação futura deverá validar no servidor a sessão Master que solicita o convite e derivar sua identidade de `auth.uid()`; a empresa escolhida será somente um recurso solicitado, nunca autoridade. O aceite deverá provar posse de um convite individual, de uso único e não expirado, e vincular o UUID Auth verificado sem duplicar identidade nem alterar credenciais. A transação que converte o convite em membership e atribui o papel inicial ainda requer contrato próprio, incluindo estado do vínculo, catálogo de papel/permissões aprovado, concorrência, cancelamento/reenvio e auditoria. Nenhuma dessas operações é executável nesta etapa.
