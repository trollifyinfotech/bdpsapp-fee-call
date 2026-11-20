-- =====================================================================
-- 011: Task deadlines, bulk transfer / add / remove teachers, renew, Today's-Tasks filters
--   * A task ends at its DEADLINE: it becomes "expired", leaves the teachers' lists, and the
--     administrator assigns a NEW task (or presses "Renew"). Expiry is applied automatically
--     whenever anybody opens the app (and by the optional pg_cron job).
--   * Several teachers can hold the same task; bulk Transfer / Add teacher / Remove teacher.
--   * crm_list gets section, teacher, priority and deadline filters.
-- Safe on an existing database (idempotent). Run ONCE in the SQL Editor (after 001-010).
-- =====================================================================
alter table public.calling_tasks add column if not exists expired_at timestamptz;
alter table public.calling_tasks add column if not exists renewed_at timestamptz;
alter table public.calling_tasks drop constraint if exists calling_tasks_status_check;
alter table public.calling_tasks add constraint calling_tasks_status_check
  check (status in ('pending','in_progress','promised','completed','cancelled','expired'));
alter table public.task_assignment_history alter column to_user drop not null;


create or replace function public.expire_overdue_tasks(p_school uuid default null) returns int
language plpgsql security definer set search_path = public as $$
declare r record; a uuid; n int := 0;
begin
  for r in
    with u as (
      update public.calling_tasks set status = 'expired', expired_at = now()
       where status in ('pending','in_progress','promised') and deadline is not null and deadline < public.today_local()
         and (p_school is null or school_id = p_school)
      returning id, school_id, student_id, assigned_to, co_assignees, assigned_by)
    select u.*, s.name as sname from u join public.students s on s.id = u.student_id
  loop
    n := n + 1;
    foreach a in array (array[r.assigned_to] || r.co_assignees || case when r.assigned_by is null then '{}'::uuid[] else array[r.assigned_by] end) loop
      perform public.notify(r.school_id, a, 'task_expired', 'Calling task deadline is over',
         'The deadline for ' || r.sname || ' is over. The task has ended; a new task must be assigned.',
         '/app.html#/crm/assign', 'expired:' || r.id || ':' || a);
    end loop;
  end loop;
  return n;
end $$;

create or replace function public.expire_my_tasks() returns int
language plpgsql security definer set search_path = public as $$
declare sid uuid := public.my_school_id();
begin
  if sid is null then return 0; end if;
  return public.expire_overdue_tasks(sid);
end $$;

create or replace function public.bulk_assign_tasks(p_tasks uuid[], p_mode text, p_users uuid[], p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare sid uuid := public.my_school_id(); t record; cur uuid[]; nw uuid[]; x uuid; v_upd int := 0; v_same int := 0;
        v_skip jsonb := '[]'::jsonb; v_added jsonb := '{}'::jsonb; why text := coalesce(nullif(trim(p_reason), ''), 'Changed by administrator');
begin
  perform public.require_perm(sid, 'assign_calling_tasks');
  perform public.expire_overdue_tasks(sid);
  if p_mode not in ('set','add','remove') then raise exception 'Invalid mode'; end if;
  if p_tasks is null or cardinality(p_tasks) = 0 then raise exception 'Select at least one task'; end if;
  if cardinality(p_tasks) > 1000 then raise exception 'Select at most 1000 tasks at a time'; end if;
  if p_users is null or cardinality(p_users) = 0 then raise exception 'Select at least one teacher'; end if;
  p_users := array(select y.u from unnest(p_users) with ordinality y(u, o) group by y.u order by min(y.o));
  if p_mode <> 'remove' then
    foreach x in array p_users loop
      if not public.user_has_perm(x, sid, 'make_calls') then raise exception 'Selected user cannot make calls (missing make_calls permission)'; end if;
    end loop;
  end if;
  for t in select ct.*, s.name as sname from public.calling_tasks ct join public.students s on s.id = ct.student_id
            where ct.school_id = sid and ct.id = any(p_tasks) order by s.name loop
    if t.status not in ('pending','in_progress','promised') then
      v_skip := v_skip || jsonb_build_object('student', t.sname, 'reason',
          case when t.status = 'expired' then 'deadline is over - use Renew' else 'task is already ' || t.status end);
      continue;
    end if;
    cur := array[t.assigned_to] || t.co_assignees;
    if p_mode = 'set' then nw := p_users;
    elsif p_mode = 'add' then nw := cur || array(select y from unnest(p_users) y where not (y = any(cur)));
    else
      nw := array(select y.u from unnest(cur) with ordinality y(u, o) where not (y.u = any(p_users)) order by y.o);
      if cardinality(nw) = 0 then
        v_skip := v_skip || jsonb_build_object('student', t.sname, 'reason', 'cannot remove every teacher - transfer it to someone else or cancel the task');
        continue;
      end if;
    end if;
    if nw = cur then v_same := v_same + 1; continue; end if;
    update public.calling_tasks set assigned_to = nw[1], co_assignees = nw[2:cardinality(nw)] where id = t.id;
    foreach x in array cur loop
      if not (x = any(nw)) then
        insert into public.task_assignment_history (school_id, task_id, from_user, to_user, changed_by, reason)
        values (sid, t.id, x, null, auth.uid(), why || ' (removed)');
      end if;
    end loop;
    foreach x in array nw loop
      if not (x = any(cur)) then
        insert into public.task_assignment_history (school_id, task_id, from_user, to_user, changed_by, reason)
        values (sid, t.id, null, x, auth.uid(), why);
        v_added := jsonb_set(v_added, array[x::text], to_jsonb(coalesce((v_added ->> x::text)::int, 0) + 1));
      end if;
    end loop;
    v_upd := v_upd + 1;
  end loop;
  for x in select key::uuid from jsonb_each(v_added) loop
    perform public.notify(sid, x, 'new_calling_task', 'Calling tasks assigned to you',
        (v_added ->> x::text) || ' student(s) were assigned to you for fee follow-up', '/app.html#/crm/today',
        'bulk:' || x || ':' || clock_timestamp()::text);
  end loop;
  return jsonb_build_object('updated', v_upd, 'unchanged', v_same, 'skipped', v_skip);
end $$;

create or replace function public.renew_tasks(p_tasks uuid[], p_deadline date, p_users uuid[] default null, p_priority text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare sid uuid := public.my_school_id(); t record; nw uuid[]; x uuid; v_id uuid; v_n int := 0; v_skip jsonb := '[]'::jsonb;
        v_cnt jsonb := '{}'::jsonb;
begin
  perform public.require_perm(sid, 'assign_calling_tasks');
  perform public.expire_overdue_tasks(sid);
  if p_tasks is null or cardinality(p_tasks) = 0 then raise exception 'Select at least one task'; end if;
  if p_deadline is null or p_deadline < public.today_local() then raise exception 'Choose a new deadline (today or a later date)'; end if;
  if p_priority is not null and p_priority not in ('low','normal','high','urgent') then raise exception 'Invalid priority'; end if;
  if p_users is not null and cardinality(p_users) > 0 then
    p_users := array(select y.u from unnest(p_users) with ordinality y(u, o) group by y.u order by min(y.o));
    foreach x in array p_users loop
      if not public.user_has_perm(x, sid, 'make_calls') then raise exception 'Selected user cannot make calls (missing make_calls permission)'; end if;
    end loop;
  else p_users := null; end if;
  for t in select ct.*, s.name as sname from public.calling_tasks ct join public.students s on s.id = ct.student_id
            where ct.school_id = sid and ct.id = any(p_tasks) order by s.name loop
    if t.status not in ('expired','cancelled') then
      v_skip := v_skip || jsonb_build_object('student', t.sname, 'reason', 'task is ' || t.status || ', only expired / cancelled tasks can be renewed'); continue; end if;
    if exists (select 1 from public.calling_tasks a where a.school_id = sid and a.session_id = t.session_id and a.student_id = t.student_id
                 and a.status in ('pending','in_progress','promised')) then
      v_skip := v_skip || jsonb_build_object('student', t.sname, 'reason', 'student already has an active task');
      update public.calling_tasks set renewed_at = coalesce(renewed_at, now()) where id = t.id and status = 'expired';
      continue; end if;
    if not exists (select 1 from public.v_enrollment_balances b join public.students s on s.id = t.student_id
                    where b.enrollment_id = t.enrollment_id and b.pending > 0 and s.status = 'active') then
      v_skip := v_skip || jsonb_build_object('student', t.sname, 'reason', 'no pending fee (or student not active)'); continue; end if;
    nw := coalesce(p_users, array(select y.u from unnest(array[t.assigned_to] || t.co_assignees) with ordinality y(u, o)
                                   where public.user_has_perm(y.u, sid, 'make_calls') order by y.o));
    if nw is null or cardinality(nw) = 0 then
      v_skip := v_skip || jsonb_build_object('student', t.sname, 'reason', 'previous teachers are not available - choose teachers'); continue; end if;
    insert into public.calling_tasks (school_id, session_id, student_id, enrollment_id, assigned_to, co_assignees, assigned_by, priority, deadline)
    values (sid, t.session_id, t.student_id, t.enrollment_id, nw[1], nw[2:cardinality(nw)], auth.uid(), coalesce(p_priority, t.priority), p_deadline)
    returning id into v_id;
    update public.calling_tasks set renewed_at = now() where id = t.id;
    foreach x in array nw loop
      insert into public.task_assignment_history (school_id, task_id, from_user, to_user, changed_by, reason)
      values (sid, v_id, null, x, auth.uid(), 'Renewed after the previous deadline');
      v_cnt := jsonb_set(v_cnt, array[x::text], to_jsonb(coalesce((v_cnt ->> x::text)::int, 0) + 1));
    end loop;
    v_n := v_n + 1;
  end loop;
  for x in select key::uuid from jsonb_each(v_cnt) loop
    perform public.notify(sid, x, 'new_calling_task', 'New calling tasks assigned to you',
        (v_cnt ->> x::text) || ' student(s) were assigned to you again with a new deadline', '/app.html#/crm/today',
        'renew:' || x || ':' || clock_timestamp()::text);
  end loop;
  return jsonb_build_object('renewed', v_n, 'skipped', v_skip);
end $$;

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
  perform public.expire_overdue_tasks(v_sid);
  if p_deadline is not null and p_deadline < public.today_local() then raise exception 'Deadline cannot be in the past'; end if;
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
    update public.calling_tasks set renewed_at = now() where enrollment_id = c.enr and status = 'expired' and renewed_at is null;
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
    if t.status = 'expired' then raise exception 'The deadline of this task is over. Ask the administrator to assign a new task.'; end if;
    if t.status not in ('pending','in_progress','promised') then raise exception 'This task is already %', t.status; end if;
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

drop function if exists public.crm_list(uuid, text, text, text, text, int, int);

create or replace function public.crm_list(p_session uuid, p_scope text default 'mine', p_search text default null,
  p_class text default null, p_group text default null, p_limit int default 25, p_offset int default 0,
  p_section text default null, p_teacher uuid default null, p_priority text default null, p_due text default null)
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
      and (p_scope <> 'tasks' or t.id is not null)
      and (p_class is null or e.class_name = p_class)
      and (p_section is null or e.section = p_section)
      and (p_teacher is null or not v_admin or public.task_has_assignee(t.assigned_to, t.co_assignees, p_teacher))
      and (p_priority is null or t.priority = p_priority)
      and (p_due is null
           or (p_due = 'overdue' and t.deadline < public.today_local())
           or (p_due = 'soon' and t.deadline between public.today_local() and public.today_local() + 3)
           or (p_due = 'nodeadline' and t.id is not null and t.deadline is null))
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

create or replace function public.run_my_reminders() returns jsonb
language plpgsql security definer set search_path = public as $$
declare sid uuid := public.my_school_id(); got int;
begin
  if sid is null then return jsonb_build_object('ran', false); end if;
  perform public.expire_overdue_tasks(sid);     -- deadlines are enforced on every app open
  insert into public.reminder_runs (school_id, last_run) values (sid, now())
  on conflict (school_id) do update set last_run = now()
    where public.reminder_runs.last_run < now() - interval '20 minutes';
  get diagnostics got = row_count;
  if got = 0 then return jsonb_build_object('ran', false, 'reason', 'throttled'); end if;
  return jsonb_build_object('ran', true, 'result', public.run_reminders(sid));
end $$;

-- pg_cron (optional): expire deadlines + run reminders every 30 minutes
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('trollify-reminders', '*/30 * * * *', 'select public.expire_overdue_tasks(null); select public.run_reminders(null)');
exception when others then
  raise notice 'pg_cron not available (%). Deadlines/reminders still run whenever staff open the app.', sqlerrm;
end $$;

-- privileges
revoke all on function public.expire_overdue_tasks(uuid) from public, anon, authenticated;
revoke all on function public.expire_my_tasks() from public, anon;
revoke all on function public.bulk_assign_tasks(uuid[], text, uuid[], text) from public, anon;
revoke all on function public.renew_tasks(uuid[], date, uuid[], text) from public, anon;
revoke all on function public.crm_list(uuid, text, text, text, text, int, int, text, uuid, text, text) from public, anon;
grant execute on function public.expire_my_tasks() to authenticated;
grant execute on function public.bulk_assign_tasks(uuid[], text, uuid[], text) to authenticated;
grant execute on function public.renew_tasks(uuid[], date, uuid[], text) to authenticated;
grant execute on function public.crm_list(uuid, text, text, text, text, int, int, text, uuid, text, text) to authenticated;
