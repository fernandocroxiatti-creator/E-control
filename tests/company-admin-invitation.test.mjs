import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const migration = readFileSync(resolve(root, "supabase/migrations/20261027180000_company_admin_invitations.sql"), "utf8");
const actions = readFileSync(resolve(root, "app/actions/company-admin-invitations.ts"), "utf8");
const page = readFileSync(resolve(root, "app/master/administradores/page.tsx"), "utf8");
const acceptPage = readFileSync(resolve(root, "app/convites/aceitar/page.tsx"), "utf8");
const acceptForm = readFileSync(resolve(root, "app/convites/aceitar/accept-invitation-form.tsx"), "utf8");

test("invitation SQL binds actor only to authenticated auth.uid() and fixed company_owner role", () => {
  assert.match(migration, /actor_id\s*:=\s*app_private\.assert_current_master\(\)/);
  assert.match(migration, /auth\.role\(\)[\s\S]*?'authenticated'/);
  assert.match(migration, /actor_id\s*:=\s*auth\.uid\(\)/);
  assert.match(migration, /role_key\s*=\s*'company_owner'/);
  assert.doesNotMatch(migration, /p_(?:user|actor|role|master)_?(?:id|key)?\s+(?:uuid|text)/i);
  assert.doesNotMatch(migration, /auth\.role\(\)\s*=\s*'service_role'/i);
});

test("invitation bearer secret is generated once, stored only as SHA-256 and expires in seven days", () => {
  assert.match(migration, /token_digest\s+bytea\s+not null unique/);
  assert.match(migration, /pg_catalog\.sha256\(pg_catalog\.convert_to\(invite_token, 'UTF8'\)\)/);
  assert.match(migration, /pg_catalog\.sha256\(pg_catalog\.convert_to\(p_invitation_token, 'UTF8'\)\)/);
  assert.match(migration, /gen_random_uuid\(\)::text \|\| pg_catalog\.gen_random_uuid\(\)::text/);
  assert.match(migration, /interval '7 days'/);
  assert.doesNotMatch(migration, /token\s+text\s+not null\s*,/i);
});

test("acceptance verifies authenticated confirmed email and atomically creates only the fixed company role", () => {
  assert.match(migration, /auth_user\.email_confirmed_at is not null/);
  assert.match(migration, /actor_email <> invitation_row\.recipient_email/);
  assert.match(migration, /insert into public\.company_memberships[\s\S]*?'active', 'all_branches', actor_id/);
  assert.match(migration, /insert into public\.membership_role_assignments[\s\S]*?'company_owner', null, actor_id/);
  assert.match(migration, /company_owner[\s\S]*?approval_state = 'approved'/);
  assert.match(migration, /company_admin_invitation\.accepted/);
  assert.match(migration, /company_admin_invitation\.expired/);
  assert.match(migration, /company_admin_invitation\.revoked/);
  assert.match(migration, /company_admin_invitation\.issued/);
});

test("tenant isolation and replay/expiry/revocation are serialized and fail closed", () => {
  assert.match(migration, /pg_advisory_xact_lock/);
  assert.match(migration, /for update/gi);
  assert.match(migration, /unique index company_admin_invitations_one_pending_per_company/);
  assert.match(migration, /constraint company_admin_invitation_actor_request_unique unique/);
  assert.match(migration, /invitation\.tenant_id = p_tenant_id/);
  assert.match(migration, /membership\.tenant_id = invitation_row\.tenant_id/);
  assert.match(migration, /invitation_row\.status <> 'pending'/);
  assert.match(migration, /invitation_row\.expires_at <= pg_catalog\.clock_timestamp\(\)/);
  assert.match(migration, /status = 'revoked'/);
});

test("all public RPCs are SECURITY DEFINER with closed search_path and restricted ACL", () => {
  const rpcNames = [
    "master_create_company_admin_invitation(uuid,text,uuid)",
    "accept_company_admin_invitation(text)",
    "master_revoke_company_admin_invitation(uuid)",
    "master_list_company_admin_invitations(uuid)",
    "master_expire_company_admin_invitations(uuid)",
  ];
  for (const name of rpcNames) {
    assert.ok(migration.includes(`alter function public.${name} owner to postgres`));
    assert.ok(migration.includes(`revoke all on function public.${name} from public, anon, authenticated, service_role`));
    assert.ok(migration.includes(`grant execute on function public.${name} to authenticated`));
  }
  assert.equal((migration.match(/security definer/gi) ?? []).length, 5);
  assert.equal((migration.match(/set search_path = '' set row_security = off/gi) ?? []).length, 5);
  assert.match(migration, /enable row level security[\s\S]*?force row level security/);
  assert.match(migration, /revoke all on table app_private\.company_admin_invitations from public, anon, authenticated, service_role/);
});

test("Next Server Actions use the authenticated SSR session, explicit feature flag, and never service_role", () => {
  assert.match(actions, /client\.auth\.getUser\(\)/);
  assert.match(actions, /requireMasterUser\(\)/);
  assert.match(actions, /env\.companyInvitationsEnabled/);
  assert.match(actions, /isAuthorizedSupabaseTarget\(env\)/);
  assert.match(actions, /accept_company_admin_invitation/);
  assert.match(actions, /master_create_company_admin_invitation/);
  assert.match(actions, /master_revoke_company_admin_invitation/);
  assert.match(actions, /master_expire_company_admin_invitations/);
  assert.doesNotMatch(actions, /service_role|SUPABASE_SERVICE_ROLE_KEY|console\.(?:log|error)/i);
  assert.match(actions, /inviteUrl\.hash/);
});

test("acceptance route checks Auth server-side and carries token only in URL fragment/client memory", () => {
  assert.match(acceptPage, /auth\.getUser\(\)/);
  assert.match(acceptForm, /window\.location\.hash/);
  assert.match(acceptForm, /history\.replaceState/);
  assert.match(acceptForm, /authenticated/);
  assert.doesNotMatch(acceptForm, /localStorage|sessionStorage|console\.(?:log|error)/);
  assert.match(page, /CompanyAdminInvitationForm/);
  assert.match(page, /getCompanyAdminInvitations/);
  assert.match(page, /company_owner/);
});
