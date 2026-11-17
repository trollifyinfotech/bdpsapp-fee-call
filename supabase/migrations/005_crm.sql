-- =====================================================================
-- Migration 005 : Calling CRM, promises, follow-ups, reminder engine
--
-- Privacy: calling functions NEVER return fee amounts unless the caller
-- holds view_fee_amounts. This is enforced here (database), not in HTML.
-- A dialer launch is NOT a call: only a saved calling_logs row counts.
-- =====================================================================

-- Statuses that mean a conversation happened (parent was reached)
create or replace function public.call_is_connected(s text) returns boolean language sql immutable as $$
  select s in ('connected','callback_requested','promised_to_pay','refused','payment_done','dispute')
$$;

-- ---------------------------------------------------------------------
-- Task assignment
-- ---------------------------------------------------------------------
create or replace function public.create_calling_tasks(
  p_session uuid, p_mode text, p_class text default null, p_student_ids uuid[] default null,
  p_teacher_ids uuid[] default null, p_priority text default 'normal', p_deadline date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_sid uuid; c record; v_n int := 0; v_idx int := 0; v_teacher uuid; v_exist int := 0; v_zero int := 0;
  v_cnt int; t uuid; v_per jsonb := '{}'::jsonb; v_ids uuid[]; v_id uuid;
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
    if exists (select 1 from public.calling_tasks where school_id = v_sid and session_id = p_session
               and student_id = c.student_id and status in ('pending','in_progress','promised')) then
      v_exist := v_exist + 1; continue;
    end if;
    v_teacher := p_teacher_ids[(v_idx % cardinality(p_teacher_ids)) + 1];
    insert into public.calling_tasks (school_id, session_id, student_id, enrollment_id, assigned_to, assigned_by, priority, deadline)
    values (v_sid, p_session, c.student_id, c.enr, v_teacher, auth.uid(), coalesce(p_priority,'normal'), p_deadline)
    returning id into v_id;
    insert into public.task_assignment_history (school_id, task_id, from_user, to_user, changed_by, reason)
    values (v_sid, v_id, null, v_teacher, auth.uid(), 'Initial assignment');
    v_per := jsonb_set(v_per, array[v_teacher::text], to_jsonb(coalesce((v_per ->> v_teacher::text)::int, 0) + 1));
    v_idx := v_idx + 1; v_n := v_n + 1;
  end loop;

  for t in select key::uuid from jsonb_each(v_per) loop
    perform public.notify(v_sid, t, 'new_calling_task', 'New calling tasks assigned',
       (v_per ->> t::text) || ' student(s) assigned to you for fee follow-up', '/app.html#/crm/today',
       'newtask:' || t || ':' || to_char(now(), 'YYYYMMDDHH24MI'));
  end loop;
  return jsonb_build_object('created', v_n, 'skipped_already_assigned', v_exist, 'skipped_no_pending_fee', v_zero);
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
  update public.calling_tasks set assigned_to = p_to where id = t.id;
  update public.follow_up_tasks set assigned_to = p_to where task_id = t.id and status in ('pending','overdue');
  insert into public.task_assignment_history (school_id, task_id, from_user, to_user, changed_by, reason)
  values (t.school_id, t.id, t.assigned_to, p_to, auth.uid(), p_reason);
  perform public.notify(t.school_id, p_to, 'task_reassigned', 'Task reassigned to you',
     'A calling task was reassigned to you', '/app.html#/crm/today', 'reassign:' || t.id || ':' || to_char(now(),'YYYYMMDDHH24MISS'));
end $$;

create or replace function public.cancel_calling_task(p_task uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare t public.calling_tasks;
begin
  select * into t from public.calling_tasks where id = p_task for update;
  perform public.require_perm(t.school_id, 'assign_calling_tasks');
  update public.calling_tasks set status = 'cancelled' where id = t.id and status in ('pending','in_progress','promised');
  update public.follow_up_tasks set status = 'cancelled' where task_id = t.id and status in ('pending','overdue');
end $$;

create or replace function public.complete_task(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.calling_tasks;
begin
  select * into t from public.calling_tasks where id = p_task for update;
  if not found then raise exception 'Task not found'; end if;
  if not (t.assigned_to = auth.uid() or public.has_perm(t.school_id, 'assign_calling_tasks')) then
    raise exception 'Not your task' using errcode = '42501'; end if;
  perform public.require_perm(t.school_id, 'make_calls');
  if t.call_count = 0 then raise exception 'Record at least one call before completing the task'; end if;
  if exists (select 1 from public.payment_promises where task_id = t.id and status in ('pending','overdue')) then
    raise exception 'A payment promise is still open for this student. It closes automatically when payment is verified.';
  end if;
  update public.calling_tasks set status = 'completed', completed_at = now() where id = t.id;
  update public.follow_up_tasks set status = 'done', completed_at = now() where task_id = t.id and status in ('pending','overdue');
end $$;

create or replace function public.set_teacher_target(p_teacher uuid, p_daily int, p_from date default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_sid uuid := public.my_school_id();
begin
  perform public.require_perm(v_sid, 'assign_calling_tasks');
  insert into public.teacher_calling_targets (school_id, teacher_id, daily_target, effective_from, set_by)
  values (v_sid, p_teacher, p_daily, coalesce(p_from, public.today_local()), auth.uid())
  on conflict (school_id, teacher_id, effective_from) do update set daily_target = excluded.daily_target, set_by = auth.uid();
end $$;

-- ---------------------------------------------------------------------
-- Call logging (history is append-only)
-- ---------------------------------------------------------------------
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
    if t.assigned_to <> auth.uid() and not public.has_perm(v_sid, 'assign_calling_tasks') then
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

  v_assignee := coalesce(t.assigned_to, auth.uid());
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

-- ---------------------------------------------------------------------
-- Auto-resolution when a verified payment arrives
-- ---------------------------------------------------------------------
create or replace function public.resolve_student_tasks(p_student uuid, p_session uuid, p_payment uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare pr record; v_paid numeric; v_pending numeric; t record;
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
      perform public.notify(t.school_id, t.assigned_to, 'fee_payment_received', 'Fee received - task resolved',
         'Fee has been fully received for a student on your list. The task was closed automatically.', '/app.html#/crm/history',
         'resolved:' || t.id);
    end loop;
  end if;
end $$;
revoke all on function public.resolve_student_tasks(uuid, uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Reminder engine (idempotent; every insert is guarded by a dedupe key)
-- Called by the reminder-engine Edge Function (service role) or pg_cron.
-- ---------------------------------------------------------------------
create or replace function public.run_reminders(p_school uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s record; cfg jsonb; v_today date := public.today_local(); r record; v_assignee uuid;
  c_due int := 0; c_over int := 0; c_fu_due int := 0; c_fu_over int := 0; c_nrc int := 0; c_esc int := 0; c_new int := 0;
  max_rem int; nrc_days int; esc_p int; esc_o int; tid uuid; v_active uuid;
begin
  for s in select id from public.schools where status = 'active' and (p_school is null or id = p_school) and public.school_is_usable(id) loop
    select coalesce(value, '{}'::jsonb) into cfg from public.school_settings where school_id = s.id and key = 'crm';
    cfg := coalesce(cfg, '{}'::jsonb);
    max_rem := coalesce((cfg ->> 'max_reminders')::int, 3);
    nrc_days := coalesce((cfg ->> 'no_recent_call_days')::int, 7);
    esc_p := coalesce((cfg ->> 'escalate_principal_after_days')::int, 3);
    esc_o := coalesce((cfg ->> 'escalate_owner_after_days')::int, 7);

    -- (6) resolve anything already covered by verified payments
    for r in select distinct student_id, session_id from public.payment_promises
              where school_id = s.id and status in ('pending','overdue') loop
      perform public.resolve_student_tasks(r.student_id, r.session_id, null);
    end loop;

    -- (1) promise date is today
    for r in select p.*, t.assigned_to as task_user, t.status as task_status from public.payment_promises p
             left join public.calling_tasks t on t.id = p.task_id
             where p.school_id = s.id and p.status = 'pending' and p.promised_date = v_today loop
      v_assignee := coalesce(case when r.task_status in ('pending','in_progress','promised') then r.task_user end, r.promised_by_user);
      insert into public.follow_up_tasks (school_id, session_id, task_id, student_id, assigned_to, kind, due_date, promise_id, dedupe_key)
      values (s.id, r.session_id, r.task_id, r.student_id, v_assignee, 'promise_due', v_today, r.id, 'pdue:' || r.id)
      on conflict (school_id, dedupe_key) do nothing;
      perform public.notify(s.id, v_assignee, 'follow_up_due', 'Promised payment due today',
         'A parent promised to pay today. Call to confirm.', '/app.html#/crm/today', 'pdue-n:' || r.id || ':' || v_today);
      c_due := c_due + 1;
    end loop;

    -- (2) promise date passed with no verified payment => overdue + new task + notifications
    for r in select p.*, t.assigned_to as task_user, t.status as task_status from public.payment_promises p
             left join public.calling_tasks t on t.id = p.task_id
             where p.school_id = s.id and p.status = 'pending' and p.promised_date < v_today loop
      update public.payment_promises set status = 'overdue' where id = r.id;
      v_assignee := coalesce(case when r.task_status in ('pending','in_progress','promised') then r.task_user end, r.promised_by_user);
      select id into v_active from public.calling_tasks where school_id = s.id and session_id = r.session_id
        and student_id = r.student_id and status in ('pending','in_progress','promised');
      if v_active is null then
        insert into public.calling_tasks (school_id, session_id, student_id, enrollment_id, assigned_to, priority, deadline)
        values (s.id, r.session_id, r.student_id, r.enrollment_id, v_assignee, 'high', v_today + 2)
        returning id into v_active;
        insert into public.task_assignment_history (school_id, task_id, from_user, to_user, reason)
        values (s.id, v_active, null, v_assignee, 'Auto-created: promised payment overdue');
        c_new := c_new + 1;
      else
        update public.calling_tasks set status = 'in_progress', priority = 'high' where id = v_active and status = 'promised';
      end if;
      insert into public.follow_up_tasks (school_id, session_id, task_id, student_id, assigned_to, kind, due_date, promise_id, dedupe_key)
      values (s.id, r.session_id, v_active, r.student_id, v_assignee, 'promise_overdue', v_today, r.id, 'povd:' || r.id)
      on conflict (school_id, dedupe_key) do nothing;
      perform public.notify(s.id, v_assignee, 'promise_overdue', 'Promised payment overdue',
         'The promised payment date has passed without a verified payment.', '/app.html#/crm/overdue', 'povd-t:' || r.id);
      perform public.notify_perm(s.id, 'assign_calling_tasks', 'promise_overdue', 'Promised payment overdue',
         'A parent missed a payment promise. A new task was created.', '/app.html#/crm/overdue', 'povd-a:' || r.id);
      c_over := c_over + 1;
    end loop;

    -- (3) follow-ups due today (bounded by max_reminders, at most one per day)
    for r in select * from public.follow_up_tasks where school_id = s.id and status = 'pending' and due_date = v_today
               and reminder_count < max_rem loop
      perform public.notify(s.id, r.assigned_to, 'follow_up_due', 'Follow-up due today',
         'You have a parent follow-up scheduled for today.', '/app.html#/crm/today', 'fu-due:' || r.id || ':' || v_today);
      update public.follow_up_tasks set reminder_count = reminder_count + 1, last_reminded_at = now() where id = r.id;
      c_fu_due := c_fu_due + 1;
    end loop;

    -- (4) overdue follow-ups + escalation
    for r in select * from public.follow_up_tasks where school_id = s.id and status in ('pending','overdue') and due_date < v_today loop
      if r.status = 'pending' then
        update public.follow_up_tasks set status = 'overdue' where id = r.id;
        perform public.notify(s.id, r.assigned_to, 'follow_up_overdue', 'Follow-up overdue',
           'A follow-up date was missed. Please call the parent.', '/app.html#/crm/overdue', 'fu-ovd:' || r.id);
        perform public.notify_perm(s.id, 'view_teacher_performance', 'follow_up_overdue', 'Teacher follow-up overdue',
           'A teacher missed a follow-up date.', '/app.html#/crm/overdue', 'fu-ovd-a:' || r.id);
        c_fu_over := c_fu_over + 1;
      end if;
      if v_today - r.due_date >= esc_p then
        perform public.notify_roles(s.id, array['principal'], 'follow_up_overdue', 'Escalation: follow-up overdue',
           'A follow-up has been overdue for ' || (v_today - r.due_date) || ' days.', '/app.html#/crm/overdue', 'esc-p:' || r.id);
        c_esc := c_esc + 1;
      end if;
      if v_today - r.due_date >= esc_o then
        perform public.notify_roles(s.id, array['school_owner'], 'follow_up_overdue', 'Escalation: follow-up overdue',
           'A follow-up has been overdue for ' || (v_today - r.due_date) || ' days.', '/app.html#/crm/overdue', 'esc-o:' || r.id);
      end if;
    end loop;

    -- (5) pending fee but no recent call
    for r in select t.* from public.calling_tasks t join public.v_enrollment_balances b on b.enrollment_id = t.enrollment_id
             where t.school_id = s.id and t.status in ('pending','in_progress') and b.pending > 0
               and coalesce(t.last_call_at, t.created_at) < now() - make_interval(days => nrc_days)
               and not exists (select 1 from public.follow_up_tasks f where f.task_id = t.id and f.status in ('pending','overdue')) loop
      insert into public.follow_up_tasks (school_id, session_id, task_id, student_id, assigned_to, kind, due_date, dedupe_key)
      values (s.id, r.session_id, r.id, r.student_id, r.assigned_to, 'no_recent_call', v_today,
              'nrc:' || r.id || ':' || to_char(v_today, 'IYYY-IW'))
      on conflict (school_id, dedupe_key) do nothing;
      if found then
        perform public.notify(s.id, r.assigned_to, 'follow_up_due', 'Student not called recently',
           'No call has been recorded for a student with pending fee in ' || nrc_days || ' days.', '/app.html#/crm/today',
           'nrc-n:' || r.id || ':' || to_char(v_today, 'IYYY-IW'));
        c_nrc := c_nrc + 1;
      end if;
    end loop;

    -- daily owner report availability
    perform public.notify_roles(s.id, array['school_owner','principal'], 'daily_report', 'Daily calling report available',
       'Open Reports > Owner Summary to view today''s calling report.', '/app.html#/reports', 'daily:' || v_today);
  end loop;
  return jsonb_build_object('promise_due_today', c_due, 'promises_overdue', c_over, 'tasks_auto_created', c_new,
     'followups_due_today', c_fu_due, 'followups_overdue', c_fu_over, 'no_recent_call', c_nrc, 'escalations', c_esc);
end $$;
revoke all on function public.run_reminders(uuid) from public, anon, authenticated;
grant execute on function public.run_reminders(uuid) to service_role;

-- ---------------------------------------------------------------------
-- CRM lists (jsonb {total, rows}) - amounts only for view_fee_amounts
-- ---------------------------------------------------------------------
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
           t.id as task_id, t.assigned_to, up.full_name as assigned_name, t.status as task_status, t.priority as task_priority,
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
      and (p_scope <> 'mine' or t.assigned_to = auth.uid())
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

create or replace function public.followups_list(p_session uuid, p_when text default 'today', p_teacher uuid default null,
  p_limit int default 50, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_sid uuid; v_admin boolean; v_today date := public.today_local(); res jsonb; v_addr boolean;
begin
  select school_id into v_sid from public.academic_sessions where id = p_session;
  perform public.require_perm(v_sid, 'view_calling_crm');
  v_admin := public.has_perm(v_sid, 'assign_calling_tasks') or public.has_perm(v_sid, 'view_teacher_performance');
  v_addr := public.has_perm(v_sid, 'view_student_list');
  if not v_admin then p_teacher := auth.uid(); end if;
  p_limit := least(greatest(coalesce(p_limit, 50), 1), 200);
  with base as (
    select f.id as followup_id, f.kind, f.due_date, f.due_time, f.status, f.task_id, f.assigned_to, up.full_name as assigned_name,
           s.id as student_id, s.name, s.father_name, s.mobile, case when v_addr then s.address end as address,
           e.class_name, e.section, f.reminder_count,
           t.last_call_at, t.last_remark, t.call_count, p.promised_date
    from public.follow_up_tasks f
    join public.students s on s.id = f.student_id
    join public.student_session_enrollments e on e.student_id = s.id and e.session_id = f.session_id
    left join public.calling_tasks t on t.id = f.task_id
    left join public.payment_promises p on p.id = f.promise_id
    left join public.user_profiles up on up.id = f.assigned_to
    where f.school_id = v_sid and f.session_id = p_session and f.status in ('pending','overdue')
      and (p_teacher is null or f.assigned_to = p_teacher)
      and (case p_when when 'today' then f.due_date = v_today
                       when 'overdue' then f.due_date < v_today
                       when 'upcoming' then f.due_date > v_today
                       else true end)
  ), page as (select * from base order by due_date, due_time nulls last limit p_limit offset p_offset)
  select jsonb_build_object('total', (select count(*) from base),
         'rows', coalesce((select jsonb_agg(to_jsonb(page) order by due_date, due_time nulls last) from page), '[]'::jsonb)) into res;
  return res;
end $$;

create or replace function public.calls_list(p_session uuid, p_from date default null, p_to date default null,
  p_teacher uuid default null, p_status text default null, p_search text default null, p_student uuid default null,
  p_limit int default 50, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_sid uuid; v_admin boolean; v_q text; res jsonb;
begin
  select school_id into v_sid from public.academic_sessions where id = p_session;
  perform public.require_perm(v_sid, 'view_calling_crm');
  v_admin := public.has_perm(v_sid, 'assign_calling_tasks') or public.has_perm(v_sid, 'view_teacher_performance')
             or public.has_perm(v_sid, 'view_student_list');
  if not v_admin then p_teacher := auth.uid(); end if;     -- teachers only ever see their own calls
  v_q := nullif(trim(coalesce(p_search, '')), '');
  p_limit := least(greatest(coalesce(p_limit, 50), 1), 500);
  with base as (
    select l.id as log_id, l.called_at, l.call_status, l.outcome, l.parent_response, l.remark, l.promised_date,
           l.next_followup_date, l.followup_time, l.priority, l.notes, l.parent_name, l.parent_mobile,
           l.called_by, up.full_name as teacher_name, s.id as student_id, s.name as student_name, s.father_name,
           e.class_name, e.section, public.call_is_connected(l.call_status) as connected
    from public.calling_logs l
    join public.students s on s.id = l.student_id
    left join public.student_session_enrollments e on e.student_id = s.id and e.session_id = l.session_id
    left join public.user_profiles up on up.id = l.called_by
    where l.school_id = v_sid and l.session_id = p_session
      and (p_teacher is null or l.called_by = p_teacher)
      and (p_student is null or l.student_id = p_student)
      and (p_status is null or l.call_status = p_status)
      and (p_from is null or (l.called_at at time zone 'Asia/Kolkata')::date >= p_from)
      and (p_to is null or (l.called_at at time zone 'Asia/Kolkata')::date <= p_to)
      and (v_q is null or s.name ilike '%' || v_q || '%' or s.father_name ilike '%' || v_q || '%' or l.remark ilike '%' || v_q || '%')
  ), page as (select * from base order by called_at desc limit p_limit offset p_offset)
  select jsonb_build_object('total', (select count(*) from base),
         'rows', coalesce((select jsonb_agg(to_jsonb(page) order by called_at desc) from page), '[]'::jsonb)) into res;
  return res;
end $$;

create or replace function public.promises_list(p_session uuid, p_status text default null, p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_sid uuid; v_admin boolean; v_fin boolean; res jsonb;
begin
  select school_id into v_sid from public.academic_sessions where id = p_session;
  perform public.require_perm(v_sid, 'view_calling_crm');
  v_admin := public.has_perm(v_sid, 'assign_calling_tasks') or public.has_perm(v_sid, 'view_teacher_performance');
  v_fin := public.has_perm(v_sid, 'view_fee_amounts');
  with base as (
    select p.id as promise_id, p.promised_date, p.status, case when v_fin then p.promised_amount end as promised_amount,
           p.created_at, s.name as student_name, s.father_name, e.class_name, up.full_name as teacher_name
    from public.payment_promises p
    join public.students s on s.id = p.student_id
    left join public.student_session_enrollments e on e.id = p.enrollment_id
    left join public.user_profiles up on up.id = p.promised_by_user
    where p.school_id = v_sid and p.session_id = p_session and (p_status is null or p.status = p_status)
      and (v_admin or p.promised_by_user = auth.uid())
  ), page as (select * from base order by promised_date desc limit least(p_limit, 500) offset p_offset)
  select jsonb_build_object('total', (select count(*) from base),
         'rows', coalesce((select jsonb_agg(to_jsonb(page) order by promised_date desc) from page), '[]'::jsonb)) into res;
  return res;
end $$;

-- ---------------------------------------------------------------------
-- Dashboards and teacher performance
-- ---------------------------------------------------------------------
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
          and (v_admin or exists (select 1 from public.calling_tasks t where t.enrollment_id = e.id and t.assigned_to = v_me
                                  and t.status in ('pending','in_progress','promised')))),
    'pending_tasks', (select count(*) from public.calling_tasks where school_id = v_sid and session_id = p_session
        and status in ('pending','in_progress','promised') and (v_admin or assigned_to = v_me)),
    'calls_today', v_calls_today,
    'completed_tasks', (select count(*) from public.calling_tasks where school_id = v_sid and session_id = p_session
        and status = 'completed' and (v_admin or assigned_to = v_me)),
    'not_called', (select count(*) from public.calling_tasks where school_id = v_sid and session_id = p_session
        and status in ('pending','in_progress','promised') and call_count = 0 and (v_admin or assigned_to = v_me)),
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
        and status in ('pending','in_progress','promised') and deadline < v_today and (v_admin or assigned_to = v_me)),
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

-- Transparent score. Components with no data are excluded (never invented) and the
-- remaining weights are re-normalised:
--   Coverage   40%  distinct students called in range / tasks assigned to the teacher
--   Follow-up  30%  follow-ups completed on/before due date / (completed + still overdue)
--   Connect    10%  connected calls / total calls
--   Recovery   20%  promises kept / promises made
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
    select assigned_to, count(*) filter (where status <> 'cancelled') assigned_tasks,
           count(distinct student_id) filter (where status in ('pending','in_progress','promised')) assigned_students,
           count(*) filter (where status in ('pending','in_progress','promised') and deadline < v_today) overdue_tasks,
           count(*) filter (where status = 'completed') completed_tasks
    from public.calling_tasks where school_id = v_sid and session_id = p_session group by assigned_to
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
