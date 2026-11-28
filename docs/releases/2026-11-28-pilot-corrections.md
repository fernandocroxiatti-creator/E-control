# Correções da homologação operacional — 28/11/2026

Estado: preparadas localmente; aplicação remota e publicação sensível dependem de autorização específica.

Base publicada: `011cd26ab827172c8b6ec2d83818550067b13589`. As dez migrations do manifesto anterior permanecem inalteradas.

Aplicar na ordem abaixo, após o pacote final existente. Não criam grants, não habilitam empresas nem ZIV01 e não reescrevem registros históricos.

## 20261128140000_restore_inventory_movement_authorization.sql

SHA-256: `987e715831b69fa128eebb5b957238f4e8dc13ea5094c40eae2469b2d2157653`

Restaura o mapeamento existente de `transaction.inventory.stock.move` para MIGO, preservando todas as verificações de autorização.

## 20261128141000_delivered_sales_billing_consistency.sql

SHA-256: `86ec42a6350e26b170f8e3e19fca8d1fd78eae5de21842f528cbce74ef0a068f`

Permite faturar vendas entregues e impede cancelamento/devolução enquanto houver faturamento ativo. Mantém idempotência e isolamento.

## 20261128142000_cancelled_obligation_report_balance.sql

SHA-256: `ab8c2ba1d978b793a1e113406ab5e60e4e055e818d3fc9c36b4258a0e12d53b8`

Mantém o valor histórico de obrigações canceladas e informa saldo exigível zero nos relatórios.

## Correções de interface

- Renova o identificador da operação após sucesso confirmado e preserva-o em tentativas de recuperação.
- Inclui vendas entregues nas origens de faturamento.
- Deixa de apresentar o fundo inicial como saldo esperado de uma sessão de caixa aberta.

## Validação local

202 testes Node aprovados; lint, TypeScript e build aprovados. Regressão PostgreSQL 17.11 integral aprovada, incluindo concorrência, SaaS, OFX, integração de faturamento e financeiro, leitura MIGO após a cadeia final, faturamento de venda entregue e proteção contra cancelamento.

A homologação autenticada dessas correções permanece pendente da publicação.
