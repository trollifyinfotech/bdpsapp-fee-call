-- =====================================================================
-- 009: Everything that used to need Edge Functions / CLI, done in SQL.
-- After this migration NO Edge Function and NO service_role key is needed.
--   * submit_registration       : school self-registration (after browser signUp)
--   * admin_attach_user         : attach a freshly signed-up account to my school
--   * admin_reset_password      : owner/principal resets a user's password
--   * set_member_active         : activate / deactivate a user
--   * run_my_reminders          : throttled reminder run, triggered from the app
--   * pg_cron job               : optional, runs reminders every 30 minutes
-- =====================================================================

-- ---------- 1. School self-registration ----------
create or replace function public.submit_registration(
  p_school_name text, p_school_code text, p_udise text, p_address text, p_city text, p_district text, p_state text,
  p_owner_name text, p_mobile text, p_logo_path text, p_terms boolean)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); em text; mob text; code text := upper(trim(coalesce(p_school_code,'')));
        sa record;
begin
  if uid is null then raise exception 'Not signed in' using errcode='42501'; end if;
  select email into em from auth.users where id = uid;
  if exists (select 1 from public.school_memberships where user_id = uid)
     or exists (select 1 from public.user_profiles where id = uid and is_super_admin)
     or exists (select 1 from public.school_registration_requests where owner_user_id = uid) then
    raise exception 'This account is already linked to a school or registration.';
  end if;
  mob := regexp_replace(coalesce(p_mobile,''), '\D', '', 'g');
  if length(mob) = 12 and left(mob,2) = '91' then mob := substr(mob,3); end if;
  if length(trim(coalesce(p_school_name,''))) < 3 then raise exception 'School name is required'; end if;
  if code !~ '^[A-Z0-9_-]{3,20}$' then raise exception 'School code must be 3-20 letters/numbers'; end if;
  if length(trim(coalesce(p_owner_name,''))) < 2 then raise exception 'Principal/Owner name is required'; end if;
  if mob !~ '^[6-9][0-9]{9}$' then raise exception 'Enter a valid 10-digit mobile number'; end if;
  if p_terms is not true then raise exception 'You must accept the Terms and Conditions'; end if;
  if p_logo_path is not null and p_logo_path not like 'pending/' || uid::text || '/%' then
    raise exception 'Invalid logo path'; end if;
  if exists (select 1 from public.schools where lower(school_code) = lower(code))
     or exists (select 1 from public.school_registration_requests where lower(school_code) = lower(code) and status in ('pending','approved')) then
    raise exception 'This school code is already registered'; end if;
  if nullif(trim(p_udise),'') is not null and exists (select 1 from public.school_registration_requests
       where udise_code = trim(p_udise) and status in ('pending','approved')) then
    raise exception 'This UDISE code is already registered'; end if;

  insert into public.school_registration_requests (school_name, school_code, udise_code, address, state, district, city,
      owner_name, mobile, email, owner_user_id, logo_path, terms_accepted)
  values (trim(p_school_name), code, nullif(trim(p_udise),''), trim(coalesce(p_address,'')), trim(coalesce(p_state,'')),
      trim(coalesce(p_district,'')), trim(coalesce(p_city,'')), trim(p_owner_name), mob, lower(em), uid, p_logo_path, true);
  update public.user_profiles set full_name = trim(p_owner_name), mobile = mob where id = uid;

  for sa in select id from public.user_profiles where is_super_admin loop
    insert into public.notifications (user_id, type, title, body, link, dedupe_key)
    values (sa.id, 'school_registration', 'New school registration',
            trim(p_school_name) || ' (' || code || ') is awaiting approval', '/super-admin/index.html', 'reg:' || uid)
    on conflict do nothing;
  end loop;
end $$;

-- ---------- 2. Add a user to my school ----------
-- The browser creates the login with auth.signUp (separate, non-persisting client);
-- this RPC then attaches that brand-new account. Safety rules: the account must be
-- < 10 minutes old, must have no school/registration yet, and the caller needs manage_users.
create or replace function public.admin_attach_user(p_user uuid, p_full_name text, p_mobile text, p_role text, p_designation text)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid := public.my_school_id(); myrole text; mob text; created timestamptz; lim int; cnt int; em text;
begin
  perform public.require_perm(sid, 'manage_users');
  myrole := public.my_role(sid);
  if p_role not in ('principal','accountant','fee_manager','teacher','viewer') then raise exception 'Invalid role'; end if;
  if p_role = 'principal' and myrole <> 'school_owner' then
    raise exception 'Only the School Owner can create a Principal' using errcode='42501'; end if;
  if length(trim(coalesce(p_full_name,''))) < 2 then raise exception 'Name is required'; end if;
  mob := regexp_replace(coalesce(p_mobile,''), '\D', '', 'g');
  if length(mob) = 12 and left(mob,2) = '91' then mob := substr(mob,3); end if;
  if mob <> '' and mob !~ '^[6-9][0-9]{9}$' then raise exception 'Invalid mobile number'; end if;
  select created_at, email into created, em from auth.users where id = p_user;
  if created is null then raise exception 'Account not found'; end if;
  if created < now() - interval '10 minutes' then raise exception 'This account was not created just now and cannot be attached'; end if;
  if exists (select 1 from public.school_memberships where user_id = p_user)
     or exists (select 1 from public.school_registration_requests where owner_user_id = p_user)
     or exists (select 1 from public.user_profiles where id = p_user and is_super_admin) then
    raise exception 'This account already belongs to a school'; end if;
  select max_users into lim from public.school_subscriptions where school_id = sid and status = 'active';
  select count(*) into cnt from public.school_memberships where school_id = sid and is_active;
  if lim is not null and cnt >= lim then raise exception 'User limit (%) of your subscription is reached', lim; end if;

  insert into public.school_memberships (school_id, user_id, role_code, designation, created_by)
  values (sid, p_user, p_role, nullif(trim(p_designation),''), auth.uid());
  update public.user_profiles set full_name = trim(p_full_name), mobile = nullif(mob,'') where id = p_user;
  perform public.audit_write(sid, 'user.created', 'user', p_user::text, null,
          jsonb_build_object('email', em, 'role', p_role, 'full_name', trim(p_full_name)), null);
end $$;

-- ---------- 3. Reset password / activate / deactivate ----------
create or replace function public._target_member_check(p_user uuid, p_for_active boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid := public.my_school_id(); myrole text; trole text;
begin
  perform public.require_perm(sid, 'manage_users');
  myrole := public.my_role(sid);
  select role_code into trole from public.school_memberships where school_id = sid and user_id = p_user;
  if trole is null then raise exception 'User not found in your school'; end if;
  if p_for_active and p_user = auth.uid() then raise exception 'You cannot deactivate your own account'; end if;
  if trole = 'school_owner' and myrole <> 'school_owner' then
    raise exception 'Only the Owner can modify the Owner account' using errcode='42501'; end if;
  if trole = 'principal' and myrole not in ('school_owner') and p_user <> auth.uid() then
    raise exception 'Only the Owner can modify a Principal' using errcode='42501'; end if;
  return sid;
end $$;

create or replace function public.admin_reset_password(p_user uuid, p_password text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare sid uuid;
begin
  sid := public._target_member_check(p_user);
  if length(coalesce(p_password,'')) < 8 or p_password !~ '[A-Za-z]' or p_password !~ '[0-9]' then
    raise exception 'Password must be at least 8 characters with letters and numbers'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now()
   where id = p_user;
  begin delete from auth.sessions where user_id = p_user; exception when undefined_table then null; end;
  perform public.audit_write(sid, 'user.password_reset', 'user', p_user::text, null, null, null);
end $$;

create or replace function public.set_member_active(p_user uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  sid := public._target_member_check(p_user, true);
  update public.school_memberships set is_active = coalesce(p_active, false) where school_id = sid and user_id = p_user;
  if not coalesce(p_active, false) then
    begin delete from auth.sessions where user_id = p_user; exception when undefined_table then null; end;
  end if;
end $$;

-- ---------- 4. Reminders without any scheduler ----------
create table if not exists public.reminder_runs (school_id uuid primary key references public.schools(id) on delete cascade, last_run timestamptz not null);
alter table public.reminder_runs enable row level security;   -- no policies: RPC only

-- Called by the app when any staff member opens it. Idempotent and throttled to once per 20 minutes per school.
create or replace function public.run_my_reminders() returns jsonb
language plpgsql security definer set search_path = public as $$
declare sid uuid := public.my_school_id(); got int;
begin
  if sid is null then return jsonb_build_object('ran', false); end if;
  insert into public.reminder_runs (school_id, last_run) values (sid, now())
  on conflict (school_id) do update set last_run = now()
    where public.reminder_runs.last_run < now() - interval '20 minutes';
  get diagnostics got = row_count;
  if got = 0 then return jsonb_build_object('ran', false, 'reason', 'throttled'); end if;
  return jsonb_build_object('ran', true, 'result', public.run_reminders(sid));
end $$;

-- Optional: pg_cron every 30 minutes (enable "pg_cron" under Database > Extensions; harmless if unavailable)
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('trollify-reminders', '*/30 * * * *', 'select public.run_reminders(null)');
exception when others then
  raise notice 'pg_cron not available (%). Reminders will still run when staff open the app.', sqlerrm;
end $$;

-- ---------- privileges ----------
revoke all on function public.submit_registration(text,text,text,text,text,text,text,text,text,text,boolean) from public, anon;
revoke all on function public.admin_attach_user(uuid,text,text,text,text) from public, anon;
revoke all on function public.admin_reset_password(uuid,text) from public, anon;
revoke all on function public.set_member_active(uuid,boolean) from public, anon;
revoke all on function public.run_my_reminders() from public, anon;
revoke all on function public._target_member_check(uuid,boolean) from public, anon, authenticated;
grant execute on function public.submit_registration(text,text,text,text,text,text,text,text,text,text,boolean) to authenticated;
grant execute on function public.admin_attach_user(uuid,text,text,text,text) to authenticated;
grant execute on function public.admin_reset_password(uuid,text) to authenticated;
grant execute on function public.set_member_active(uuid,boolean) to authenticated;
grant execute on function public.run_my_reminders() to authenticated;
