# Ordem de Serviço — fundação proposta

Esta é uma especificação de contrato; não cria interface, tabelas, estoque ou lançamentos.

## Transações reservadas

- `OS01` — criar O.S. em rascunho.
- `OS02` — alterar O.S. em rascunho.
- `OS03` — consultar O.S.
- `OS04` — encerrar O.S. aprovada.

Os códigos não existem no catálogo atual e devem iniciar `pending_approval` quando uma migration específica for aprovada.

## Escopo e estados

Cada O.S. pertence a uma empresa, filial, cliente e usuário responsável. Veículo ou equipamento é opcional. Estados mínimos: `draft`, `quoted`, `approved`, `in_progress`, `completed`, `cancelled`.

## Estoque

Peças devem ter reservas identificadas por O.S.; reserva não movimenta saldo. Somente a conclusão aprovada consome uma reserva exatamente uma vez, sob bloqueio por item/filial e chave de idempotência. Cancelamento libera reservas ainda não consumidas. Estorno exige transação própria, motivo e auditoria; nunca ocorre automaticamente por edição.

## Controles obrigatórios

Cada RPC futura exige sessão, empresa e filial ativas, vínculo, papel e grant efetivos, aprovação global, disponibilidade empresarial da transação e auditoria. Alterações de status e consumo usam bloqueio transacional; acesso direto por URL não substitui essa validação.
