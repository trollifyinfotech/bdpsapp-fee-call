-- =====================================================================
-- Migration 002 : Authorization helpers, triggers, reference data
-- =====================================================================

-- ---------------------------------------------------------------------
-- Authorization helpers (SECURITY DEFINER so RLS policies can call them
-- without recursive policy evaluation).
-- ---------------------------------------------------------------------
create or replace function public.is_super_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.is_super_admin from public.user_profiles p where p.id = auth.uid()), false);
$$;

create or replace function public.school_is_usable(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.schools s where s.id = sid and s.status = 'active')
     and not exists (select 1 from public.school_subscriptions ss
                     where ss.school_id = sid and ss.status = 'active'
                       and ss.expires_on is not null and ss.expires_on < current_date);
$$;

create or replace function public.is_member(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.school_memberships m
                 where m.school_id = sid and m.user_id = auth.uid() and m.is_active)
     and public.school_is_usable(sid);
$$;

create or replace function public.my_role(sid uuid) returns text
language sql stable security definer set search_path = public as $$
  select m.role_code from public.school_memberships m
  where m.school_id = sid and m.user_id = auth.uid() and m.is_active
$$;

-- Effective permission = explicit per-user override (grant OR deny) else role default.
create or replace function public.user_has_perm(uid uuid, sid uuid, code text) returns boolean
language sql stable security definer set search_path = public as $$
  select
    exists (select 1 from public.school_memberships m
            where m.school_id = sid and m.user_id = uid and m.is_active)
    and public.school_is_usable(sid)
    and coalesce(
      (select up.granted from public.user_permissions up
        where up.school_id = sid and up.user_id = uid and up.permission_code = code),
      exists (select 1 from public.school_memberships m
              join public.role_permissions rp on rp.role_code = m.role_code
              where m.school_id = sid and m.user_id = uid and m.is_active and rp.permission_code = code)
    );
$$;

create or replace function public.has_perm(sid uuid, code text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.user_has_perm(auth.uid(), sid, code);
$$;

-- Returns the caller's school (first active membership). The frontend still
-- sends no school_id for sensitive operations: RPCs derive it from here.
create or replace function public.my_school_id() returns uuid
language sql stable security definer set search_path = public as $$
  select m.school_id from public.school_memberships m
  where m.user_id = auth.uid() and m.is_active and public.school_is_usable(m.school_id)
  order by m.created_at limit 1;
$$;

-- Raises unless caller holds the permission in the school.
create or replace function public.require_perm(sid uuid, code text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if sid is null or not public.has_perm(sid, code) then
    raise exception 'Permission denied: % required', code using errcode = '42501';
  end if;
end $$;

-- School-local date (India). All due-date / reminder logic uses this, not UTC current_date.
create or replace function public.today_local() returns date
language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- ---------------------------------------------------------------------
-- Counters / notifications / audit helpers
-- ---------------------------------------------------------------------
create or replace function public.next_counter(sid uuid, k text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  insert into public.counters (school_id, key, value) values (sid, k, 1)
  on conflict (school_id, key) do update set value = public.counters.value + 1
  returning value into v;
  return v;
end $$;
revoke all on function public.next_counter(uuid, text) from public, anon, authenticated;

create or replace function public.notify(sid uuid, uid uuid, ntype text, ntitle text, nbody text,
                                         nlink text default null, ndedupe text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if uid is null then return; end if;
  insert into public.notifications (school_id, user_id, type, title, body, link, dedupe_key)
  values (sid, uid, ntype, ntitle, nbody, nlink, ndedupe)
  on conflict (user_id, dedupe_key) where dedupe_key is not null do nothing;
end $$;
revoke all on function public.notify(uuid, uuid, text, text, text, text, text) from public, anon, authenticated;

-- Notify every active member of the school who holds a permission.
create or replace function public.notify_perm(sid uuid, perm text, ntype text, ntitle text, nbody text,
                                              nlink text default null, ndedupe text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select m.user_id from public.school_memberships m where m.school_id = sid and m.is_active loop
    if public.user_has_perm(r.user_id, sid, perm) then
      perform public.notify(sid, r.user_id, ntype, ntitle, nbody, nlink,
                            case when ndedupe is null then null else ndedupe || ':' || r.user_id end);
    end if;
  end loop;
end $$;
revoke all on function public.notify_perm(uuid, text, text, text, text, text, text) from public, anon, authenticated;

create or replace function public.notify_roles(sid uuid, roles text[], ntype text, ntitle text, nbody text,
                                               nlink text default null, ndedupe text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select m.user_id from public.school_memberships m
           where m.school_id = sid and m.is_active and m.role_code = any(roles) loop
    perform public.notify(sid, r.user_id, ntype, ntitle, nbody, nlink,
                          case when ndedupe is null then null else ndedupe || ':' || r.user_id end);
  end loop;
end $$;
revoke all on function public.notify_roles(uuid, text[], text, text, text, text, text) from public, anon, authenticated;

create or replace function public.audit_write(sid uuid, act text, rtype text, rid text,
                                              oldv jsonb, newv jsonb, why text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_logs (school_id, user_id, action, record_type, record_id, old_values, new_values, reason)
  values (sid, auth.uid(), act, rtype, rid, oldv, newv, why);
end $$;
revoke all on function public.audit_write(uuid, text, text, text, jsonb, jsonb, text) from public, anon, authenticated;

-- Client-callable audit for events the database cannot observe (login/logout/export).
create or replace function public.log_audit(p_action text, p_record_type text default null, p_details jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid := public.my_school_id();
begin
  if p_action not in ('login','logout','data_export','report_print') then
    raise exception 'Action not allowed from client';
  end if;
  insert into public.audit_logs (school_id, user_id, action, record_type, new_values)
  values (sid, auth.uid(), p_action, p_record_type, p_details);
end $$;

-- Generic row-level audit trigger
create or replace function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  rec jsonb; oldj jsonb; sid uuid; rid text; why text;
begin
  why := nullif(current_setting('app.audit_reason', true), '');
  if tg_op = 'DELETE' then rec := to_jsonb(old); oldj := rec;
  elsif tg_op = 'UPDATE' then
    rec := to_jsonb(new); oldj := to_jsonb(old);
    if rec = oldj then return new; end if;
  else rec := to_jsonb(new); end if;
  sid := nullif(rec->>'school_id', '')::uuid;
  if tg_table_name = 'schools' then sid := (rec->>'id')::uuid; end if;
  rid := coalesce(rec->>'id', rec->>'user_id');
  insert into public.audit_logs (school_id, user_id, action, record_type, record_id, old_values, new_values, reason)
  values (sid, auth.uid(), lower(tg_table_name || '.' || tg_op), tg_table_name, rid, oldj,
          case when tg_op = 'DELETE' then null else rec end, why);
  return case when tg_op = 'DELETE' then old else new end;
end $$;

do $$
declare t text;
begin
  foreach t in array array['students','student_session_enrollments','families','family_members','family_policies',
    'fee_heads','fee_structures','student_fee_assignments','fee_adjustments','student_discounts','rte_records','rte_reimbursements',
    'scholarship_records','payments','payment_verifications','receipts','transaction_reversals','calling_tasks',
    'task_assignment_history','calling_logs','payment_promises','school_memberships','user_permissions',
    'academic_sessions','school_settings','schools','import_batches','teacher_calling_targets','school_subscriptions']
  loop
    execute format('create trigger trg_audit_%1$s after insert or update or delete on public.%1$s for each row execute function public.audit_row()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Immutability: financial + audit records are never silently erased.
-- ---------------------------------------------------------------------
create or replace function public.forbid_delete() returns trigger language plpgsql as $$
begin
  raise exception 'Deleting % records is not allowed (append-only). Use cancellation/reversal.', tg_table_name
    using errcode = '42501';
end $$;

create or replace function public.forbid_update() returns trigger language plpgsql as $$
begin
  raise exception '% records are immutable.', tg_table_name using errcode = '42501';
end $$;

do $$
declare t text;
begin
  foreach t in array array['payments','payment_allocations','payment_verifications','receipts',
      'transaction_reversals','calling_logs','audit_logs','task_assignment_history','fee_adjustments','rte_reimbursements']
  loop
    execute format('create trigger trg_nodelete_%1$s before delete on public.%1$s for each row execute function public.forbid_delete()', t);
  end loop;
  foreach t in array array['payment_allocations','payment_verifications','transaction_reversals',
      'calling_logs','audit_logs','task_assignment_history','fee_adjustments']
  loop
    execute format('create trigger trg_noupdate_%1$s before update on public.%1$s for each row execute function public.forbid_update()', t);
  end loop;
end $$;

-- Payments: only status / verification columns may change after creation.
create or replace function public.payments_guard() returns trigger language plpgsql as $$
begin
  if new.amount is distinct from old.amount or new.school_id is distinct from old.school_id
     or new.session_id is distinct from old.session_id or new.student_id is distinct from old.student_id
     or new.enrollment_id is distinct from old.enrollment_id or new.receipt_no is distinct from old.receipt_no
     or new.txn_id is distinct from old.txn_id or new.payment_date is distinct from old.payment_date
     or new.mode is distinct from old.mode or new.collector_id is distinct from old.collector_id then
    raise exception 'Payment core fields are immutable. Cancel and re-enter instead.' using errcode = '42501';
  end if;
  if old.status in ('rejected','cancelled') and new.status is distinct from old.status then
    raise exception 'A % payment cannot change status.', old.status using errcode = '42501';
  end if;
  if old.status = 'verified' and new.status not in ('verified','cancelled') then
    raise exception 'Verified payment can only be cancelled.' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger trg_payments_guard before update on public.payments
  for each row execute function public.payments_guard();

-- Allocations must equal payment amount (checked at commit so batches can insert rows one by one)
create or replace function public.check_allocation_total() returns trigger
language plpgsql as $$
declare p record; s numeric;
begin
  select id, amount into p from public.payments where id = new.payment_id;
  select coalesce(sum(amount), 0) into s from public.payment_allocations where payment_id = new.payment_id;
  if s <> p.amount then
    raise exception 'Allocation total % does not equal payment amount % (payment %)', s, p.amount, p.id;
  end if;
  return null;
end $$;
create constraint trigger trg_alloc_total after insert on public.payment_allocations
  deferrable initially deferred for each row execute function public.check_allocation_total();

-- ---------------------------------------------------------------------
-- Students: permanent ID, subscription limit, protected columns
-- ---------------------------------------------------------------------
create or replace function public.students_before_write() returns trigger
language plpgsql security definer set search_path = public as $$
declare maxs int; cnt int;
begin
  if tg_op = 'INSERT' then
    if new.student_code is null or new.student_code = '' then
      new.student_code := 'STU-' || lpad(public.next_counter(new.school_id, 'student')::text, 6, '0');
    end if;
    new.created_by := coalesce(new.created_by, auth.uid());
    select ss.max_students into maxs from public.school_subscriptions ss
      where ss.school_id = new.school_id and ss.status = 'active';
    if maxs is not null then
      select count(*) into cnt from public.students where school_id = new.school_id and status = 'active';
      if cnt >= maxs then
        raise exception 'Subscription student limit (%) reached for this school.', maxs;
      end if;
    end if;
  else
    if new.student_code is distinct from old.student_code or new.school_id is distinct from old.school_id then
      raise exception 'Student ID and school are permanent and cannot be changed.' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
create trigger trg_students_before before insert or update on public.students
  for each row execute function public.students_before_write();

-- ---------------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.user_profiles (id, email, full_name, mobile)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data->>'full_name', ''),
          new.raw_user_meta_data->>'mobile')
  on conflict (id) do nothing;
  return new;
end $$;
create trigger trg_on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.profile_guard() returns trigger language plpgsql as $$
begin
  if new.is_super_admin is distinct from old.is_super_admin
     and current_setting('role', true) in ('authenticated', 'anon') then
    raise exception 'Cannot change platform role.' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger trg_profile_guard before update on public.user_profiles
  for each row execute function public.profile_guard();

-- Memberships: nobody can alter their own role/activation via any path.
create or replace function public.membership_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and old.user_id = auth.uid()
     and (new.role_code is distinct from old.role_code or new.is_active is distinct from old.is_active)
     and current_setting('role', true) in ('authenticated', 'anon') then
    raise exception 'You cannot change your own role or status.' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger trg_membership_guard before update on public.school_memberships
  for each row execute function public.membership_guard();

-- ---------------------------------------------------------------------
-- Session validation: an enrollment's session must be open for new financial work
-- ---------------------------------------------------------------------
create or replace function public.session_is_open(sid uuid, sess uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.academic_sessions s where s.id = sess and s.school_id = sid and s.status = 'open');
$$;

-- ---------------------------------------------------------------------
-- Reference data: roles, permissions, role defaults, plans
-- ---------------------------------------------------------------------
insert into public.roles (code, name, description, rank) values
 ('super_admin','Super Admin','Platform owner (platform-level only)',100),
 ('school_owner','School Owner','Full control of the school account',90),
 ('principal','Principal','Administrative access, approvals and monitoring',80),
 ('accountant','Accountant','Fee collection, ledgers and financial reports',60),
 ('fee_manager','Fee Manager','Fee collection and fee structure',50),
 ('teacher','Teacher','Parent calling only; no financial amounts',30),
 ('viewer','Viewer / Auditor','Read-only reports and audit',10);

insert into public.permissions (code, name, category) values
 ('view_student_list','View Student List','Students'),
 ('add_student','Add Student','Students'),
 ('edit_student','Edit Student','Students'),
 ('archive_student','Delete/Archive Student','Students'),
 ('import_students','Import Students','Students'),
 ('manage_families','Manage Families & Siblings','Students'),
 ('manage_rte','Manage RTE & Scholarships','Students'),
 ('view_fee_details','View Fee Details (status)','Fees'),
 ('view_fee_amounts','View Fee Amounts','Fees'),
 ('collect_fee','Collect Fee','Fees'),
 ('edit_fee_structure','Edit Fee Structure','Fees'),
 ('apply_discount','Apply Discount','Fees'),
 ('approve_payment','Approve Online Payment','Fees'),
 ('cancel_receipt','Cancel Receipt','Fees'),
 ('print_receipt','Print Receipt','Fees'),
 ('view_fee_reports','View Fee Reports','Reports'),
 ('export_csv','Export CSV','Reports'),
 ('export_pdf','Export PDF','Reports'),
 ('view_financial_dashboard','View Financial Dashboard','Reports'),
 ('view_calling_crm','View Calling CRM','Calling CRM'),
 ('make_calls','Make Parent Calls','Calling CRM'),
 ('add_call_remarks','Add Calling Remarks','Calling CRM'),
 ('assign_calling_tasks','Assign Calling Tasks','Calling CRM'),
 ('view_teacher_performance','View Teacher Performance','Calling CRM'),
 ('manage_sessions','Manage Sessions','Administration'),
 ('manage_users','Manage Users','Administration'),
 ('manage_permissions','Manage Roles & Permissions','Administration'),
 ('manage_settings','Manage Settings','Administration'),
 ('view_audit_logs','View Audit Logs','Administration');

-- owner: everything
insert into public.role_permissions select 'school_owner', code from public.permissions;
-- principal: everything except permission management
insert into public.role_permissions select 'principal', code from public.permissions where code <> 'manage_permissions';
-- accountant
insert into public.role_permissions select 'accountant', code from public.permissions where code in
 ('view_student_list','view_fee_details','view_fee_amounts','collect_fee','print_receipt','view_fee_reports',
  'export_csv','export_pdf','view_financial_dashboard','manage_rte');
-- fee manager
insert into public.role_permissions select 'fee_manager', code from public.permissions where code in
 ('view_student_list','view_fee_details','view_fee_amounts','collect_fee','edit_fee_structure','print_receipt',
  'view_fee_reports','export_csv');
-- teacher: calling only, NO financial permission
insert into public.role_permissions select 'teacher', code from public.permissions where code in
 ('view_calling_crm','make_calls','add_call_remarks');
-- viewer / auditor
insert into public.role_permissions select 'viewer', code from public.permissions where code in
 ('view_student_list','view_fee_details','view_fee_amounts','view_fee_reports','view_financial_dashboard',
  'view_teacher_performance','view_audit_logs','export_csv','export_pdf');

insert into public.subscription_plans (code, name, max_students, max_users, price_monthly) values
 ('trial','Trial',300,10,0),
 ('standard','Standard',1500,30,999),
 ('premium','Premium',10000,100,2999);
