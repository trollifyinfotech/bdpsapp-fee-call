-- =====================================================================
-- Migration 007 : Row Level Security
-- Principle: every table has RLS enabled. Clients get SELECT only where the
-- caller holds the matching permission; ALL financial / CRM writes go through
-- SECURITY DEFINER functions (which re-check permissions). Direct DML is
-- granted only where it is harmless and permission-checked by policy.
-- =====================================================================

do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke insert, update, delete, truncate on public.%I from authenticated', t);
  end loop;
end $$;
revoke all on public.v_enrollment_balances from anon;

-- Base read grant (rows still filtered by policies)
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('grant select on public.%I to authenticated', t);
  end loop;
  grant select on public.v_enrollment_balances to authenticated;
end $$;

-- ---------------------------------------------------------------------
-- Platform / identity
-- ---------------------------------------------------------------------
create policy profiles_read on public.user_profiles for select to authenticated
  using (id = auth.uid() or public.is_super_admin()
         or exists (select 1 from public.school_memberships a join public.school_memberships b on a.school_id = b.school_id
                    where a.user_id = auth.uid() and b.user_id = user_profiles.id and a.is_active
                      and (public.has_perm(a.school_id, 'manage_users') or public.has_perm(a.school_id, 'view_calling_crm')
                           or public.has_perm(a.school_id, 'view_audit_logs'))));
grant update (full_name, mobile) on public.user_profiles to authenticated;
create policy profiles_update_self on public.user_profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy schools_read on public.schools for select to authenticated
  using (public.is_super_admin() or exists (select 1 from public.school_memberships m
         where m.school_id = schools.id and m.user_id = auth.uid() and m.is_active));
grant update (phone, address, logo_path, name) on public.schools to authenticated;
create policy schools_update_owner on public.schools for update to authenticated
  using (public.has_perm(id, 'manage_settings')) with check (public.has_perm(id, 'manage_settings'));

create policy regreq_read on public.school_registration_requests for select to authenticated
  using (public.is_super_admin() or owner_user_id = auth.uid());

create policy plans_read on public.subscription_plans for select to authenticated using (true);
create policy sub_read on public.school_subscriptions for select to authenticated
  using (public.is_super_admin() or public.is_member(school_id));
create policy platpay_read on public.platform_payments for select to authenticated using (public.is_super_admin());

create policy roles_read on public.roles for select to authenticated using (true);
create policy perms_read on public.permissions for select to authenticated using (true);
create policy roleperms_read on public.role_permissions for select to authenticated using (true);

create policy memberships_read on public.school_memberships for select to authenticated
  using (user_id = auth.uid() or public.is_super_admin()
         or public.has_perm(school_id, 'manage_users') or public.has_perm(school_id, 'assign_calling_tasks')
         or public.has_perm(school_id, 'view_teacher_performance'));
create policy userperms_read on public.user_permissions for select to authenticated
  using (user_id = auth.uid() or public.has_perm(school_id, 'manage_permissions') or public.has_perm(school_id, 'manage_users'));

create policy settings_read on public.school_settings for select to authenticated using (public.is_member(school_id));
create policy settings_write on public.school_settings for insert to authenticated with check (public.has_perm(school_id, 'manage_settings'));
create policy settings_update on public.school_settings for update to authenticated
  using (public.has_perm(school_id, 'manage_settings')) with check (public.has_perm(school_id, 'manage_settings'));
grant insert, update on public.school_settings to authenticated;

-- counters: no client access at all
create policy counters_none on public.counters for select to authenticated using (false);

-- ---------------------------------------------------------------------
-- Academic sessions (read: any member; writes via RPC)
-- ---------------------------------------------------------------------
create policy sessions_read on public.academic_sessions for select to authenticated using (public.is_member(school_id));

-- ---------------------------------------------------------------------
-- Students & enrollments. Teachers (calling only) have no view_student_list,
-- therefore cannot read these tables directly; they use crm_* RPCs.
-- ---------------------------------------------------------------------
create policy students_read on public.students for select to authenticated using (public.has_perm(school_id, 'view_student_list'));
grant update (name, father_name, mother_name, gender, dob, admission_date, mobile, alt_mobile, whatsapp, address, village,
              district, parent_email, photo_path, remarks, admission_no) on public.students to authenticated;
create policy students_update on public.students for update to authenticated
  using (public.has_perm(school_id, 'edit_student')) with check (public.has_perm(school_id, 'edit_student'));

create policy enroll_read on public.student_session_enrollments for select to authenticated
  using (public.has_perm(school_id, 'view_student_list') or public.has_perm(school_id, 'view_fee_details'));

create policy families_read on public.families for select to authenticated using (public.has_perm(school_id, 'view_student_list'));
grant update (name, primary_mobile, notes, family_ref) on public.families to authenticated;
create policy families_update on public.families for update to authenticated
  using (public.has_perm(school_id, 'manage_families')) with check (public.has_perm(school_id, 'manage_families'));
create policy fmembers_read on public.family_members for select to authenticated using (public.has_perm(school_id, 'view_student_list'));
create policy fpolicies_read on public.family_policies for select to authenticated using (public.has_perm(school_id, 'view_fee_amounts'));

-- ---------------------------------------------------------------------
-- Fee configuration & money: view_fee_amounts is the gate
-- ---------------------------------------------------------------------
create policy feeheads_read on public.fee_heads for select to authenticated using (public.is_member(school_id));
create policy feeheads_ins on public.fee_heads for insert to authenticated with check (public.has_perm(school_id, 'edit_fee_structure'));
create policy feeheads_upd on public.fee_heads for update to authenticated
  using (public.has_perm(school_id, 'edit_fee_structure')) with check (public.has_perm(school_id, 'edit_fee_structure'));
grant insert, update on public.fee_heads to authenticated;

create policy feestruct_read on public.fee_structures for select to authenticated using (public.has_perm(school_id, 'view_fee_amounts'));
create policy feestruct_ins on public.fee_structures for insert to authenticated
  with check (public.has_perm(school_id, 'edit_fee_structure') and public.session_is_open(school_id, session_id));
create policy feestruct_upd on public.fee_structures for update to authenticated
  using (public.has_perm(school_id, 'edit_fee_structure') and public.session_is_open(school_id, session_id))
  with check (public.has_perm(school_id, 'edit_fee_structure') and public.session_is_open(school_id, session_id));
create policy feestruct_del on public.fee_structures for delete to authenticated
  using (public.has_perm(school_id, 'edit_fee_structure') and public.session_is_open(school_id, session_id));
grant insert, update, delete on public.fee_structures to authenticated;

create policy assign_read on public.student_fee_assignments for select to authenticated using (public.has_perm(school_id, 'view_fee_amounts'));
create policy install_read on public.fee_installments for select to authenticated using (public.has_perm(school_id, 'view_fee_amounts'));
create policy adjust_read on public.fee_adjustments for select to authenticated using (public.has_perm(school_id, 'view_fee_amounts'));
create policy discounts_read on public.student_discounts for select to authenticated using (public.has_perm(school_id, 'view_fee_amounts'));
create policy rte_read on public.rte_records for select to authenticated using (public.has_perm(school_id, 'manage_rte') or public.has_perm(school_id, 'view_fee_amounts'));
create policy rtereimb_read on public.rte_reimbursements for select to authenticated using (public.has_perm(school_id, 'manage_rte'));
create policy schol_read on public.scholarship_records for select to authenticated using (public.has_perm(school_id, 'manage_rte') or public.has_perm(school_id, 'view_fee_amounts'));

create policy payments_read on public.payments for select to authenticated using (public.has_perm(school_id, 'view_fee_amounts'));
create policy alloc_read on public.payment_allocations for select to authenticated using (public.has_perm(school_id, 'view_fee_amounts'));
create policy verif_read on public.payment_verifications for select to authenticated using (public.has_perm(school_id, 'view_fee_amounts'));
create policy receipts_read on public.receipts for select to authenticated using (public.has_perm(school_id, 'view_fee_amounts'));
create policy reversals_read on public.transaction_reversals for select to authenticated using (public.has_perm(school_id, 'view_fee_amounts'));

-- ---------------------------------------------------------------------
-- Calling CRM
-- ---------------------------------------------------------------------
create policy tasks_read on public.calling_tasks for select to authenticated
  using (public.has_perm(school_id, 'view_calling_crm')
         and (assigned_to = auth.uid() or auth.uid() = any(co_assignees) or public.has_perm(school_id, 'assign_calling_tasks') or public.has_perm(school_id, 'view_teacher_performance')));
create policy taskhist_read on public.task_assignment_history for select to authenticated
  using (public.has_perm(school_id, 'assign_calling_tasks') or public.has_perm(school_id, 'view_teacher_performance'));
create policy calllogs_read on public.calling_logs for select to authenticated
  using (public.has_perm(school_id, 'view_calling_crm')
         and (called_by = auth.uid() or public.has_perm(school_id, 'assign_calling_tasks')
              or public.has_perm(school_id, 'view_teacher_performance') or public.has_perm(school_id, 'view_student_list')));
-- promised_amount is financial: only view_fee_amounts may read the raw table; teachers use promises_list()
create policy promises_read on public.payment_promises for select to authenticated using (public.has_perm(school_id, 'view_fee_amounts'));
create policy followups_read on public.follow_up_tasks for select to authenticated
  using (public.has_perm(school_id, 'view_calling_crm')
         and (assigned_to = auth.uid() or public.has_perm(school_id, 'assign_calling_tasks') or public.has_perm(school_id, 'view_teacher_performance')));
create policy targets_read on public.teacher_calling_targets for select to authenticated
  using (teacher_id = auth.uid() or public.has_perm(school_id, 'assign_calling_tasks') or public.has_perm(school_id, 'view_teacher_performance'));

-- ---------------------------------------------------------------------
-- Notifications: strictly the recipient
-- ---------------------------------------------------------------------
create policy notif_read on public.notifications for select to authenticated using (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- Audit logs (read-only, permission gated; immutable via triggers)
-- ---------------------------------------------------------------------
create policy audit_read on public.audit_logs for select to authenticated
  using (public.is_super_admin() or (school_id is not null and public.has_perm(school_id, 'view_audit_logs')));

-- ---------------------------------------------------------------------
-- Import & attachments
-- ---------------------------------------------------------------------
create policy imports_read on public.import_batches for select to authenticated using (public.has_perm(school_id, 'import_students'));
create policy importerr_read on public.import_errors for select to authenticated using (public.has_perm(school_id, 'import_students'));
create policy attach_read on public.file_attachments for select to authenticated
  using (public.has_perm(school_id, 'view_student_list') or public.has_perm(school_id, 'view_fee_amounts'));

-- ---------------------------------------------------------------------
-- Function privileges: nothing is callable by anon; internal helpers are locked.
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f' loop
    execute format('revoke all on function %s from public, anon', f.sig);
    if f.proname in ('set_updated_at','audit_row','forbid_delete','forbid_update','payments_guard','check_allocation_total',
                     'students_before_write','handle_new_user','profile_guard','membership_guard') then
      execute format('revoke all on function %s from authenticated', f.sig);
    elsif f.proname not in ('next_counter','notify','notify_perm','notify_roles','audit_write','init_school_defaults',
                            '_make_installments','_assign_fees','_set_specific_fee','resolve_student_tasks','run_reminders') then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;
grant execute on function public.run_reminders(uuid) to service_role;

-- Public registration lookups (no private data): duplicate check only
create or replace function public.registration_conflicts(p_code text, p_email text, p_udise text default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'code',  exists (select 1 from public.school_registration_requests where lower(school_code) = lower(p_code) and status in ('pending','approved'))
             or exists (select 1 from public.schools where lower(school_code) = lower(p_code)),
    'email', exists (select 1 from public.school_registration_requests where lower(email) = lower(p_email) and status in ('pending','approved')),
    'udise', coalesce(nullif(p_udise,'') is not null and exists (select 1 from public.school_registration_requests where udise_code = p_udise and status in ('pending','approved')), false))
$$;
revoke all on function public.registration_conflicts(text, text, text) from public;
grant execute on function public.registration_conflicts(text, text, text) to anon, authenticated;
