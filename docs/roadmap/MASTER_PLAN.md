# eControll — Plano Mestre Cronológico

> Controle local criado em 2026-11-16. Nunca registrar segredos ou dados pessoais.

## Visão e regras permanentes

O eControll é um ERP SaaS multiempresa e multifilial. Toda operação requer sessão,
vínculo ativo, filial autorizada, papel/grant, aprovação global e disponibilidade
empresarial. O Admin Master governa acesso, mas não recebe dados operacionais de
clientes por padrão.

Antes de cada tarefa, ler os cinco documentos desta pasta. Não iniciar uma fase
posterior sem critérios de aceite da anterior. Toda mutação exige autorização
server-side, RLS/FORCE RLS, auditoria, transação atômica, idempotência e estorno
auditável. Nunca usar `service_role` para contornar a autorização operacional.

## Fases obrigatórias

| Ordem | Fase | Estado |
|---:|---|---|
| 1 | Recebimento de compras, estoque e custo médio | Hardening local de idempotência e concorrência aprovado em auditoria independente; pronto somente para o sexto commit local. Publicação, migration e ativação gradual permanecem pendentes de autorização. |
| 2 | Compra direta para O.S. | Não iniciada |
| 3 | Orçamentos e conversão | Não iniciada |
| 4 | O.S. completa | Não iniciada |
| 5 | Vendas e faturamento gerencial | Não iniciada |
| 6 | Financeiro | Não iniciada |
| 7 | Caixa e conciliação | Não iniciada |
| 8 | DRE e relatórios | Não iniciada |
| 9 | Comercial SaaS | Não iniciada |

## Portões

- Fase 1 precisa de recebimento idempotente, valuation por filial e testes de
  concorrência contra transferência, inventário e O.S. antes da Fase 2. Os
  testes são feitos em sessões PostgreSQL concorrentes reais, com timeout e
  repetição; uma contagem física obsoleta deve falhar para recontagem.
- O estorno, recebimento, transferência, inventário, reservas, consumo/reversão
  de O.S. e avaliação inicial seguem o protocolo: lock de idempotência quando
  existir; locks advisory de posição `(empresa, filial, produto)` ordenados;
  linhas de documento; linha de saldo. D05 falha fechada: reserva ativa ou saída
  posterior bloqueia estorno sem rastreabilidade por lote.
- Um `request_id` é a identidade integral de um comando: repetição com payload
  normalizado idêntico retorna o fato existente; qualquer diferença relevante
  falha com `23505`. Esse contrato vale para movimento avaliado, transferência
  e avaliação inicial, inclusive sob concorrência real. O namespace é
  `(empresa, tipo de operação)`: o mesmo UUID pode existir em operações distintas,
  mas nunca mistura ou retorna fatos entre tabelas. Custo calculado pelo servidor
  não é campo do payload e não pode fazer um replay idêntico falhar.
- Fases posteriores não criam lançamentos financeiros/fiscais sem regra aprovada.
- Publicação, migrations remotas, grants e disponibilidade empresarial exigem
  autorização específica, mesmo após o código local estar aprovado.
- O rollout da Fase 1 é progressivo: backup recuperável, código compatível,
  migration, verificação de schema, avaliação de saldos legados por ZIV01 e,
  somente então, ZGR01 para uma empresa/filial piloto explicitamente autorizada.

## Referências existentes

- Fundação operacional: `20261029130000_operational_erp_foundation.sql`.
- Compras: `20261029160000_inventory_history_purchase_foundation.sql`.
- Estoque avançado/O.S.: `20261105100000_inventory_work_order_foundation.sql`.
- Read models: `20261110100000_inventory_work_order_read_models.sql`.
- Segurança/autorização: `20261030110000`, `20261030120000`, `20261109130000`.
