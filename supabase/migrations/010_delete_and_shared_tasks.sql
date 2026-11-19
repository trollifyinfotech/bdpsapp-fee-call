-- =====================================================================
-- 010: (a) Delete students PERMANENTLY (wrong entries), single or in bulk
--      (b) One student can be given to SEVERAL teachers (shared task):
--          any of them can call; when the task is completed / the fee is fully paid
--          it disappears from ALL of them.
--      (c) Import tells you when a matching student is ARCHIVED.
-- Safe to run on an existing database (idempotent). Run it ONCE in the SQL Editor.
-- =====================================================================

alter table public.calling_tasks add column if not exists co_assignees uuid[] not null default '{}';

insert into public.permissions (code, name, category) values
  ('delete_student', 'Delete Student Permanently (wrong entries)', 'Students')
on conflict (code) do nothing;
update public.permissions set name = 'Archive Student' where code = 'archive_student';
insert into public.role_permissions (role_code, permission_code) values ('school_owner','delete_student'), ('principal','delete_student')
on conflict do nothing;


-- append-only guard: only delete_students_permanently() may cascade-remove call history of a deleted wrong-entry student
create or replace function public.forbid_delete() returns trigger language plpgsql as $$
begin
  -- only delete_students_permanently() sets this flag; it first refuses students with payments / fee adjustments / RTE reimbursements
  if tg_table_name in ('task_assignment_history','calling_logs') and current_setting('app.student_purge', true) = 'on' then
    return old;
  end if;
  raise exception 'Deleting % records is not allowed (append-only). Use cancellation/reversal.', tg_table_name
    using errcode = '42501';
end $$;

-- ---------- shared calling tasks ----------

create or replace function public.task_has_assignee(p_assigned uuid, p_co uuid[], p_user uuid) returns boolean
language sql immutable as $$ select p_user is not null and (p_user = p_assigned or p_user = any(coalesce(p_co, '{}'))) $$;

drop function if exists public.create_calling_tasks(uuid, text, text, uuid[], uuid[], text, date);

create or replace function public.create_calling_tasks(
  p_session uuid, p_mode text, p_class text default null, p_student_ids uuid[] default null,
  p_teacher_ids uuid[] default null, p_priority text default 'normal', p_deadline date default null,
  p_share boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_sid uuid; c record; v_n int := 0; v_idx int := 0; v_teacher uuid; v_exist int := 0; v_zero int := 0;
  v_cnt int; t uuid; v_per jsonb := '{}'::jsonb; v_ids uuid[]; v_id uuid; v_shared int := 0; ex record; tid2 uuid; v_co uuid[];
begin
  select school_id into v_sid from public.academic_sessions where id = p_session;
  perform public.require_perm(v_sid, 'assign_calling_tasks');
  if p_teacher_ids is null or cardinality(p_teacher_ids) = 0 then raise exception 'Select at least one teacher'; end if;
  if p_mode not in ('students','class','all_pending') then raise exception 'Invalid mode'; end if;
  if p_mode = 'class' and p_class is null then raise exception 'Class is required'; end if;
  if p_mode = 'students' and (p_student_ids is null or cardinality(p_student_ids) = 0) then raise exception 'Select students'; end if;
  foreach t in array p_teacher_ids loop
    if not public.user_has_perm(t, v_sid, 'make_calls') then
      raise exception 'Selected user cannot make calls (missing make_calls permission)'; end if;
  end loop;

  for c in
    select e.id as enr, e.student_id, b.pending
    from public.student_session_enrollments e
    join public.students s on s.id = e.student_id
    join public.v_enrollment_balances b on b.enrollment_id = e.id
    where e.school_id = v_sid and e.session_id = p_session and e.status = 'active' and s.status = 'active'
      and ((p_mode = 'students' and e.student_id = any(p_student_ids))
        or (p_mode = 'class' and e.class_name = p_class)
        or p_mode = 'all_pending')
    order by e.class_name, s.name
  loop
    if c.pending <= 0 then v_zero := v_zero + 1; continue; end if;
    select * into ex from public.calling_tasks where school_id = v_sid and session_id = p_session
       and student_id = c.student_id and status in ('pending','in_progress','promised');
    if found then
      if p_share then   -- same student, one more teacher: add as co-assignee of the existing task
        v_co := array(select u from unnest(p_teacher_ids) u where u <> ex.assigned_to and not (u = any(ex.co_assignees)));
        if cardinality(v_co) > 0 then
          update public.calling_tasks set co_assignees = co_assignees || v_co where id = ex.id;
          foreach tid2 in array v_co loop
            insert into public.task_assignment_history (school_id, task_id, from_user, to_user, changed_by, reason)
            values (v_sid, ex.id, null, tid2, auth.uid(), 'Added as shared assignee');
            v_per := jsonb_set(v_per, array[tid2::text], to_jsonb(coalesce((v_per ->> tid2::text)::int, 0) + 1));
          end loop;
          v_shared := v_shared + 1; continue;
        end if;
      end if;
      v_exist := v_exist + 1; continue;
    end if;
    if p_share then
      v_teacher := p_teacher_ids[1]; v_co := p_teacher_ids[2:cardinality(p_teacher_ids)];
    else
      v_teacher := p_teacher_ids[(v_idx % cardinality(p_teacher_ids)) + 1]; v_co := '{}';
    end if;
    insert into public.calling_tasks (school_id, session_id, student_id, enrollment_id, assigned_to, co_assignees, assigned_by, priority, deadline)
    values (v_sid, p_session, c.student_id, c.enr, v_teacher, v_co, auth.uid(), coalesce(p_priority,'normal'), p_deadline)
    returning id into v_id;
    insert into public.task_assignment_history (school_id, task_id, from_user, to_user, changed_by, reason)
    values (v_sid, v_id, null, v_teacher, auth.uid(), 'Initial assignment');
    v_per := jsonb_set(v_per, array[v_teacher::text], to_jsonb(coalesce((v_per ->> v_teacher::text)::int, 0) + 1));
    if p_share then
      foreach tid2 in array v_co loop
        insert into public.task_assignment_history (school_id, task_id, from_user, to_user, changed_by, reason)
        values (v_sid, v_id, null, tid2, auth.uid(), 'Initial assignment (shared)');
        v_per := jsonb_set(v_per, array[tid2::text], to_jsonb(coalesce((v_per ->> tid2::text)::int, 0) + 1));
      end loop;
    end if;
    v_idx := v_idx + 1; v_n := v_n + 1;
  end loop;

  for t in select key::uuid from jsonb_each(v_per) loop
    perform public.notify(v_sid, t, 'new_calling_task', 'New calling tasks assigned',
       (v_per ->> t::text) || ' student(s) assigned to you for fee follow-up', '/app.html#/crm/today',
       'newtask:' || t || ':' || to_char(now(), 'YYYYMMDDHH24MI'));
  end loop;
  return jsonb_build_object('created', v_n, 'shared_added', v_shared, 'skipped_already_assigned', v_exist, 'skipped_no_pending_fee', v_zero);
end $$;

create or replace function public.reassign_task(p_task uuid, p_to uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare t public.calling_tasks;
begin
  select * into t from public.calling_tasks where id = p_task for update;
  if not found then raise exception 'Task not found'; end if;
  perform public.require_perm(t.school_id, 'assign_calling_tasks');
  if t.status in ('completed','cancelled') then raise exception 'Task is already %', t.status; end if;
  if not public.user_has_perm(p_to, t.school_id, 'make_calls') then raise exception 'Target user cannot make calls'; end if;
  if p_to = t.assigned_to then return; end if;
  update public.calling_tasks set assigned_to = p_to, co_assignees = array_remove(co_assignees, p_to) where id = t.id;
  update public.follow_up_tasks set assigned_to = p_to where task_id = t.id and status in ('pending','overdue');
  insert into public.task_assignment_history (school_id, task_id, from_user, to_user, changed_by, reason)
  values (t.school_id, t.id, t.assigned_to, p_to, auth.uid(), p_reason);
  perform public.notify(t.school_id, p_to, 'task_reassigned', 'Task reassigned to you',
     'A calling task was reassigned to you', '/app.html#/crm/today', 'reassign:' || t.id || ':' || to_char(now(),'YYYYMMDDHH24MISS'));
end $$;

create or replace function public.complete_task(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.calling_tasks;
begin
  select * into t from public.calling_tasks where id = p_task for update;
  if not found then raise exception 'Task not found'; end if;
  if not (public.task_has_assignee(t.assigned_to, t.co_assignees, auth.uid()) or public.has_perm(t.school_id, 'assign_calling_tasks')) then
    raise exception 'Not your task' using errcode = '42501'; end if;
  perform public.require_perm(t.school_id, 'make_calls');
  if t.call_count = 0 then raise exception 'Record at least one call before completing the task'; end if;
  if exists (select 1 from public.payment_promises where task_id = t.id and status in ('pending','overdue')) then
    raise exception 'A payment promise is still open for this student. It closes automatically when payment is verified.';
  end if;
  update public.calling_tasks set status = 'completed', completed_at = now() where id = t.id;
  update public.follow_up_tasks set status = 'done', completed_at = now() where task_id = t.id and status in ('pending','overdue');
end $$;

create or replace function public.add_task_assignee(p_task uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.calling_tasks;
begin
  select * into t from public.calling_tasks where id = p_task for update;
  if not found then raise exception 'Task not found'; end if;
  perform public.require_perm(t.school_id, 'assign_calling_tasks');
  if t.status in ('completed','cancelled') then raise exception 'Task is already %', t.status; end if;
  if not public.user_has_perm(p_user, t.school_id, 'make_calls') then raise exception 'Selected user cannot make calls'; end if;
  if public.task_has_assignee(t.assigned_to, t.co_assignees, p_user) then return; end if;
  update public.calling_tasks set co_assignees = co_assignees || p_user where id = t.id;
  insert into public.task_assignment_history (school_id, task_id, from_user, to_user, changed_by, reason)
  values (t.school_id, t.id, null, p_user, auth.uid(), 'Added as shared assignee');
  perform public.notify(t.school_id, p_user, 'new_calling_task', 'A calling task was shared with you',
     'A student was also assigned to you for fee follow-up', '/app.html#/crm/today', 'share:' || t.id || ':' || p_user);
end $$;

create or replace function public.remove_task_assignee(p_task uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.calling_tasks;
begin
  select * into t from public.calling_tasks where id = p_task for update;
  if not found then raise exception 'Task not found'; end if;
  perform public.require_perm(t.school_id, 'assign_calling_tasks');
  if p_user = t.assigned_to then raise exception 'Use Reassign to change the main assignee'; end if;
  update public.calling_tasks set co_assignees = array_remove(co_assignees, p_user) where id = t.id;
  insert into public.task_assignment_history (school_id, task_id, from_user, to_user, changed_by, reason)
  values (t.school_id, t.id, p_user, null, auth.uid(), 'Removed shared assignee');
end $$;

create or replace function public.log_call(
  p_student uuid, p_session uuid, p_task uuid, p_status text, p_remark text,
  p_outcome text default null, p_parent_response text default null, p_parent_name text default null,
  p_parent_mobile text default null, p_called_at timestamptz default null,
  p_promised_date date default null, p_promised_amount numeric default null,
  p_next_followup date default null, p_followup_time time default null,
  p_priority text default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_sid uuid; t public.calling_tasks; v_log uuid; v_prom uuid; v_assignee uuid; v_enr uuid;
  v_today date := public.today_local(); v_streak int; v_new_status text; v_next date;
begin
  select school_id into v_sid from public.students where id = p_student;
  if v_sid is null then raise exception 'Student not found'; end if;
  perform public.require_perm(v_sid, 'make_calls');
  perform public.require_perm(v_sid, 'add_call_remarks');
  if not exists (select 1 from public.academic_sessions where id = p_session and school_id = v_sid) then
    raise exception 'Session not in your school'; end if;
  if p_status not in ('connected','not_answered','busy','switched_off','wrong_number','callback_requested',
                      'promised_to_pay','refused','payment_done','dispute','other') then
    raise exception 'Invalid call status'; end if;
  if length(trim(coalesce(p_remark,''))) < 3 then raise exception 'Teacher remark is required'; end if;

  if p_task is not null then
    select * into t from public.calling_tasks where id = p_task and school_id = v_sid and student_id = p_student for update;
    if not found then raise exception 'Task not found for this student'; end if;
    if not public.task_has_assignee(t.assigned_to, t.co_assignees, auth.uid()) and not public.has_perm(v_sid, 'assign_calling_tasks') then
      raise exception 'This task is assigned to another teacher' using errcode = '42501'; end if;
  elsif not public.has_perm(v_sid, 'assign_calling_tasks') then
    raise exception 'A calling task is required' using errcode = '42501';
  end if;

  if p_status = 'promised_to_pay' and p_promised_date is null then
    raise exception 'Promised payment date is required when the parent promised to pay'; end if;
  if p_promised_date is not null and p_promised_date < v_today then raise exception 'Promised date cannot be in the past'; end if;
  if p_next_followup is not null and p_next_followup < v_today then raise exception 'Follow-up date cannot be in the past'; end if;
  if p_promised_amount is not null and p_promised_amount <= 0 then raise exception 'Promised amount must be positive'; end if;

  insert into public.calling_logs (school_id, session_id, task_id, student_id, called_by, parent_name, parent_mobile, called_at,
      call_status, outcome, parent_response, remark, promised_date, next_followup_date, followup_time, priority, notes)
  values (v_sid, p_session, p_task, p_student, auth.uid(), p_parent_name, p_parent_mobile, coalesce(p_called_at, now()),
      p_status, p_outcome, p_parent_response, trim(p_remark), p_promised_date, p_next_followup, p_followup_time, p_priority, p_notes)
  returning id into v_log;

  v_assignee := case when public.task_has_assignee(t.assigned_to, t.co_assignees, auth.uid()) then auth.uid() else coalesce(t.assigned_to, auth.uid()) end;
  select id into v_enr from public.student_session_enrollments where student_id = p_student and session_id = p_session;

  -- this call fulfils follow-ups that were already due
  update public.follow_up_tasks set status = 'done', completed_at = now(), completed_log_id = v_log
   where student_id = p_student and session_id = p_session and status in ('pending','overdue') and due_date <= v_today
     and (p_task is null or task_id = p_task);

  if p_promised_date is not null then
    update public.payment_promises set status = 'cancelled'
     where student_id = p_student and session_id = p_session and status in ('pending','overdue');
    update public.follow_up_tasks set status = 'cancelled'
     where student_id = p_student and session_id = p_session and status in ('pending','overdue') and kind in ('promise_due','promise_overdue');
    insert into public.payment_promises (school_id, session_id, student_id, enrollment_id, task_id, log_id, promised_by_user,
                                         promised_date, promised_amount)
    values (v_sid, p_session, p_student, v_enr, p_task, v_log, auth.uid(), p_promised_date, p_promised_amount)
    returning id into v_prom;
    insert into public.follow_up_tasks (school_id, session_id, task_id, student_id, assigned_to, kind, due_date, promise_id, log_id, dedupe_key)
    values (v_sid, p_session, p_task, p_student, v_assignee, 'promise_due', p_promised_date, v_prom, v_log, 'pdue:' || v_prom)
    on conflict (school_id, dedupe_key) do nothing;
  end if;

  if p_next_followup is not null then
    insert into public.follow_up_tasks (school_id, session_id, task_id, student_id, assigned_to, kind, due_date, due_time, log_id, dedupe_key)
    values (v_sid, p_session, p_task, p_student, v_assignee, 'follow_up', p_next_followup, p_followup_time, v_log, 'fu:' || v_log)
    on conflict (school_id, dedupe_key) do nothing;
  end if;

  if p_task is not null then
    v_streak := case when p_status in ('not_answered','busy','switched_off') then t.not_answered_streak + 1 else 0 end;
    v_new_status := case when p_promised_date is not null then 'promised'
                         when t.status = 'promised' and exists (select 1 from public.payment_promises where task_id = t.id and status in ('pending','overdue')) then 'promised'
                         else 'in_progress' end;
    select min(due_date) into v_next from public.follow_up_tasks where task_id = p_task and status in ('pending','overdue');
    update public.calling_tasks set call_count = call_count + 1, last_call_at = coalesce(p_called_at, now()),
           last_status = p_status, last_remark = trim(p_remark), not_answered_streak = v_streak,
           status = v_new_status, next_followup_date = v_next,
           priority = coalesce(nullif(p_priority,''), priority)
     where id = p_task;
  end if;

  if p_status in ('dispute','refused') then
    perform public.notify_roles(v_sid, array['school_owner','principal'], 'fee_dispute', 'Fee issue reported on call',
       'A parent ' || case when p_status = 'dispute' then 'raised a fee dispute' else 'refused to pay' end, '/app.html#/crm/history',
       'disp:' || v_log);
  end if;
  return jsonb_build_object('log_id', v_log, 'promise_id', v_prom);
end $$;

create or replace function public.resolve_student_tasks(p_student uuid, p_session uuid, p_payment uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare pr record; v_paid numeric; v_pending numeric; t record; a uuid;
begin
  for pr in select * from public.payment_promises where student_id = p_student and session_id = p_session and status in ('pending','overdue') loop
    select coalesce(sum(pa.amount), 0) into v_paid from public.payments py join public.payment_allocations pa on pa.payment_id = py.id
     where py.enrollment_id = pr.enrollment_id and py.status = 'verified' and py.created_at >= pr.created_at;
    if v_paid > 0 and (pr.promised_amount is null or v_paid >= pr.promised_amount) then
      update public.payment_promises set status = 'kept', resolved_payment_id = p_payment, resolved_at = now() where id = pr.id;
      update public.follow_up_tasks set status = 'done', completed_at = now()
       where promise_id = pr.id and status in ('pending','overdue');
    end if;
  end loop;
  select b.pending into v_pending from public.v_enrollment_balances b
   join public.student_session_enrollments e on e.id = b.enrollment_id where e.student_id = p_student and e.session_id = p_session;
  if coalesce(v_pending, 0) <= 0 then
    for t in select * from public.calling_tasks where student_id = p_student and session_id = p_session
              and status in ('pending','in_progress','promised') loop
      update public.calling_tasks set status = 'completed', completed_at = now() where id = t.id;
      update public.follow_up_tasks set status = 'done', completed_at = now() where task_id = t.id and status in ('pending','overdue');
      update public.payment_promises set status = 'kept', resolved_at = now(), resolved_payment_id = p_payment
       where task_id = t.id and status in ('pending','overdue');
      foreach a in array (array[t.assigned_to] || t.co_assignees) loop
        perform public.notify(t.school_id, a, 'fee_payment_received', 'Fee received - task resolved',
           'Fee has been fully received for a student on your list. The task was closed automatically.', '/app.html#/crm/history',
           'resolved:' || t.id || ':' || a);
      end loop;
    end loop;
  end if;
end $$;

create or replace function public.crm_list(p_session uuid, p_scope text default 'mine', p_search text default null,
  p_class text default null, p_group text default null, p_limit int default 25, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_sid uuid; v_admin boolean; v_fin boolean; v_addr boolean; v_q text; res jsonb;
begin
  select school_id into v_sid from public.academic_sessions where id = p_session;
  perform public.require_perm(v_sid, 'view_calling_crm');
  v_admin := public.has_perm(v_sid, 'assign_calling_tasks') or public.has_perm(v_sid, 'view_teacher_performance');
  v_fin := public.has_perm(v_sid, 'view_fee_amounts');
  v_addr := public.has_perm(v_sid, 'view_student_list');
  if not v_admin then p_scope := 'mine'; end if;
  v_q := nullif(trim(coalesce(p_search, '')), '');
  p_limit := least(greatest(coalesce(p_limit, 25), 1), 200);

  with base as (
    select e.id as enrollment_id, s.id as student_id, s.student_code, s.admission_no, s.name, s.father_name, s.mother_name,
           s.mobile, s.alt_mobile, case when v_addr then s.address end as address,
           e.class_name, e.section, b.pay_status, (b.overdue_amount > 0) as is_overdue,
           case when v_fin then b.pending end as pending_amount,
           case when v_fin then b.net end as net_fee, case when v_fin then b.paid end as paid_amount,
           t.id as task_id, t.assigned_to, t.co_assignees,
           (select string_agg(p2.full_name, ', ' order by (p2.id <> t.assigned_to), p2.full_name) from public.user_profiles p2
             where p2.id = t.assigned_to or p2.id = any(t.co_assignees)) as assigned_name, t.status as task_status, t.priority as task_priority,
           t.deadline, t.last_call_at, t.last_status, t.last_remark, coalesce(t.call_count, 0) as call_count,
           coalesce(t.not_answered_streak, 0) as not_answered_streak,
           pr.promised_date, pr.status as promise_status,
           (select min(f.due_date) from public.follow_up_tasks f where f.student_id = s.id and f.session_id = p_session
              and f.status in ('pending','overdue')) as next_followup,
           array_remove(array[
             case when b.pay_status = 'unpaid' then 'no_payment' end,
             case when b.pay_status = 'partial' then 'partial' end,
             case when b.overdue_amount > 0 then 'overdue' end,
             case when pr.promised_date is not null and pr.promised_date < public.today_local() then 'promise_passed' end,
             case when coalesce(t.call_count, 0) = 0 then 'no_calling' end,
             case when coalesce(t.not_answered_streak, 0) >= 3 then 'repeat_not_answering' end], null) as flags
    from public.student_session_enrollments e
    join public.students s on s.id = e.student_id
    join public.v_enrollment_balances b on b.enrollment_id = e.id
    left join public.calling_tasks t on t.enrollment_id = e.id and t.status in ('pending','in_progress','promised')
    left join public.user_profiles up on up.id = t.assigned_to
    left join lateral (select p.promised_date, p.status from public.payment_promises p
                       where p.enrollment_id = e.id and p.status in ('pending','overdue') order by p.promised_date limit 1) pr on true
    where e.school_id = v_sid and e.session_id = p_session and e.status = 'active' and s.status = 'active'
      and b.pending > 0                                   -- RTE / zero-fee / fully paid never appear
      and (p_scope <> 'mine' or public.task_has_assignee(t.assigned_to, t.co_assignees, auth.uid()))
      and (p_scope <> 'unassigned' or t.id is null)
      and (p_class is null or e.class_name = p_class)
      and (v_q is null or s.name ilike '%' || v_q || '%' or s.father_name ilike '%' || v_q || '%'
           or s.mobile like '%' || v_q || '%' or s.student_code ilike '%' || v_q || '%' or s.admission_no ilike '%' || v_q || '%')
  ), filtered as (
    select *, case when 'promise_passed' = any(flags) then 1 when 'overdue' = any(flags) then 2
                   when 'repeat_not_answering' = any(flags) then 3 when 'no_calling' = any(flags) then 4
                   when 'partial' = any(flags) then 5 else 6 end as priority_rank
    from base where p_group is null or p_group = any(flags)
  ), page as (select * from filtered order by priority_rank, name limit p_limit offset p_offset)
  select jsonb_build_object('total', (select count(*) from filtered),
         'rows', coalesce((select jsonb_agg(to_jsonb(page) order by priority_rank, name) from page), '[]'::jsonb))
  into res;
  return res;
end $$;

create or replace function public.crm_dashboard(p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_sid uuid; v_admin boolean; v_me uuid := auth.uid(); v_today date := public.today_local(); res jsonb;
  v_calls_today int; v_conn int; v_notconn int; v_followdone int; v_followall int;
begin
  select school_id into v_sid from public.academic_sessions where id = p_session;
  perform public.require_perm(v_sid, 'view_calling_crm');
  v_admin := public.has_perm(v_sid, 'assign_calling_tasks') or public.has_perm(v_sid, 'view_teacher_performance');

  select count(*) filter (where (called_at at time zone 'Asia/Kolkata')::date = v_today),
         count(*) filter (where public.call_is_connected(call_status)),
         count(*) filter (where call_status in ('not_answered','busy','switched_off','wrong_number'))
    into v_calls_today, v_conn, v_notconn
    from public.calling_logs where school_id = v_sid and session_id = p_session and (v_admin or called_by = v_me);
  select count(*) filter (where status = 'done'), count(*) into v_followdone, v_followall
    from public.follow_up_tasks where school_id = v_sid and session_id = p_session and status <> 'cancelled' and (v_admin or assigned_to = v_me);

  res := jsonb_build_object(
    'scope', case when v_admin then 'school' else 'mine' end,
    'students_requiring_calls', (select count(*) from public.student_session_enrollments e
        join public.v_enrollment_balances b on b.enrollment_id = e.id join public.students s on s.id = e.student_id
        where e.school_id = v_sid and e.session_id = p_session and e.status = 'active' and s.status = 'active' and b.pending > 0
          and (v_admin or exists (select 1 from public.calling_tasks t where t.enrollment_id = e.id and public.task_has_assignee(t.assigned_to, t.co_assignees, v_me)
                                  and t.status in ('pending','in_progress','promised')))),
    'pending_tasks', (select count(*) from public.calling_tasks where school_id = v_sid and session_id = p_session
        and status in ('pending','in_progress','promised') and (v_admin or public.task_has_assignee(assigned_to, co_assignees, v_me))),
    'calls_today', v_calls_today,
    'completed_tasks', (select count(*) from public.calling_tasks where school_id = v_sid and session_id = p_session
        and status = 'completed' and (v_admin or public.task_has_assignee(assigned_to, co_assignees, v_me))),
    'not_called', (select count(*) from public.calling_tasks where school_id = v_sid and session_id = p_session
        and status in ('pending','in_progress','promised') and call_count = 0 and (v_admin or public.task_has_assignee(assigned_to, co_assignees, v_me))),
    'connected_calls', v_conn, 'not_connected_calls', v_notconn,
    'promised_pending', (select count(*) from public.payment_promises where school_id = v_sid and session_id = p_session
        and status = 'pending' and (v_admin or promised_by_user = v_me)),
    'promised_overdue', (select count(*) from public.payment_promises where school_id = v_sid and session_id = p_session
        and status = 'overdue' and (v_admin or promised_by_user = v_me)),
    'followups_today', (select count(*) from public.follow_up_tasks where school_id = v_sid and session_id = p_session
        and status = 'pending' and due_date = v_today and (v_admin or assigned_to = v_me)),
    'followups_upcoming', (select count(*) from public.follow_up_tasks where school_id = v_sid and session_id = p_session
        and status = 'pending' and due_date > v_today and (v_admin or assigned_to = v_me)),
    'followups_overdue', (select count(*) from public.follow_up_tasks where school_id = v_sid and session_id = p_session
        and status = 'overdue' and (v_admin or assigned_to = v_me)),
    'tasks_overdue', (select count(*) from public.calling_tasks where school_id = v_sid and session_id = p_session
        and status in ('pending','in_progress','promised') and deadline < v_today and (v_admin or public.task_has_assignee(assigned_to, co_assignees, v_me))),
    'promise_made', (select count(*) from public.payment_promises where school_id = v_sid and session_id = p_session
        and status <> 'cancelled' and (v_admin or promised_by_user = v_me)),
    'promise_kept', (select count(*) from public.payment_promises where school_id = v_sid and session_id = p_session
        and status = 'kept' and (v_admin or promised_by_user = v_me)),
    'followup_completion_rate', case when v_followall = 0 then null else round(100.0 * v_followdone / v_followall, 1) end,
    'daily', coalesce((select jsonb_agg(jsonb_build_object('label', to_char(d, 'DD Mon'), 'calls', coalesce(c.n, 0)) order by d)
        from generate_series(v_today - 13, v_today, interval '1 day') g(d)
        left join (select (called_at at time zone 'Asia/Kolkata')::date as day, count(*) n from public.calling_logs
                   where school_id = v_sid and session_id = p_session and (v_admin or called_by = v_me) group by 1) c on c.day = g.d::date), '[]'::jsonb),
    'weekly', coalesce((select jsonb_agg(jsonb_build_object('label', to_char(w, 'DD Mon'), 'calls', coalesce(c.n, 0)) order by w)
        from generate_series(date_trunc('week', v_today::timestamp) - interval '7 weeks', date_trunc('week', v_today::timestamp), interval '1 week') g(w)
        left join (select date_trunc('week', called_at at time zone 'Asia/Kolkata') as wk, count(*) n from public.calling_logs
                   where school_id = v_sid and session_id = p_session and (v_admin or called_by = v_me) group by 1) c on c.wk = g.w), '[]'::jsonb),
    'monthly', coalesce((select jsonb_agg(jsonb_build_object('label', to_char(m, 'Mon YY'), 'calls', coalesce(c.n, 0)) order by m)
        from generate_series(date_trunc('month', v_today::timestamp) - interval '5 months', date_trunc('month', v_today::timestamp), interval '1 month') g(m)
        left join (select date_trunc('month', called_at at time zone 'Asia/Kolkata') as mo, count(*) n from public.calling_logs
                   where school_id = v_sid and session_id = p_session and (v_admin or called_by = v_me) group by 1) c on c.mo = g.m), '[]'::jsonb),
    'by_teacher', case when v_admin then coalesce((select jsonb_agg(jsonb_build_object('teacher', up.full_name, 'calls', x.n) order by x.n desc)
        from (select called_by, count(*) n from public.calling_logs where school_id = v_sid and session_id = p_session group by 1) x
        join public.user_profiles up on up.id = x.called_by), '[]'::jsonb) else '[]'::jsonb end,
    'my_target', (select daily_target from public.teacher_calling_targets where school_id = v_sid and teacher_id = v_me
                  and effective_from <= v_today order by effective_from desc limit 1));
  return res;
end $$;

create or replace function public.teacher_performance(p_session uuid, p_from date default null, p_to date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_sid uuid; v_admin boolean; v_today date := public.today_local(); v_from date; v_to date; res jsonb;
begin
  select school_id into v_sid from public.academic_sessions where id = p_session;
  perform public.require_perm(v_sid, 'view_calling_crm');
  v_admin := public.has_perm(v_sid, 'view_teacher_performance');
  v_from := coalesce(p_from, date '2000-01-01'); v_to := coalesce(p_to, v_today);

  with teachers as (
    select m.user_id, up.full_name from public.school_memberships m join public.user_profiles up on up.id = m.user_id
    where m.school_id = v_sid and (m.is_active or exists (select 1 from public.calling_logs l where l.called_by = m.user_id and l.school_id = v_sid))
      and public.user_has_perm(m.user_id, v_sid, 'make_calls') and (v_admin or m.user_id = auth.uid())
  ), calls as (
    select l.called_by, count(*) total, count(*) filter (where public.call_is_connected(l.call_status)) connected,
           count(*) filter (where l.call_status = 'not_answered') not_answered, count(*) filter (where l.call_status = 'busy') busy,
           count(*) filter (where l.call_status = 'promised_to_pay') promised, count(distinct l.student_id) students_called,
           max(l.called_at) last_call,
           count(*) filter (where (l.called_at at time zone 'Asia/Kolkata')::date = v_today) as today,
           count(*) filter (where (l.called_at at time zone 'Asia/Kolkata')::date > v_today - 7) as week,
           count(*) filter (where (l.called_at at time zone 'Asia/Kolkata')::date > v_today - 30) as month
    from public.calling_logs l where l.school_id = v_sid and l.session_id = p_session
      and (l.called_at at time zone 'Asia/Kolkata')::date between v_from and v_to group by l.called_by
  ), tasks as (
    select u.uid as assigned_to, count(*) filter (where status <> 'cancelled') assigned_tasks,
           count(distinct student_id) filter (where status in ('pending','in_progress','promised')) assigned_students,
           count(*) filter (where status in ('pending','in_progress','promised') and deadline < v_today) overdue_tasks,
           count(*) filter (where status = 'completed') completed_tasks
    from public.calling_tasks cross join lateral unnest(array[assigned_to] || co_assignees) as u(uid)
    where school_id = v_sid and session_id = p_session group by u.uid
  ), fu as (
    select assigned_to, count(*) filter (where status = 'done') done,
           count(*) filter (where status = 'done' and completed_at at time zone 'Asia/Kolkata' <= (due_date + 1)::timestamp) on_time,
           count(*) filter (where status = 'overdue') missed
    from public.follow_up_tasks where school_id = v_sid and session_id = p_session group by assigned_to
  ), pr as (
    select promised_by_user as u, count(*) filter (where status <> 'cancelled') made, count(*) filter (where status = 'kept') kept,
           count(*) filter (where status = 'overdue') overdue
    from public.payment_promises where school_id = v_sid and session_id = p_session group by promised_by_user
  ), tg as (
    select distinct on (teacher_id) teacher_id, daily_target from public.teacher_calling_targets
    where school_id = v_sid and effective_from <= v_today order by teacher_id, effective_from desc
  ), rows_ as (
    select t.user_id as teacher_id, t.full_name as teacher_name,
           coalesce(k.assigned_students, 0) as assigned_students, coalesce(k.assigned_tasks, 0) as assigned_tasks,
           coalesce(c.total, 0) as total_calls, coalesce(c.connected, 0) as connected_calls,
           coalesce(c.not_answered, 0) as not_answered, coalesce(c.busy, 0) as busy_calls,
           coalesce(c.promised, 0) as promised_payments, coalesce(f.done, 0) as followups_completed,
           coalesce(f.missed, 0) as followups_missed, coalesce(k.overdue_tasks, 0) as overdue_tasks,
           coalesce(k.completed_tasks, 0) as completed_tasks, c.last_call as last_call_at,
           coalesce(c.today, 0) as calls_today, coalesce(c.week, 0) as calls_week, coalesce(c.month, 0) as calls_month,
           coalesce(c.students_called, 0) as students_called,
           coalesce(p.made, 0) as promises_made, coalesce(p.kept, 0) as promises_kept, coalesce(p.overdue, 0) as promises_overdue,
           g.daily_target,
           case when coalesce(k.assigned_tasks,0) > 0 then least(1.0, coalesce(c.students_called,0)::numeric / k.assigned_tasks) end as cov,
           case when coalesce(f.done,0) + coalesce(f.missed,0) > 0 then coalesce(f.on_time,0)::numeric / (f.done + f.missed) end as adh,
           case when coalesce(c.total,0) > 0 then c.connected::numeric / c.total end as conn,
           case when coalesce(p.made,0) > 0 then p.kept::numeric / p.made end as rec
    from teachers t left join calls c on c.called_by = t.user_id left join tasks k on k.assigned_to = t.user_id
    left join fu f on f.assigned_to = t.user_id left join pr p on p.u = t.user_id left join tg g on g.teacher_id = t.user_id
  ), scored as (
    select *, case when (cov is not null)::int * 40 + (adh is not null)::int * 30 + (conn is not null)::int * 10 + (rec is not null)::int * 20 = 0
                   then null
                   else round(100 * (coalesce(cov,0) * 40 + coalesce(adh,0) * 30 + coalesce(conn,0) * 10 + coalesce(rec,0) * 20)
                        / ((cov is not null)::int * 40 + (adh is not null)::int * 30 + (conn is not null)::int * 10 + (rec is not null)::int * 20), 1)
              end as score
    from rows_
  )
  select jsonb_build_object('rows', coalesce(jsonb_agg(to_jsonb(scored) - 'cov' - 'adh' - 'conn' - 'rec'
         || jsonb_build_object('coverage_pct', round(100 * cov, 1), 'followup_pct', round(100 * adh, 1),
                               'connect_pct', round(100 * conn, 1), 'recovery_pct', round(100 * rec, 1))
         order by score desc nulls last, teacher_name), '[]'::jsonb)) into res from scored;
  return res;
end $$;

revoke all on function public.resolve_student_tasks(uuid, uuid, uuid) from public, anon, authenticated;

create or replace function public.owner_summary(p_session uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_sid uuid; v_fin boolean; v_today date := public.today_local(); res jsonb;
begin
  select school_id into v_sid from public.academic_sessions where id = p_session;
  perform public.require_perm(v_sid, 'view_teacher_performance');
  v_fin := public.has_perm(v_sid, 'view_fee_amounts');
  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'tasks_assigned', (select count(*) from public.task_assignment_history h join public.calling_tasks t on t.id = h.task_id
         where h.school_id = v_sid and t.session_id = p_session and (h.changed_at at time zone 'Asia/Kolkata')::date between p_from and p_to),
    'calls_completed', (select count(*) from public.calling_logs where school_id = v_sid and session_id = p_session
         and (called_at at time zone 'Asia/Kolkata')::date between p_from and p_to),
    'connected_calls', (select count(*) from public.calling_logs where school_id = v_sid and session_id = p_session
         and public.call_is_connected(call_status) and (called_at at time zone 'Asia/Kolkata')::date between p_from and p_to),
    'tasks_not_completed', (select count(*) from public.calling_tasks where school_id = v_sid and session_id = p_session
         and status in ('pending','in_progress','promised')),
    'followups_due', (select count(*) from public.follow_up_tasks where school_id = v_sid and session_id = p_session
         and status in ('pending','overdue') and due_date between p_from and p_to),
    'promises_received', (select count(*) from public.payment_promises where school_id = v_sid and session_id = p_session
         and (created_at at time zone 'Asia/Kolkata')::date between p_from and p_to),
    'promises_overdue', (select count(*) from public.payment_promises where school_id = v_sid and session_id = p_session and status = 'overdue'),
    'payments_recovered', case when v_fin then (select coalesce(sum(py.amount), 0) from public.payments py
         where py.school_id = v_sid and py.session_id = p_session and py.status = 'verified' and py.payment_date between p_from and p_to
           and exists (select 1 from public.calling_tasks t where t.student_id = py.student_id and t.session_id = p_session)) end,
    'teacher_calls', coalesce((select jsonb_agg(jsonb_build_object('teacher', up.full_name, 'calls', x.n, 'connected', x.c) order by x.n desc)
         from (select called_by, count(*) n, count(*) filter (where public.call_is_connected(call_status)) c from public.calling_logs
               where school_id = v_sid and session_id = p_session and (called_at at time zone 'Asia/Kolkata')::date between p_from and p_to group by 1) x
         join public.user_profiles up on up.id = x.called_by), '[]'::jsonb),
    'teachers_incomplete', coalesce((select jsonb_agg(jsonb_build_object('teacher', up.full_name, 'open_tasks', x.open_tasks,
            'followups_overdue', x.overdue, 'calls_in_period', x.calls) order by x.overdue desc)
         from (select u.uid as assigned_to,
                 count(*) filter (where t.status in ('pending','in_progress','promised')) open_tasks,
                 (select count(*) from public.follow_up_tasks f where f.assigned_to = u.uid and f.session_id = p_session and f.status = 'overdue') overdue,
                 (select count(*) from public.calling_logs l where l.called_by = u.uid and l.session_id = p_session
                    and (l.called_at at time zone 'Asia/Kolkata')::date between p_from and p_to) calls
               from public.calling_tasks t cross join lateral unnest(array[t.assigned_to] || t.co_assignees) as u(uid)
               where t.school_id = v_sid and t.session_id = p_session group by u.uid) x
         join public.user_profiles up on up.id = x.assigned_to
         where x.open_tasks > 0 and (x.calls = 0 or x.overdue > 0)), '[]'::jsonb)) into res;
  return res;
end $$;

-- ---------- import: archived students ----------
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


-- ---------- policies: shared assignees can read their tasks ----------
drop policy if exists tasks_read on public.calling_tasks;
create policy tasks_read on public.calling_tasks for select to authenticated
  using (public.has_perm(school_id, 'view_calling_crm')
         and (assigned_to = auth.uid() or auth.uid() = any(co_assignees) or public.has_perm(school_id, 'assign_calling_tasks') or public.has_perm(school_id, 'view_teacher_performance')));

-- ---------- permanent delete ----------
-- Blocks students that have money records. Everything else (enrollment, fee assignments, concessions,
-- calling tasks, follow-ups, promises, call history of the student) is removed. Each deletion is audited.
create or replace function public._student_delete_blocker(p_student uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from public.payments where student_id = p_student) then 'fee payment records exist (use Archive instead)'
    when exists (select 1 from public.fee_adjustments fa join public.student_fee_assignments sa on sa.id = fa.assignment_id
                  where sa.student_id = p_student) then 'fee adjustment records exist (use Archive instead)'
    when exists (select 1 from public.rte_reimbursements rr join public.rte_records r on r.id = rr.rte_record_id
                  where r.student_id = p_student) then 'RTE reimbursement records exist (use Archive instead)'
  end
$$;

create or replace function public.delete_students_permanently(p_students uuid[], p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sid uuid := public.my_school_id(); s record; v_del int := 0; v_skip jsonb := '[]'::jsonb; why text;
begin
  perform public.require_perm(sid, 'delete_student');
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Reason is required'; end if;
  if p_students is null or cardinality(p_students) = 0 then raise exception 'Select at least one student'; end if;
  if cardinality(p_students) > 1000 then raise exception 'Delete at most 1000 students at a time'; end if;
  perform set_config('app.student_purge', 'on', true);
  perform set_config('app.audit_reason', trim(p_reason), true);
  for s in select * from public.students where school_id = sid and id = any(p_students) order by name loop
    why := public._student_delete_blocker(s.id);
    if why is not null then
      v_skip := v_skip || jsonb_build_object('student_code', s.student_code, 'name', s.name, 'reason', why);
      continue;
    end if;
    perform public.audit_write(sid, 'student.deleted_permanently', 'students', s.id::text,
            jsonb_build_object('student_code', s.student_code, 'admission_no', s.admission_no, 'name', s.name, 'status', s.status),
            null, trim(p_reason));
    delete from public.students where id = s.id;
    v_del := v_del + 1;
  end loop;
  perform set_config('app.student_purge', 'off', true);
  return jsonb_build_object('deleted', v_del, 'skipped', v_skip);
end $$;

-- ---------- privileges ----------
revoke all on function public.task_has_assignee(uuid, uuid[], uuid) from public, anon;
revoke all on function public.create_calling_tasks(uuid, text, text, uuid[], uuid[], text, date, boolean) from public, anon;
revoke all on function public.add_task_assignee(uuid, uuid) from public, anon;
revoke all on function public.remove_task_assignee(uuid, uuid) from public, anon;
revoke all on function public.delete_students_permanently(uuid[], text) from public, anon;
revoke all on function public._student_delete_blocker(uuid) from public, anon, authenticated;
grant execute on function public.task_has_assignee(uuid, uuid[], uuid) to authenticated;
grant execute on function public.create_calling_tasks(uuid, text, text, uuid[], uuid[], text, date, boolean) to authenticated;
grant execute on function public.add_task_assignee(uuid, uuid) to authenticated;
grant execute on function public.remove_task_assignee(uuid, uuid) to authenticated;
grant execute on function public.delete_students_permanently(uuid[], text) to authenticated;
