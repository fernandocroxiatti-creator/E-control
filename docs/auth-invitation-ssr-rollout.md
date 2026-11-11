# Rollout seguro de convites Auth com confirmação SSR

## Objetivo

Usar `token_hash` e `verifyOtp` no endpoint `/auth/confirm`, evitando que uma
sessão anterior do navegador seja usada para aceitar um convite destinado a
outra pessoa. Este procedimento não emite convites, não altera vínculos e não
aprova permissões.

## Pré-requisitos

- O código que contém `/auth/confirm` deve estar publicado antes de qualquer
  mudança nos templates Auth hospedados.
- As migrations de convite empresarial, gestão de funcionários e onboarding
  (`20261027180000`, `20261109100000`, `20261110120000`) devem existir no
  ambiente que receberá o teste. A confirmação Auth e a definição de senha não
  precisam de migration; o aceite do vínculo precisa dessas RPCs.
- `ECONTROLL_AUTH_SSR_CONFIRMATION_ENABLED` permanece ausente ou `false` no
  primeiro deploy. Esse é o comportamento padrão do código.

## Ordem de ativação

1. Publicar o código com a flag ausente/`false`. As emissões continuam usando
   exatamente o callback legado.
2. No Supabase Auth, manter `https://www.econtroll.com.br` como Site URL e
   adicionar, sem curingas, as três Redirect URLs emitidas pelo novo fluxo:
   - `https://www.econtroll.com.br/auth/confirm?flow=company-owner-invite`
   - `https://www.econtroll.com.br/auth/confirm?flow=employee-invite`
   - `https://www.econtroll.com.br/auth/confirm?flow=password-recovery`
3. Trocar os templates hospedados **Invite user** e **Reset password** para
   enviar o destinatário ao endpoint abaixo, preservando `RedirectTo`:

   ```html
   <a href="https://www.econtroll.com.br/auth/confirm?token_hash={{ .TokenHash }}&amp;type=invite&amp;redirect_to={{ .RedirectTo }}">Ativar conta</a>
   ```

   No template de recuperação, trocar somente `type=invite` por
   `type=recovery`. Desativar rastreamento de clique para os e-mails Auth do
   provedor SMTP; ele não pode reescrever o link de confirmação.
4. Enquanto a flag continua `false`, fazer um único teste com endereço interno
   autorizado. O endpoint aceita o `RedirectTo` legado exato e cria a sessão
   vinculada ao token antes de mostrar a primeira senha.
5. Testar em navegador limpo, em navegador já autenticado como outro usuário e
   no Safari do iPhone. Confirmar que o destino é a senha, que o aceite exige
   confirmação e que convite expirado/revogado é recusado.
6. Depois de aprovar os testes, configurar exclusivamente
   `ECONTROLL_AUTH_SSR_CONFIRMATION_ENABLED=true` no ambiente Production e
   redeployar. Novas emissões passam a usar os três Redirect URLs SSR.

## Reversão

1. Primeiro definir `ECONTROLL_AUTH_SSR_CONFIRMATION_ENABLED=false` e
   redeployar; novas emissões voltam ao callback legado.
2. O endpoint `/auth/confirm` continua entendendo os Redirect URLs legados,
   então os templates hospedados podem permanecer temporariamente como estão.
3. Só restaurar templates ou remover `/auth/confirm` depois que todos os links
   emitidos durante a transição tiverem expirado. Pausar emissões Auth antes de
   uma reversão de código que remova a rota.

## Limites de segurança

- A rota aceita somente `invite` e `recovery`, verifica o token uma única vez e
  nunca registra o valor.
- `redirect_to` aceita apenas o domínio canônico e os três fluxos SSR ou os
  três callbacks legados exatos; não há curingas nem destinos externos.
- O aceite empresarial continua validando e-mail confirmado, expiração,
  revogação, concorrência e autorização no banco.
