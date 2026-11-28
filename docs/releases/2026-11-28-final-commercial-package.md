# Pacote comercial local — 28/11/2026

**Atualização de publicação:** consulte o [preflight Production e a correção de compatibilidade](2026-11-28-production-preflight.md). A branch de preparação foi publicada; migrations e promoção de main aguardam autorização dos hashes corrigidos.

Branch de integração: `codex/local-erp-completion`. Base local: `ab32549`. Produção de referência: `6718657967afa5e6a614c396a4e7df42170ec894`.

Commit de implementação validada: `76ad8d90fb9a5979388759c4ecc7bb93c5d85efb`.

## Entrega implementada

- SaaS: política explícita de vencimento e tolerância (0–90 dias), bloqueio operacional no banco, reativação manual Master, limites de usuários ativos/pendentes e filiais ativas validados continuamente, inclusive alterações de plano/assinatura. Consulta de situação e utilização pela empresa permanece acessível. Assinaturas não concedem permissões.
- Faturamento/financeiro: integração explícita com geração de parcelas ou vínculo a obrigação existente, chave idempotente, vínculo auditável, prevenção de duplicidade e cancelamento atômico protegido por baixas e movimentos dependentes. Nenhum recebível histórico é gerado ou reclassificado automaticamente.
- Relatórios: compras, vendas, movimentações de estoque, financeiro, bancos e ordens de serviço com dados persistidos, filtros, paginação e transação própria. CSV, XLSX, PDF e impressão; DRE e fluxo também exportam XLSX/PDF. Exportação acima de 5.000 registros pede refinamento, sem truncamento silencioso. Valores extensos ficam como texto no Excel para preservar precisão.
- Tesouraria: OFX SGML/XML em BRL, até 2 MB/2.000 movimentos, identificação explícita de conta, hash e FITID para deduplicação, sugestões por valor/data/referência e confirmação manual. Reimportação divergente é rejeitada. Desfazer conciliação limpa o vínculo ao extrato. Sem conexão bancária externa.
- Navegação: assinatura e central de relatórios, aviso comercial no painel, formulários responsivos e controles uniformizados. Entradas Master sem operação real foram retiradas do menu; configurações redireciona a planos. Suporte/solicitações sem implementação retornam 404, sem formulário fictício.
- Código anterior de contas, transferências, conciliação manual, fluxo, DRE, onboarding e governança preservado. Os worktrees originais não foram descartados; a integração permanece no worktree durável `work/local-erp-completion`.

## Catálogo e isolamento

ZTR02–ZTR05 e ZGE01–ZGE02 continuam registrados pelas migrations da base local, inicialmente pendentes. ZFB04, ZTR06 e ZRP01–ZRP06 são adicionais e também nascem pendentes. ZCX01–ZCX04 já existem no código publicado e suas RPCs/mapeamentos foram preservados. No banco local de teste, ZCX01–ZCX04 foram confirmadas como `pending_approval`, sem empresas habilitadas. As aprovações sintéticas de outras transações usadas pelo harness não representam o ambiente remoto. O estado real das aprovações e disponibilidades em produção não foi inferido a partir das fixtures locais; deve ser confirmado com o preflight somente leitura incluído.

ZIV01 não foi liberada. Nenhuma nova transação é disponibilizada automaticamente a empresas. Cada concessão Master continua exigindo autorização própria; publicação, assinatura e reativação comercial não equivalem a concessão. RLS forçada, ACLs e validações de tenant/filial são exercitadas no PostgreSQL local. Não há cobrança real.

## Evidência local

- Node: 201 testes aprovados, incluindo os 193 anteriores.
- Lint, TypeScript e build Next.js aprovados.
- Regressão PostgreSQL integral: harness local PostgreSQL 17.11, contêiner descartável sem rede. Inclui regressões de onboarding, permissões, compras, vendas, estoque, faturamento, caixa, gestão e tesouraria; novos casos de SaaS, integração financeira, OFX e seis relatórios.
- Concorrência: transferências bancárias opostas e duas criações simultâneas de filial/usuário com observação real de espera de lock; capacidade contratada preservada.
- XLSX reaberto e inspecionado: datas, filtros, cabeçalho congelado, strings sem fórmulas executáveis, números e decimais extensos. PDF renderizado e inspecionado: acentuação, cabeçalhos, rodapés, paginação e textos longos. Preview independente de XLSX pode exibir números textuais extensos em notação científica; o arquivo reaberto com ExcelJS conserva o texto integral.
- Interface nova com dados sintéticos: 390, 768 e 1440 pixels, sem overflow horizontal da página e sem erros JavaScript. Rota temporária de QA removida antes do build. Essa verificação cobre os novos formulários e o shell compartilhado; não substitui revisão autenticada de todas as telas com dados da empresa piloto.
- Auditoria npm de dependências de produção: zero vulnerabilidades reportadas após override compatível de uuid usado pelo ExcelJS. Não equivale a auditoria independente do produto.

## Publicação pendente e ordem operacional

Manifestos: [nomes e hashes completos](2026-11-28-migrations.md) e [JSON verificável](2026-11-28-migrations.json). Preflight: [consulta somente leitura](2026-11-28-preflight.sql).

1. Confirmar explicitamente o ambiente Supabase de destino, o conjunto exato de dez migrations e a publicação dos commits no repositório oficial/branch configurada. Aprovação de código não autoriza aplicação de banco nem concessões Master.
2. Antes de escrever remotamente: verificar divergência Git, histórico remoto de migrations, estado do catálogo/ZIV01, conexão GitHub–Vercel, branch de deploy, variáveis necessárias e URLs de Auth sem divulgar valores. Interromper se houver divergência ou migration de mesmo nome com conteúdo diferente.
3. Aplicar somente migrations ausentes e individualmente autorizadas, em ordem. Elas devem preceder o código que chama as novas RPCs. Falha interrompe a sequência; não efetuar rollback destrutivo nem alterar dados históricos para contornar falhas.
4. Publicar pelo GitHub oficial, sem force push, acompanhar Vercel READY e conferir rotas/funções alteradas. Não habilitar flags, módulos, empresas ou grants como consequência do deploy.
5. Com empresa/filial piloto e usuário autenticado indicados, homologar fluxo completo: limites/comercial, faturamento e parcelas, baixa/estorno, caixa/bancos, OFX/reconciliação, DRE/fluxo, relatórios/exportação e navegação. Verificar negações em outra empresa/filial e ausência de concessões automáticas. Registrar resultados sem dados privados no Git.

Nenhum push, deploy, aplicação remota, concessão Master ou homologação autenticada em produção foi realizado nesta etapa. GO comercial e G1 permanecem pendentes; ZIV01 exige homologação específica.

## Limites funcionais deliberados

DRE é gerencial sobre obrigações classificadas, sem substituir escrituração contábil. Relatório de estoque representa movimentos no período e seus saldos persistidos, não reconstrução contábil de posição em qualquer data. Financeiro usa emissão/competência e saldo atual; caixa/bancos não são somados novamente ao fluxo derivado de baixas. Políticas não são impostas automaticamente a empresas sem assinatura; inscrição comercial continua manual. Alterações simultâneas de plano e assinatura podem ser rejeitadas pelo PostgreSQL em caso de deadlock e devem ser repetidas após consulta, sem persistência parcial.
