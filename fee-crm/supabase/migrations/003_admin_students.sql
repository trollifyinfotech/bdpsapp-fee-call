-- =====================================================================
-- Migration 003 : Platform admin, users, sessions, students, families
-- All functions are SECURITY DEFINER and authorise from auth.uid();
-- school_id supplied by the client is never trusted.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Super Admin: registration review, school status, subscriptions
-- ---------------------------------------------------------------------
create or replace function public.sa_review_registration(
  p_request uuid, p_decision text, p_reason text default null,
  p_plan text default 'trial', p_expires date default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.school_registration_requests; sid uuid; pl public.subscription_plans;
begin
  if not public.is_super_admin() then raise exception 'Super Admin only' using errcode='42501'; end if;
  select * into r from public.school_registration_requests where id = p_request for update;
  if not found then raise exception 'Request not found'; end if;
  if r.status <> 'pending' then raise exception 'Request already %', r.status; end if;

  if p_decision = 'reject' then
    update public.school_registration_requests
       set status='rejected', reviewed_by=auth.uid(), reviewed_at=now(), reject_reason=p_reason where id=p_request;
    perform public.audit_write(null,'registration.rejected','school_registration_requests',p_request::text,null,
            jsonb_build_object('school',r.school_name),p_reason);
    return null;
  elsif p_decision <> 'approve' then
    raise exception 'Decision must be approve or reject';
  end if;

  if r.owner_user_id is null then raise exception 'Owner account missing for this request'; end if;
  insert into public.schools (school_code, name, udise_code, address, state, district, city, owner_name,
                              mobile, email, logo_path, status, approved_at, approved_by)
  values (r.school_code, r.school_name, nullif(r.udise_code,''), r.address, r.state, r.district, r.city,
          r.owner_name, r.mobile, r.email, r.logo_path, 'active', now(), auth.uid())
  returning id into sid;

  insert into public.school_memberships (school_id, user_id, role_code, created_by)
  values (sid, r.owner_user_id, 'school_owner', auth.uid());

  select * into pl from public.subscription_plans where code = p_plan;
  if not found then select * into pl from public.subscription_plans where code = 'trial'; end if;
  insert into public.school_subscriptions (school_id, plan_code, max_students, max_users, expires_on)
  values (sid, pl.code, pl.max_students, pl.max_users, coalesce(p_expires, current_date + 30));

  perform public.init_school_defaults(sid);

  update public.school_registration_requests
     set status='approved', reviewed_by=auth.uid(), reviewed_at=now(), school_id=sid where id=p_request;
  perform public.notify(sid, r.owner_user_id, 'school_approved', 'School approved',
         'Your school account is active. You can now sign in and set up sessions, staff and fees.', '/app.html');
  return sid;
end $$;

-- default fee heads + settings for a new school (no demo data)
create or replace function public.init_school_defaults(sid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.fee_heads (school_id, name)
  select sid, n from unnest(array['Admission Fee','Tuition Fee','Development Fee','Examination Fee','Annual Charges',
    'Computer Fee','Transport Fee','Library Fee','Sports Fee','Other Charges','Previous Dues']) n
  on conflict do nothing;
  insert into public.school_settings (school_id, key, value) values
   (sid,'verification_rules','{"cash":false,"upi":true,"bank_transfer":true,"cheque":true,"card":false,"other":true}'),
   (sid,'allow_advance_payment','false'),
   (sid,'default_due_days','30'),
   (sid,'crm','{"no_recent_call_days":7,"max_reminders":3,"escalate_principal_after_days":3,"escalate_owner_after_days":7,"followup_interval_days":3,"default_daily_target":20}'),
   (sid,'receipt','{"footer":"This is a computer generated receipt.","phone":""}')
  on conflict do nothing;
end $$;
revoke all on function public.init_school_defaults(uuid) from public, anon, authenticated;

create or replace function public.sa_set_school_status(p_school uuid, p_status text, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_super_admin() then raise exception 'Super Admin only' using errcode='42501'; end if;
  if p_status not in ('active','suspended','inactive') then raise exception 'Invalid status'; end if;
  perform set_config('app.audit_reason', coalesce(p_reason,''), true);
  update public.schools set status = p_status where id = p_school;
end $$;

create or replace function public.sa_set_subscription(p_school uuid, p_plan text, p_max_students int,
                                                      p_max_users int, p_expires date)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_super_admin() then raise exception 'Super Admin only' using errcode='42501'; end if;
  update public.school_subscriptions set status='cancelled' where school_id=p_school and status='active';
  insert into public.school_subscriptions (school_id, plan_code, max_students, max_users, expires_on)
  values (p_school, nullif(p_plan,''), p_max_students, p_max_users, p_expires);
end $$;

create or replace function public.sa_record_payment(p_school uuid, p_amount numeric, p_paid_on date,
                                                    p_mode text, p_reference text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_super_admin() then raise exception 'Super Admin only' using errcode='42501'; end if;
  insert into public.platform_payments (school_id, amount, paid_on, mode, reference, note, recorded_by)
  values (p_school, p_amount, coalesce(p_paid_on, current_date), p_mode, p_reference, p_note, auth.uid());
end $$;

create or replace function public.platform_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_super_admin() then raise exception 'Super Admin only' using errcode='42501'; end if;
  return jsonb_build_object(
    'total_schools',   (select count(*) from public.schools),
    'active_schools',  (select count(*) from public.schools where status='active'),
    'pending_schools', (select count(*) from public.school_registration_requests where status='pending'),
    'total_students',  (select count(*) from public.students where status='active'),
    'total_teachers',  (select count(*) from public.school_memberships where role_code='teacher' and is_active),
    'total_transactions', (select count(*) from public.payments where status='verified'),
    'total_collection',   (select coalesce(sum(amount),0) from public.payments where status='verified'));
end $$;

create or replace function public.sa_school_stats() returns table(
  school_id uuid, name text, school_code text, status text, is_demo boolean, created_at timestamptz,
  students bigint, users bigint, transactions bigint, collection numeric,
  plan_code text, max_students int, max_users int, expires_on date)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_super_admin() then raise exception 'Super Admin only' using errcode='42501'; end if;
  return query
   select s.id, s.name, s.school_code, s.status, s.is_demo, s.created_at,
     (select count(*) from public.students st where st.school_id=s.id and st.status='active'),
     (select count(*) from public.school_memberships m where m.school_id=s.id and m.is_active),
     (select count(*) from public.payments p where p.school_id=s.id and p.status='verified'),
     (select coalesce(sum(p.amount),0) from public.payments p where p.school_id=s.id and p.status='verified'),
     ss.plan_code, ss.max_students, ss.max_users, ss.expires_on
   from public.schools s
   left join public.school_subscriptions ss on ss.school_id=s.id and ss.status='active'
   order by s.created_at desc;
end $$;

create or replace function public.sa_list_users() returns table(
  user_id uuid, full_name text, email text, school_id uuid, school_name text, role_code text, is_active boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_super_admin() then raise exception 'Super Admin only' using errcode='42501'; end if;
  return query select m.user_id, p.full_name, p.email, m.school_id, s.name, m.role_code, m.is_active
    from public.school_memberships m join public.user_profiles p on p.id=m.user_id
    join public.schools s on s.id=m.school_id order by s.name, m.role_code;
end $$;

-- ---------------------------------------------------------------------
-- School users & permissions
-- ---------------------------------------------------------------------
create or replace function public.list_school_users() returns table(
  user_id uuid, full_name text, email text, mobile text, role_code text, designation text,
  is_active boolean, overrides int)
language plpgsql stable security definer set search_path = public as $$
declare sid uuid := public.my_school_id();
begin
  if sid is null or not (public.has_perm(sid,'manage_users') or public.has_perm(sid,'assign_calling_tasks')
        or public.has_perm(sid,'view_teacher_performance') or public.has_perm(sid,'manage_permissions')) then
    raise exception 'Permission denied' using errcode='42501';
  end if;
  return query select m.user_id, p.full_name, p.email, p.mobile, m.role_code, m.designation, m.is_active,
     (select count(*)::int from public.user_permissions up where up.school_id=sid and up.user_id=m.user_id)
    from public.school_memberships m join public.user_profiles p on p.id=m.user_id
    where m.school_id=sid order by m.role_code, p.full_name;
end $$;

create or replace function public.set_member_role(p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = public as $$
declare sid uuid := public.my_school_id(); myrole text; target text;
begin
  perform public.require_perm(sid,'manage_users');
  if p_user = auth.uid() then raise exception 'You cannot change your own role' using errcode='42501'; end if;
  if p_role in ('super_admin') or not exists (select 1 from public.roles where code=p_role) then
    raise exception 'Invalid role'; end if;
  myrole := public.my_role(sid);
  select role_code into target from public.school_memberships where school_id=sid and user_id=p_user;
  if target is null then raise exception 'User is not in your school'; end if;
  if (p_role in ('school_owner','principal') or target in ('school_owner')) and myrole <> 'school_owner' then
    raise exception 'Only the School Owner can assign or modify Owner/Principal roles' using errcode='42501';
  end if;
  update public.school_memberships set role_code=p_role where school_id=sid and user_id=p_user;
end $$;

create or replace function public.set_user_permission(p_user uuid, p_perm text, p_granted boolean) returns void
language plpgsql security definer set search_path = public as $$
declare sid uuid := public.my_school_id();
begin
  perform public.require_perm(sid,'manage_permissions');
  if p_user = auth.uid() then raise exception 'You cannot change your own permissions' using errcode='42501'; end if;
  if not exists (select 1 from public.school_memberships where school_id=sid and user_id=p_user) then
    raise exception 'User is not in your school'; end if;
  if (select role_code from public.school_memberships where school_id=sid and user_id=p_user) = 'school_owner'
     and public.my_role(sid) <> 'school_owner' then
    raise exception 'Only the Owner can change Owner permissions' using errcode='42501'; end if;
  if p_granted is null then
    delete from public.user_permissions where school_id=sid and user_id=p_user and permission_code=p_perm;
  else
    insert into public.user_permissions (school_id,user_id,permission_code,granted,granted_by)
    values (sid,p_user,p_perm,p_granted,auth.uid())
    on conflict (school_id,user_id,permission_code) do update set granted=excluded.granted, granted_by=auth.uid();
  end if;
end $$;

create or replace function public.my_access() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare sid uuid := public.my_school_id(); res jsonb;
begin
  select jsonb_build_object(
    'user_id', auth.uid(),
    'is_super_admin', public.is_super_admin(),
    'school_id', sid,
    'role', case when sid is null then null else public.my_role(sid) end,
    'school', (select to_jsonb(s) - 'approved_by' from public.schools s where s.id = sid),
    'permissions', coalesce((select jsonb_agg(p.code) from public.permissions p
                     where sid is not null and public.has_perm(sid, p.code)), '[]'::jsonb),
    'pending_registration', (select jsonb_build_object('status', r.status, 'school_name', r.school_name, 'reason', r.reject_reason)
                     from public.school_registration_requests r where r.owner_user_id = auth.uid()
                     order by r.created_at desc limit 1)
  ) into res;
  return res;
end $$;

-- ---------------------------------------------------------------------
-- Academic sessions
-- ---------------------------------------------------------------------
create or replace function public.create_session(p_name text, p_start date, p_end date, p_make_active boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid := public.my_school_id(); id uuid;
begin
  perform public.require_perm(sid,'manage_sessions');
  insert into public.academic_sessions (school_id,name,start_date,end_date,created_by)
  values (sid, trim(p_name), p_start, p_end, auth.uid()) returning academic_sessions.id into id;
  if p_make_active then perform public.set_active_session(id); end if;
  return id;
end $$;

create or replace function public.set_active_session(p_session uuid) returns void
language plpgsql security definer set search_path = public as $$
declare sid uuid; st text;
begin
  select school_id, status into sid, st from public.academic_sessions where id = p_session;
  perform public.require_perm(sid,'manage_sessions');
  if st <> 'open' then raise exception 'A closed session cannot be made active. Re-open it first.'; end if;
  update public.academic_sessions set is_active=false where school_id=sid and is_active and id<>p_session;
  update public.academic_sessions set is_active=true where id=p_session;
end $$;

create or replace function public.close_session(p_session uuid) returns void
language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select school_id into sid from public.academic_sessions where id = p_session;
  perform public.require_perm(sid,'manage_sessions');
  update public.academic_sessions set status='closed', is_active=false where id=p_session;
end $$;

create or replace function public.reopen_session(p_session uuid) returns void
language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select school_id into sid from public.academic_sessions where id = p_session;
  perform public.require_perm(sid,'manage_sessions');
  update public.academic_sessions set status='open' where id=p_session;
end $$;

create or replace function public.next_class(c text) returns text language sql immutable as $$
  select case c
    when 'Nursery' then 'LKG' when 'LKG' then 'UKG' when 'UKG' then 'Class 1'
    when 'Class 12' then null
    else case when c ~ '^Class \d+$' then 'Class ' || ((regexp_replace(c,'\D','','g'))::int + 1) end end;
$$;

create or replace function public.normalize_class(c text) returns text
language plpgsql immutable as $$
declare x text := lower(trim(coalesce(c,''))); n text;
begin
  if x in ('nursery','nur') then return 'Nursery'; end if;
  if x = 'lkg' then return 'LKG'; end if;
  if x = 'ukg' then return 'UKG'; end if;
  n := regexp_replace(x, '[^0-9]', '', 'g');
  if n <> '' and n::int between 1 and 12 then return 'Class ' || n::int; end if;
  return null;
end $$;

-- Promote / copy students into a new session. Identity is reused (no duplicates).
create or replace function public.promote_students(
  p_from uuid, p_to uuid, p_student_ids uuid[] default null,
  p_class_overrides jsonb default '{}'::jsonb, p_assign_fees boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare sid uuid; sid2 uuid; e record; nc text; created int := 0; skipped int := 0; finished int := 0; new_id uuid;
begin
  select school_id into sid from public.academic_sessions where id = p_from;
  select school_id into sid2 from public.academic_sessions where id = p_to;
  if sid is null or sid <> sid2 then raise exception 'Sessions must belong to your school'; end if;
  perform public.require_perm(sid,'manage_sessions');
  perform public.require_perm(sid,'edit_student');
  if not public.session_is_open(sid, p_to) then raise exception 'Target session is closed'; end if;
  for e in select en.* from public.student_session_enrollments en join public.students s on s.id=en.student_id
           where en.session_id=p_from and en.status='active' and s.status='active'
             and (p_student_ids is null or en.student_id = any(p_student_ids)) loop
    if exists (select 1 from public.student_session_enrollments where session_id=p_to and student_id=e.student_id) then
      skipped := skipped + 1; continue; end if;
    nc := coalesce(nullif(p_class_overrides->>(e.student_id::text),''), public.next_class(e.class_name));
    if nc is null then finished := finished + 1; continue; end if;
    insert into public.student_session_enrollments (school_id,session_id,student_id,class_name,section,roll_no,category,custom_category,created_by)
    values (sid,p_to,e.student_id,nc,e.section,null,e.category,e.custom_category,auth.uid()) returning id into new_id;
    update public.student_session_enrollments set status='promoted' where id=e.id;
    if p_assign_fees then perform public._assign_fees(sid, p_to, new_id); end if;
    created := created + 1;
  end loop;
  return jsonb_build_object('created',created,'skipped_existing',skipped,'no_next_class',finished);
end $$;

create or replace function public.session_compare(p_a uuid, p_b uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare sid uuid; res jsonb := '[]'::jsonb; x uuid;
begin
  select school_id into sid from public.academic_sessions where id = p_a;
  perform public.require_perm(sid,'view_financial_dashboard');
  if not exists (select 1 from public.academic_sessions where id=p_b and school_id=sid) then
    raise exception 'Sessions must belong to your school'; end if;
  foreach x in array array[p_a,p_b] loop
    res := res || jsonb_build_array((select jsonb_build_object(
      'session', (select name from public.academic_sessions where id=x),
      'students', count(*), 'gross', coalesce(sum(gross),0), 'discount', coalesce(sum(discount),0),
      'net', coalesce(sum(net),0), 'collected', coalesce(sum(paid),0), 'pending', coalesce(sum(pending),0))
      from public.v_enrollment_balances where session_id = x));
  end loop;
  return res;
end $$;

-- ---------------------------------------------------------------------
-- Students
-- ---------------------------------------------------------------------
create or replace function public.add_student(p_data jsonb, p_session uuid, p_class text, p_section text default null,
  p_roll text default null, p_category text default 'general', p_annual_fee numeric default null,
  p_family uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid; stid uuid; enr uuid; cls text := public.normalize_class(p_class);
begin
  select school_id into sid from public.academic_sessions where id = p_session;
  perform public.require_perm(sid,'add_student');
  if cls is null then raise exception 'Invalid class'; end if;
  if not public.session_is_open(sid,p_session) then raise exception 'Session is closed'; end if;
  insert into public.students (school_id, admission_no, name, father_name, mother_name, gender, dob, admission_date,
     mobile, alt_mobile, whatsapp, address, village, district, parent_email, remarks)
  values (sid, trim(p_data->>'admission_no'), trim(p_data->>'name'), p_data->>'father_name', p_data->>'mother_name',
     nullif(p_data->>'gender',''), nullif(p_data->>'dob','')::date, coalesce(nullif(p_data->>'admission_date','')::date, current_date),
     p_data->>'mobile', p_data->>'alt_mobile', p_data->>'whatsapp', p_data->>'address', p_data->>'village',
     p_data->>'district', p_data->>'parent_email', p_data->>'remarks')
  returning id into stid;
  insert into public.student_session_enrollments (school_id,session_id,student_id,class_name,section,roll_no,category,created_by)
  values (sid,p_session,stid,cls,nullif(p_section,''),nullif(p_roll,''),coalesce(p_category,'general'),auth.uid())
  returning id into enr;
  if p_category = 'rte' then
    insert into public.rte_records (school_id,student_id,session_id,created_by) values (sid,stid,p_session,auth.uid())
    on conflict do nothing;
  end if;
  if p_annual_fee is not null and p_category <> 'rte' then
    perform public._set_specific_fee(sid,p_session,enr,'Annual Fee',p_annual_fee,'Set at admission');
  else
    perform public._assign_fees(sid,p_session,enr);
  end if;
  if p_family is not null then
    perform public.link_student_family(p_family, stid, 'sibling');
  end if;
  perform public.notify_roles(sid, array['school_owner','principal'], 'new_student', 'New student added',
      trim(p_data->>'name') || ' admitted to ' || cls, '/app.html#/students');
  return stid;
end $$;

create or replace function public.change_class(p_enrollment uuid, p_class text, p_section text default null,
  p_roll text default null, p_category text default null, p_reassign_fees boolean default true)
returns void language plpgsql security definer set search_path = public as $$
declare e public.student_session_enrollments; cls text := public.normalize_class(p_class); a record;
begin
  select * into e from public.student_session_enrollments where id = p_enrollment;
  if not found then raise exception 'Enrollment not found'; end if;
  perform public.require_perm(e.school_id,'edit_student');
  if cls is null then raise exception 'Invalid class'; end if;
  if (cls <> e.class_name or coalesce(p_category,e.category) <> e.category) and p_reassign_fees then
    perform public.require_perm(e.school_id,'edit_fee_structure');
    -- cancel structure-based fee lines that have no money against them; keep the rest untouched
    for a in select sfa.id from public.student_fee_assignments sfa
             where sfa.enrollment_id=e.id and sfa.status='active' and sfa.source='structure'
               and not exists (select 1 from public.payment_allocations pa join public.payments py on py.id=pa.payment_id
                               where pa.assignment_id=sfa.id and py.status in ('verified','pending')) loop
      update public.student_fee_assignments set status='cancelled', reason='Class/category changed' where id=a.id;
    end loop;
  end if;
  update public.student_session_enrollments
     set class_name=cls, section=nullif(p_section,''), roll_no=nullif(p_roll,''),
         category=coalesce(p_category,category)
   where id = p_enrollment;
  if (cls <> e.class_name or coalesce(p_category,e.category) <> e.category) and p_reassign_fees then
    perform public._assign_fees(e.school_id, e.session_id, e.id);
  end if;
end $$;

create or replace function public.archive_student(p_student uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select school_id into sid from public.students where id = p_student;
  perform public.require_perm(sid,'archive_student');
  if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Reason is required'; end if;
  perform set_config('app.audit_reason', p_reason, true);
  update public.students set status='archived' where id=p_student;
  update public.calling_tasks set status='cancelled' where student_id=p_student and status in ('pending','in_progress','promised');
end $$;

create or replace function public.restore_student(p_student uuid) returns void
language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select school_id into sid from public.students where id = p_student;
  perform public.require_perm(sid,'archive_student');
  update public.students set status='active' where id=p_student;
end $$;

-- ---------------------------------------------------------------------
-- Families / siblings (admin must confirm; no automatic sibling assumption)
-- ---------------------------------------------------------------------
create or replace function public.create_family(p_name text, p_mobile text, p_notes text, p_student_ids uuid[] default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid := public.my_school_id(); fid uuid; s uuid;
begin
  perform public.require_perm(sid,'manage_families');
  insert into public.families (school_id,name,primary_mobile,notes,created_by)
  values (sid,trim(p_name),p_mobile,p_notes,auth.uid()) returning id into fid;
  foreach s in array coalesce(p_student_ids,'{}') loop
    perform public.link_student_family(fid, s, 'sibling');
  end loop;
  return fid;
end $$;

create or replace function public.link_student_family(p_family uuid, p_student uuid, p_rel text default 'sibling')
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select school_id into sid from public.families where id = p_family;
  perform public.require_perm(sid,'manage_families');
  if not exists (select 1 from public.students where id=p_student and school_id=sid) then
    raise exception 'Student not found in your school'; end if;
  if exists (select 1 from public.family_members where student_id=p_student and removed_at is null) then
    raise exception 'Student already belongs to a family. Remove the existing link first.'; end if;
  insert into public.family_members (school_id,family_id,student_id,relationship,verified,verified_by,verified_at,created_by)
  values (sid,p_family,p_student,coalesce(p_rel,'sibling'),true,auth.uid(),now(),auth.uid());
end $$;

create or replace function public.verify_family_member(p_member uuid) returns void
language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select school_id into sid from public.family_members where id = p_member;
  perform public.require_perm(sid,'manage_families');
  update public.family_members set verified=true, verified_by=auth.uid(), verified_at=now() where id=p_member;
end $$;

create or replace function public.remove_family_member(p_member uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select school_id into sid from public.family_members where id = p_member;
  perform public.require_perm(sid,'manage_families');
  if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Reason is required'; end if;
  update public.family_members set removed_at=now(), removed_by=auth.uid(), removed_reason=p_reason
   where id=p_member and removed_at is null;
end $$;

-- Candidate siblings (shared mobile or same father+mobile). SUGGESTIONS ONLY.
create or replace function public.suggest_siblings() returns table(
  student_a uuid, name_a text, student_b uuid, name_b text, reason text)
language plpgsql stable security definer set search_path = public as $$
declare sid uuid := public.my_school_id();
begin
  perform public.require_perm(sid,'manage_families');
  return query
   select a.id, a.name, b.id, b.name,
          case when lower(coalesce(a.father_name,''))=lower(coalesce(b.father_name,'')) and coalesce(a.father_name,'')<>''
               then 'Same father name & mobile' else 'Same mobile number' end
   from public.students a join public.students b
     on a.school_id=b.school_id and a.id<b.id and a.mobile is not null and a.mobile=b.mobile
   where a.school_id=sid and a.status='active' and b.status='active'
     and not exists (select 1 from public.family_members fa join public.family_members fb on fa.family_id=fb.family_id
                     where fa.student_id=a.id and fb.student_id=b.id and fa.removed_at is null and fb.removed_at is null)
   limit 200;
end $$;

-- ---------------------------------------------------------------------
-- Discounts / family concessions (recorded separately for each student)
-- ---------------------------------------------------------------------
create or replace function public.apply_discount(p_enrollment uuid, p_type text, p_value numeric, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare e public.student_session_enrollments; id uuid; g numeric;
begin
  select * into e from public.student_session_enrollments where id = p_enrollment;
  if not found then raise exception 'Enrollment not found'; end if;
  perform public.require_perm(e.school_id,'apply_discount');
  if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Reason is required for every concession'; end if;
  select coalesce(sum(amount),0) into g from public.student_fee_assignments where enrollment_id=e.id and status='active';
  if p_type = 'fixed' and (p_value is null or p_value <= 0 or p_value > g) then
    raise exception 'Fixed discount must be between 1 and the gross fee (%)', g; end if;
  if p_type = 'percentage' and (p_value is null or p_value <= 0 or p_value > 100) then
    raise exception 'Percentage must be between 1 and 100'; end if;
  insert into public.student_discounts (school_id,session_id,enrollment_id,student_id,discount_type,value,reason,approved_by)
  values (e.school_id,e.session_id,e.id,e.student_id,p_type,case when p_type='full_waiver' then 100 else p_value end,p_reason,auth.uid())
  returning student_discounts.id into id;
  return id;
end $$;

create or replace function public.revoke_discount(p_discount uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select school_id into sid from public.student_discounts where id = p_discount;
  perform public.require_perm(sid,'apply_discount');
  if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Reason required'; end if;
  update public.student_discounts set status='revoked', revoked_by=auth.uid(), revoked_reason=p_reason, revoked_at=now()
   where id=p_discount and status='active';
end $$;

create or replace function public.apply_family_policy(
  p_family uuid, p_session uuid, p_policy text, p_payer uuid default null,
  p_value numeric default 0, p_reason text default null, p_selected uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare sid uuid; pol uuid; m record; payer uuid := p_payer; n int := 0; dtype text; dval numeric;
begin
  select school_id into sid from public.families where id = p_family;
  perform public.require_perm(sid,'apply_discount');
  if not exists (select 1 from public.academic_sessions where id=p_session and school_id=sid) then
    raise exception 'Session not in your school'; end if;
  if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Reason is required'; end if;
  if p_policy not in ('first_pays_rest_free','first_pays_rest_percent','selected_free','fixed_each','percent_each','custom') then
    raise exception 'Unknown policy'; end if;
  if payer is null then
    select fm.student_id into payer from public.family_members fm join public.students s on s.id=fm.student_id
     join public.student_session_enrollments e on e.student_id=s.id and e.session_id=p_session
     where fm.family_id=p_family and fm.removed_at is null and fm.verified
     order by s.admission_date nulls last, s.created_at limit 1;
  end if;
  -- revoke any previous active policy discounts for this family+session
  update public.student_discounts set status='revoked', revoked_by=auth.uid(), revoked_at=now(),
         revoked_reason='Superseded by new family policy'
   where family_id=p_family and session_id=p_session and status='active';
  update public.family_policies set status='revoked' where family_id=p_family and session_id=p_session and status='active';
  insert into public.family_policies (school_id,family_id,session_id,policy_type,payer_student_id,value,reason,approved_by)
  values (sid,p_family,p_session,p_policy,payer,coalesce(p_value,0),p_reason,auth.uid()) returning id into pol;

  for m in select fm.student_id, e.id as enr from public.family_members fm
           join public.student_session_enrollments e on e.student_id=fm.student_id and e.session_id=p_session
           where fm.family_id=p_family and fm.removed_at is null and fm.verified loop
    dtype := null;
    if p_policy = 'first_pays_rest_free' and m.student_id <> payer then dtype := 'full_waiver'; dval := 100;
    elsif p_policy = 'first_pays_rest_percent' and m.student_id <> payer then dtype := 'percentage'; dval := p_value;
    elsif p_policy = 'percent_each' and m.student_id <> payer then dtype := 'percentage'; dval := p_value;
    elsif p_policy = 'fixed_each' and m.student_id <> payer then dtype := 'fixed'; dval := p_value;
    elsif p_policy = 'selected_free' and m.student_id = any(p_selected) then dtype := 'full_waiver'; dval := 100;
    elsif p_policy = 'custom' and m.student_id = any(p_selected) then dtype := 'fixed'; dval := p_value;
    end if;
    if dtype is not null then
      insert into public.student_discounts (school_id,session_id,enrollment_id,student_id,family_id,policy_id,
                                            discount_type,value,reason,approved_by)
      values (sid,p_session,m.enr,m.student_id,p_family,pol,dtype,dval,p_reason,auth.uid());
      n := n + 1;
    end if;
  end loop;
  return jsonb_build_object('policy_id',pol,'payer',payer,'discounts_created',n);
end $$;

-- ---------------------------------------------------------------------
-- RTE & scholarships
-- ---------------------------------------------------------------------
create or replace function public.save_rte(p_student uuid, p_session uuid, p_cert text, p_from date, p_to date,
  p_expected numeric, p_remarks text, p_doc text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid; id uuid; enr uuid;
begin
  select school_id into sid from public.students where id = p_student;
  perform public.require_perm(sid,'manage_rte');
  insert into public.rte_records (school_id,student_id,session_id,certificate_no,valid_from,valid_to,reimbursement_expected,remarks,document_path,created_by)
  values (sid,p_student,p_session,p_cert,p_from,p_to,coalesce(p_expected,0),p_remarks,p_doc,auth.uid())
  on conflict (student_id,session_id) do update set certificate_no=excluded.certificate_no, valid_from=excluded.valid_from,
     valid_to=excluded.valid_to, reimbursement_expected=excluded.reimbursement_expected, remarks=excluded.remarks,
     document_path=coalesce(excluded.document_path, public.rte_records.document_path)
  returning rte_records.id into id;
  -- RTE category => parent fee zero (no structure-based assignments, unless category-specific structure exists)
  select e.id into enr from public.student_session_enrollments e where e.student_id=p_student and e.session_id=p_session;
  if enr is not null then
    update public.student_session_enrollments set category='rte' where id=enr and category <> 'rte';
    update public.student_fee_assignments set status='cancelled', reason='RTE: parent fee waived'
     where enrollment_id=enr and status='active' and source='structure'
       and not exists (select 1 from public.payment_allocations pa join public.payments py on py.id=pa.payment_id
                       where pa.assignment_id=student_fee_assignments.id and py.status in ('verified','pending'));
  end if;
  return id;
end $$;

create or replace function public.record_rte_reimbursement(p_rte uuid, p_amount numeric, p_date date, p_ref text)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select school_id into sid from public.rte_records where id = p_rte;
  perform public.require_perm(sid,'manage_rte');
  insert into public.rte_reimbursements (school_id,rte_record_id,amount,received_on,reference,recorded_by)
  values (sid,p_rte,p_amount,p_date,p_ref,auth.uid());
end $$;

create or replace function public.save_scholarship(p_student uuid, p_session uuid, p_name text, p_amount numeric,
  p_percentage numeric, p_remarks text, p_doc text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid; id uuid;
begin
  select school_id into sid from public.students where id = p_student;
  perform public.require_perm(sid,'manage_rte');
  insert into public.scholarship_records (school_id,student_id,session_id,name,amount,percentage,remarks,document_path,created_by)
  values (sid,p_student,p_session,p_name,p_amount,p_percentage,p_remarks,p_doc,auth.uid()) returning scholarship_records.id into id;
  return id;
end $$;

-- Approving a scholarship creates a recorded discount (so balances reflect it).
create or replace function public.review_scholarship(p_id uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare s public.scholarship_records; enr uuid;
begin
  select * into s from public.scholarship_records where id = p_id for update;
  perform public.require_perm(s.school_id,'apply_discount');
  if s.approval_status <> 'pending' then raise exception 'Already reviewed'; end if;
  update public.scholarship_records set approval_status = case when p_approve then 'approved' else 'rejected' end,
         approved_by = auth.uid() where id = p_id;
  if p_approve then
    select e.id into enr from public.student_session_enrollments e where e.student_id=s.student_id and e.session_id=s.session_id;
    if enr is null then raise exception 'Student is not enrolled in that session'; end if;
    insert into public.student_discounts (school_id,session_id,enrollment_id,student_id,scholarship_id,discount_type,value,reason,approved_by)
    values (s.school_id,s.session_id,enr,s.student_id,s.id,
            case when s.percentage is not null then 'percentage' else 'fixed' end,
            coalesce(s.percentage, s.amount), 'Scholarship: ' || s.name, auth.uid());
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Bulk import (idempotent: re-uploading the same file never duplicates)
-- ---------------------------------------------------------------------
create or replace function public.start_import(p_session uuid, p_filename text, p_file_hash text, p_total int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare sid uuid; b uuid; prev record;
begin
  select school_id into sid from public.academic_sessions where id = p_session;
  perform public.require_perm(sid,'import_students');
  select id, created_at, imported into prev from public.import_batches
    where school_id=sid and file_hash=p_file_hash and session_id=p_session and status='completed' order by created_at desc limit 1;
  insert into public.import_batches (school_id,session_id,filename,file_hash,total_rows,created_by)
  values (sid,p_session,p_filename,p_file_hash,p_total,auth.uid()) returning id into b;
  return jsonb_build_object('batch_id',b,'previous_import_at',prev.created_at);
end $$;

create or replace function public.import_students_batch(p_batch uuid, p_rows jsonb, p_allow_possible_dups boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  b public.import_batches; r jsonb; idx int; errs text[]; ok int := 0; sk int := 0; bad int := 0;
  adm text; nm text; cls text; mob text; fee numeric; adate date; ex public.students; stid uuid; enr uuid;
  rte boolean; fam text; fid uuid; kind text; rowno int;
begin
  select * into b from public.import_batches where id = p_batch and created_by = auth.uid();
  if not found then raise exception 'Import batch not found'; end if;
  perform public.require_perm(b.school_id,'import_students');
  if not public.session_is_open(b.school_id, b.session_id) then raise exception 'Session is closed'; end if;

  for r, idx in select e.value, e.ordinality::int from jsonb_array_elements(p_rows) with ordinality e(value, ordinality) loop
    errs := '{}'; kind := 'error'; rowno := coalesce((r->>'_row')::int, idx);
    stid := null; ex := null; fid := null;
    begin
      adm := trim(coalesce(r->>'admission_no','')); nm := trim(coalesce(r->>'name',''));
      cls := public.normalize_class(r->>'class_name');
      mob := regexp_replace(coalesce(r->>'mobile',''), '[^0-9]', '', 'g');
      if length(mob) = 12 and left(mob,2) = '91' then mob := right(mob,10); end if;
      if length(mob) = 11 and left(mob,1) = '0' then mob := right(mob,10); end if;
      rte := lower(coalesce(r->>'rte_status','')) in ('yes','y','true','1','rte');
      fam := nullif(trim(coalesce(r->>'family_ref','')),'');
      fee := null; adate := null;
      if nm = '' then errs := array_append(errs, 'Student Name is required'); end if;
      if adm = '' then errs := array_append(errs, 'Admission No is required'); end if;
      if cls is null then errs := array_append(errs, ('Invalid class: ' || coalesce(r->>'class_name','(blank)'))); end if;
      if mob <> '' and mob !~ '^[6-9][0-9]{9}$' then errs := array_append(errs, 'Invalid mobile number (need 10-digit Indian mobile)'); end if;
      if mob = '' then errs := array_append(errs, 'Parent mobile is required for calling'); end if;
      if coalesce(r->>'annual_fee','') <> '' then
        begin fee := (regexp_replace(r->>'annual_fee','[^0-9.]','','g'))::numeric;
        exception when others then errs := array_append(errs, 'Invalid annual fee'); end;
        if fee is not null and fee < 0 then errs := array_append(errs, 'Annual fee cannot be negative'); end if;
      end if;
      if coalesce(r->>'admission_date','') <> '' then
        begin adate := (r->>'admission_date')::date; exception when others then errs := array_append(errs, 'Invalid admission date (use YYYY-MM-DD)'); end;
      end if;

      if cardinality(errs) = 0 then
        select * into ex from public.students where school_id=b.school_id and admission_no=adm;
        if found then
          if lower(ex.name) <> lower(nm) then
            errs := array_append(errs, ('Admission No already used by a different student (' || ex.name || ')'));
          elsif ex.status = 'archived' then
            errs := array_append(errs, 'An ARCHIVED student with this admission no exists. Delete it permanently (Students > Archived) or restore it, then import again'); kind := 'duplicate';
          elsif exists (select 1 from public.student_session_enrollments where student_id=ex.id and session_id=b.session_id) then
            errs := array_append(errs, 'Already imported (same admission no & session) - skipped'); kind := 'duplicate';
          else
            stid := ex.id;  -- existing student continuing in this session
          end if;
        elsif not p_allow_possible_dups and exists (
            select 1 from public.students s where s.school_id=b.school_id and lower(s.name)=lower(nm)
              and lower(coalesce(s.father_name,''))=lower(coalesce(r->>'father_name','')) and s.mobile = mob) then
          errs := array_append(errs, 'Possible duplicate: same name, father and mobile exists with different admission no'); kind := 'duplicate';
        end if;
      end if;

      if cardinality(errs) > 0 then
        insert into public.import_errors (school_id,batch_id,row_no,raw,errors,kind) values (b.school_id,p_batch,rowno,r,errs,kind);
        if kind = 'duplicate' then sk := sk + 1; else bad := bad + 1; end if;
        continue;
      end if;

      if stid is null or (ex.id is null) then
        insert into public.students (school_id,admission_no,name,father_name,mother_name,gender,admission_date,mobile,address,created_by)
        values (b.school_id,adm,nm,r->>'father_name',r->>'mother_name',nullif(lower(r->>'gender'),''),
                coalesce(adate,current_date),mob,r->>'address',auth.uid()) returning id into stid;
      end if;
      insert into public.student_session_enrollments (school_id,session_id,student_id,class_name,section,roll_no,category,created_by)
      values (b.school_id,b.session_id,stid,cls,nullif(r->>'section',''),nullif(r->>'roll_no',''),
              case when rte then 'rte' else 'general' end, auth.uid()) returning id into enr;
      if rte then
        insert into public.rte_records (school_id,student_id,session_id,created_by) values (b.school_id,stid,b.session_id,auth.uid())
        on conflict do nothing;
      elsif fee is not null then
        perform public._set_specific_fee(b.school_id,b.session_id,enr,'Annual Fee',fee,'Imported');
      else
        perform public._assign_fees(b.school_id,b.session_id,enr);
      end if;
      if fam is not null then
        select id into fid from public.families where school_id=b.school_id and lower(family_ref)=lower(fam);
        if fid is null then
          insert into public.families (school_id,family_ref,name,primary_mobile,created_by)
          values (b.school_id,fam,coalesce(nullif(r->>'father_name',''),nm) || ' Family',mob,auth.uid()) returning id into fid;
        end if;
        if not exists (select 1 from public.family_members where student_id=stid and removed_at is null) then
          insert into public.family_members (school_id,family_id,student_id,verified,created_by)
          values (b.school_id,fid,stid,false,auth.uid());   -- imported links stay UNVERIFIED until admin confirms
        end if;
      end if;
      ok := ok + 1;
    exception when others then
      insert into public.import_errors (school_id,batch_id,row_no,raw,errors) values (b.school_id,p_batch,rowno,r,array[SQLERRM]);
      bad := bad + 1;
    end;
    stid := null; ex := null; fid := null;
  end loop;

  update public.import_batches set imported = imported + ok, skipped = skipped + sk, failed = failed + bad where id = p_batch;
  return jsonb_build_object('imported',ok,'skipped',sk,'failed',bad);
end $$;

create or replace function public.finish_import(p_batch uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b public.import_batches;
begin
  select * into b from public.import_batches where id = p_batch and created_by = auth.uid();
  if not found then raise exception 'Batch not found'; end if;
  update public.import_batches set status='completed' where id = p_batch;
  perform public.audit_write(b.school_id,'data_import','import_batches',p_batch::text,null,
     jsonb_build_object('file',b.filename,'imported',b.imported,'skipped',b.skipped,'failed',b.failed),null);
  return jsonb_build_object('imported',b.imported,'skipped',b.skipped,'failed',b.failed,'total',b.total_rows);
end $$;
