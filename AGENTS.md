# Regras de desenvolvimento e publicação do eControl

Estas instruções aplicam-se às próximas tarefas do Codex neste repositório. A autorização para uma etapa cobre somente o escopo explicitamente aprovado; não autoriza automaticamente tarefas seguintes.

## Fluxo de cada etapa autorizada

1. Inspecionar o estado do repositório e implementar somente o escopo aprovado.
2. Executar lint, verificação TypeScript, build e os testes aplicáveis. Relatar resultados reais e identificar o que não foi executado.
3. Revisar o diff e interromper se houver alterações inesperadas, falhas de verificação ou conflitos.
4. Auditar os arquivos que seriam publicados em busca de segredos, credenciais e conteúdo privado antes de criar o commit.
5. Criar um commit com mensagem que identifique a etapa autorizada e publicar na branch configurada do repositório GitHub autorizado, sem force push.
6. Acompanhar o deploy automático da Vercel, verificar seu resultado e conferir as rotas e funções alteradas. Se o deploy não puder ser verificado, declarar isso claramente.
7. Encerrar com um relatório do escopo, commit, validações, deploy, verificações funcionais e pendências.

## Repositórios e publicação

- O código oficial é publicado em `https://github.com/fernandocroxiatti-creator/E-control.git`; a Vercel associada é `https://e-control-delta.vercel.app`.
- Usar somente esse repositório e a branch configurada. Não alterar configurações globais do Git.
- Preservar a conta GitHub Erlanyapp usada por outros projetos.
- Nunca publicar senhas, tokens, chaves secretas, `.env.local` ou outros arquivos de ambiente locais, `work/`, documentos privados ou evidências confidenciais.
- Nunca usar force push nem sobrescrever alterações remotas. Interromper diante de conflito ou divergência inesperada.
- Se uma alteração tocar autenticação, RLS, banco de dados, credenciais ou permissões administrativas, não fazer push dessa alteração sem aprovação específica do proprietário para publicá-la.
- Não publicar funcionalidades administrativas ou empresariais que não tenham sido autorizadas.
- Publicar no ambiente de desenvolvimento somente etapas aprovadas e validadas; build ou deploy bem-sucedido não equivale a aprovação de segurança.

## Supabase e limites de segurança

- Não aplicar migrações automaticamente; exigir autorização específica para cada aplicação remota.
- Não executar operações destrutivas no Supabase nem alterar dados/configurações fora do escopo autorizado.
- Não expor chaves privilegiadas no frontend nem registrar valores de variáveis secretas em relatórios.
- Não liberar operações empresariais reais antes da aprovação de G1.
- Uma falha de teste, segredo encontrado, arquivo privado no conjunto de publicação ou alteração inesperada bloqueia o commit/push até ser resolvida e autorizada.

## Verificação de integração

Quando a etapa exigir publicação, conferir sem revelar valores secretos: conexão GitHub–Vercel, branch de deploy, deploy automático, presença das variáveis necessárias e compatibilidade das URLs de autenticação Supabase com o domínio da Vercel. Confirmar também que nenhuma chave privilegiada está incluída no bundle do navegador. Não alterar configurações externas sem autorização específica.
