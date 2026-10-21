# Base de dados local — DEV-02

Esta pasta contém uma migração SQL local para Supabase PostgreSQL. Nenhum projeto remoto foi conectado e a migração não foi executada nesta tarefa.

Base de negócio consultada: EC-13 v1.6; P00-T03 (modelo, matriz de permissões, superfícies e validação futura); EC-04 (isolamento/autorização); decisões D20–D21 e regras C23–C25. TV-020/TV-021 e HML-01 seguem como validações planejadas, não executadas.

## Modelo inicial

- `companies`: empresa/tenant, cuja chave `id` é o identificador empresarial.
- `branches`: filial com `tenant_id`; unicidade do código e chaves compostas limitam referências ao mesmo tenant.
- `user_profiles`: perfil global ligado a `auth.users`; não contém permissões empresariais.
- `company_memberships`: vínculo autorizado entre identidade e empresa. A associação começa `pending`; somente vínculo `active` permite leitura empresarial.
- `branch_access`: concessão explícita de acesso a uma filial vinculada ao mesmo tenant e membership. O modo padrão é `assigned_only`; `all_branches` é apenas uma capacidade administrativa do modelo, sem caminho de autoatribuição e sujeita à definição de escopo de filial.
- `access_role_definitions`, `permission_definitions`, `role_permission_grants` e `membership_role_assignments`: estrutura inicial de RBAC. Os nomes de papel e permissões registrados são rascunhos; começam pendentes, não há grants semeados e não podem ser atribuídos por usuários autenticados.

As permissões pontuais de fechamento, reabertura e lançamento em período reaberto aparecem separadas conforme C23–C25. O catálogo de permissões operacionais não está completo. O helper `app_private.has_tenant_permission` só retorna verdadeiro quando o papel, a permissão, a concessão e o vínculo foram aprovados e registrados; nenhuma política atual concede essas ações.

## Controles de acesso na migração

RLS é habilitada e forçada nas tabelas. Políticas de leitura permitem que a identidade autenticada veja somente o próprio perfil, os próprios vínculos, empresas com vínculo ativo e filiais expressamente acessíveis. Para dados não cobertos por uma política, o resultado é negar acesso. Não há políticas de inserção, exclusão, alteração de vínculos, filiais, papéis ou permissões; o usuário não pode conceder a si próprio privilégios. A única atualização direta permitida é `user_profiles.display_name` do próprio usuário.

A migração não cria papel operacional para Master ou suporte. O Master não recebe associação a tenant. O procedimento temporário de suporte aprovado como política de negócio ainda requer desenho e implementação próprios; até lá não se deve criar vínculos comuns de empresa para identidades de suporte.

RLS não está comprovada por esta modelagem. É necessário testar com identidades e tenants distintos, tentativas de leitura/escrita cruzadas, filial autorizada/não autorizada, concessões/revogação e funções privilegiadas antes de G1.

## Aplicação futura

Pré-requisitos: Supabase CLI configurado para ambiente local e runtime PostgreSQL/Auth local disponível. Fluxo futuro recomendado: configurar o ambiente local autorizado, revisar a migração, executar `supabase start`, aplicar as migrações locais com `supabase db reset`, executar os testes SQL/RLS e revisar o resultado. Vincular a projeto remoto e executar `supabase db push` exigirão revisão e autorização separadas. Nenhum comando de aplicação remota foi executado. Esta tarefa não cria `config.toml`, projeto Supabase, credenciais ou configuração de deploy.

As migrações devem permanecer versionadas, ordenadas por timestamp e imutáveis depois de aplicadas a um ambiente compartilhado; correções futuras devem entrar como nova migração revisada.

## Referências técnicas

- [Supabase — Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security): grants mínimos, funções `security definer` em schema não exposto e `search_path` fixo.
- [Supabase — Securing your data](https://supabase.com/docs/guides/database/secure-data): RLS e restrição de chaves secret/service-role a componentes de servidor.
