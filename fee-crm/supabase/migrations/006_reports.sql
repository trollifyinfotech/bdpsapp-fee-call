-- =====================================================================
-- Migration 006 : Dashboards, paginated lists and report data
-- All aggregation happens in the database; the browser never loads the
-- whole school. Amount columns are NULL unless the caller holds
-- view_fee_amounts (enforced here, not in HTML).
-- =====================================================================

create or replace function public.class_rank(c text) returns int language sql immutable as $$
  select case c when 'Nursery' then 0 when 'LKG' then 1 when 'UKG' then 2
    else coalesce(nullif(regexp_replace(c, '\D', '', 'g'), '')::int, 99) + 2 end
$$;

-- ---------------------------------------------------------------------
-- Fee dashboard
-- ---------------------------------------------------------------------
create or replace function public.fee_summary(p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_sid uuid; v_today date := public.today_local(); res jsonb;
begin
  select school_id into v_sid from public.academic_sessions where id = p_session;
  if v_sid is null or not (public.has_perm(v_sid, 'view_financial_dashboard') or public.has_perm(v_sid, 'view_fee_amounts')) then
    raise exception 'Permission denied: financial dashboard' using errcode = '42501'; end if;

  with b as (select b.*, e.class_name, e.category from public.v_enrollment_balances b
             join public.student_session_enrollments e on e.id = b.enrollment_id
             join public.students s on s.id = e.student_id
             where b.school_id = v_sid and b.session_id = p_session and e.status <> 'left' and s.status = 'active'),
  pay as (select * from public.payments where school_id = v_sid and session_id = p_session and status = 'verified')
  select jsonb_build_object(
    'total_students', (select count(*) from b),
    'gross', (select coalesce(sum(gross),0) from b), 'discount', (select coalesce(sum(discount),0) from b),
    'net', (select coalesce(sum(net),0) from b),
    'collected', (select coalesce(sum(amount),0) from pay),
    'pending', (select coalesce(sum(pending),0) from b),
    'partial_students', (select count(*) from b where pay_status = 'partial'),
    'paid_students', (select count(*) from b where pay_status = 'paid'),
    'unpaid_students', (select count(*) from b where pay_status = 'unpaid'),
    'zero_fee_students', (select count(*) from b where pay_status = 'zero_fee'),
    'rte_students', (select count(*) from b where category = 'rte'),
    'overdue_students', (select count(*) from b where overdue_amount > 0),
    'awaiting_verification', (select coalesce(sum(amount),0) from public.payments where school_id = v_sid and session_id = p_session and status = 'pending'),
    'today_collection', (select coalesce(sum(amount),0) from pay where payment_date = v_today),
    'month_collection', (select coalesce(sum(amount),0) from pay where date_trunc('month', payment_date) = date_trunc('month', v_today::timestamp)),
    'charts', jsonb_build_object(
      'monthly', coalesce((select jsonb_agg(jsonb_build_object('label', to_char(m, 'Mon YY'), 'amount', a) order by m)
                   from (select date_trunc('month', payment_date) m, sum(amount) a from pay group by 1) x), '[]'::jsonb),
      'by_class', coalesce((select jsonb_agg(jsonb_build_object('label', class_name, 'collected', coll, 'pending', pend) order by public.class_rank(class_name))
                   from (select class_name, sum(paid) coll, sum(pending) pend from b group by class_name) x), '[]'::jsonb),
      'by_mode', coalesce((select jsonb_agg(jsonb_build_object('label', mode, 'amount', a)) from
                   (select mode, sum(amount) a from pay group by mode) x), '[]'::jsonb),
      'trend', coalesce((select jsonb_agg(jsonb_build_object('label', to_char(d, 'DD Mon'), 'amount', coalesce(a, 0)) order by d)
                   from generate_series(v_today - 29, v_today, interval '1 day') g(d)
                   left join (select payment_date dd, sum(amount) a from pay group by 1) p on p.dd = g.d::date), '[]'::jsonb),
      'recovery', coalesce((select jsonb_agg(jsonb_build_object('label', to_char(x.m, 'Mon YY'),
                     'pct', case when t.tn = 0 then 0 else round(100.0 * x.cum / t.tn, 1) end) order by x.m)
                   from (select m, sum(a) over (order by m) as cum
                         from (select date_trunc('month', payment_date) m, sum(amount) a from pay group by 1) y) x,
                        (select coalesce(sum(net), 0) as tn from b) t), '[]'::jsonb)
    )) into res;
  return res;
end $$;

-- ---------------------------------------------------------------------
-- Student fee table (server-side filtering + pagination)
-- ---------------------------------------------------------------------
create or replace function public.fee_list(
  p_session uuid, p_search text default null, p_class text default null, p_section text default null,
  p_status text default null, p_category text default null, p_sibling boolean default null,
  p_discounted boolean default null, p_fee_head uuid default null,
  p_adm_from date default null, p_adm_to date default null, p_due_from date default null, p_due_to date default null,
  p_limit int default 25, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_sid uuid; v_fin boolean; v_q text; res jsonb;
begin
  select school_id into v_sid from public.academic_sessions where id = p_session;
  perform public.require_perm(v_sid, 'view_fee_details');
  v_fin := public.has_perm(v_sid, 'view_fee_amounts');
  v_q := nullif(trim(coalesce(p_search, '')), '');
  p_limit := least(greatest(coalesce(p_limit, 25), 1), 5000);

  with base as (
    select e.id as enrollment_id, s.id as student_id, s.student_code, s.admission_no, s.name, s.father_name, s.mother_name,
           e.class_name, e.section, e.roll_no, s.mobile, s.address, s.admission_date, e.category,
           case when v_fin then b.gross end as total_fee, case when v_fin then b.discount end as discount,
           case when v_fin then b.net end as net_fee, case when v_fin then b.paid end as paid_amount,
           case when v_fin then b.pending end as pending_amount, case when v_fin then b.overdue_amount end as overdue_amount,
           b.pay_status, (b.overdue_amount > 0) as is_overdue,
           (select fm.family_id from public.family_members fm where fm.student_id = s.id and fm.removed_at is null limit 1) as family_id,
           (select l.remark from public.calling_logs l where l.student_id = s.id and l.session_id = p_session order by l.called_at desc limit 1) as last_remark,
           (select l.called_at from public.calling_logs l where l.student_id = s.id and l.session_id = p_session order by l.called_at desc limit 1) as last_call_at,
           (select min(f.due_date) from public.follow_up_tasks f where f.student_id = s.id and f.session_id = p_session and f.status in ('pending','overdue')) as next_followup,
           b.discount as _disc, b.pending as _pend, b.net as _net, b.paid as _paid
    from public.student_session_enrollments e
    join public.students s on s.id = e.student_id
    join public.v_enrollment_balances b on b.enrollment_id = e.id
    where e.school_id = v_sid and e.session_id = p_session and s.status = 'active' and e.status <> 'left'
      and (p_class is null or e.class_name = p_class) and (p_section is null or e.section = p_section)
      and (p_category is null or e.category = p_category)
      and (p_adm_from is null or s.admission_date >= p_adm_from) and (p_adm_to is null or s.admission_date <= p_adm_to)
      and (v_q is null or s.name ilike '%' || v_q || '%' or s.father_name ilike '%' || v_q || '%' or s.student_code ilike '%' || v_q || '%'
           or s.admission_no ilike '%' || v_q || '%' or s.mobile like '%' || v_q || '%')
      and (p_status is null or case p_status
             when 'pending' then b.pending > 0 when 'overdue' then b.overdue_amount > 0
             else b.pay_status = p_status end)
      and (p_discounted is null or (b.discount > 0) = p_discounted)
      and (p_sibling is null or exists (select 1 from public.family_members fm where fm.student_id = s.id and fm.removed_at is null
             and (select count(*) from public.family_members x where x.family_id = fm.family_id and x.removed_at is null) > 1) = p_sibling)
      and (p_fee_head is null or exists (select 1 from public.student_fee_assignments a where a.enrollment_id = e.id and a.fee_head_id = p_fee_head and a.status = 'active'))
      and ((p_due_from is null and p_due_to is null) or exists (select 1 from public.fee_installments fi
             join public.student_fee_assignments a on a.id = fi.assignment_id
             where a.enrollment_id = e.id and a.status = 'active'
               and (p_due_from is null or fi.due_date >= p_due_from) and (p_due_to is null or fi.due_date <= p_due_to)))
  ), page as (select * from base order by public.class_rank(class_name), section, name limit p_limit offset p_offset)
  select jsonb_build_object(
     'total', (select count(*) from base),
     'totals', case when v_fin then (select jsonb_build_object('gross', coalesce(sum(total_fee),0), 'discount', coalesce(sum(discount),0),
                  'net', coalesce(sum(net_fee),0), 'paid', coalesce(sum(paid_amount),0), 'pending', coalesce(sum(pending_amount),0)) from base) end,
     'rows', coalesce((select jsonb_agg(to_jsonb(page) - '_disc' - '_pend' - '_net' - '_paid'
                       order by public.class_rank(class_name), section, name) from page), '[]'::jsonb)) into res;
  return res;
end $$;

-- ---------------------------------------------------------------------
-- Transactions / receipts register
-- ---------------------------------------------------------------------
create or replace function public.payments_list(p_session uuid, p_from date default null, p_to date default null,
  p_mode text default null, p_status text default null, p_collector uuid default null, p_search text default null,
  p_student uuid default null, p_limit int default 25, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_sid uuid; v_q text; res jsonb;
begin
  select school_id into v_sid from public.academic_sessions where id = p_session;
  perform public.require_perm(v_sid, 'view_fee_amounts');
  v_q := nullif(trim(coalesce(p_search, '')), '');
  p_limit := least(greatest(coalesce(p_limit, 25), 1), 5000);
  with base as (
    select py.id as payment_id, py.receipt_no, py.txn_id, py.payment_date, py.amount, py.mode, py.status, py.reference,
           py.hard_copy_receipt_no, py.remarks, py.created_at, py.collector_id, cu.full_name as collector_name,
           s.id as student_id, s.name as student_name, s.father_name, s.admission_no, e.class_name, e.section,
           tr.reason as cancel_reason, tr.cancelled_at, cb.full_name as cancelled_by_name,
           (select v.reason from public.payment_verifications v where v.payment_id = py.id order by v.decided_at desc limit 1) as review_reason
    from public.payments py
    join public.students s on s.id = py.student_id
    join public.student_session_enrollments e on e.id = py.enrollment_id
    left join public.user_profiles cu on cu.id = py.collector_id
    left join public.transaction_reversals tr on tr.payment_id = py.id
    left join public.user_profiles cb on cb.id = tr.cancelled_by
    where py.school_id = v_sid and py.session_id = p_session
      and (p_from is null or py.payment_date >= p_from) and (p_to is null or py.payment_date <= p_to)
      and (p_mode is null or py.mode = p_mode) and (p_status is null or py.status = p_status)
      and (p_collector is null or py.collector_id = p_collector) and (p_student is null or py.student_id = p_student)
      and (v_q is null or py.receipt_no ilike '%' || v_q || '%' or py.txn_id ilike '%' || v_q || '%' or s.name ilike '%' || v_q || '%'
           or s.father_name ilike '%' || v_q || '%' or py.hard_copy_receipt_no ilike '%' || v_q || '%')
  ), page as (select * from base order by payment_date desc, created_at desc limit p_limit offset p_offset)
  select jsonb_build_object('total', (select count(*) from base),
     'totals', (select jsonb_build_object('verified', coalesce(sum(amount) filter (where status = 'verified'), 0),
                 'pending', coalesce(sum(amount) filter (where status = 'pending'), 0),
                 'cancelled', coalesce(sum(amount) filter (where status = 'cancelled'), 0),
                 'rejected', coalesce(sum(amount) filter (where status = 'rejected'), 0)) from base),
     'rows', coalesce((select jsonb_agg(to_jsonb(page) order by payment_date desc, created_at desc) from page), '[]'::jsonb)) into res;
  return res;
end $$;

create or replace function public.payments_summary(p_session uuid, p_from date default null, p_to date default null,
  p_mode text default null, p_collector uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_sid uuid; res jsonb;
begin
  select school_id into v_sid from public.academic_sessions where id = p_session;
  perform public.require_perm(v_sid, 'view_fee_amounts');
  with pay as (select py.* from public.payments py where py.school_id = v_sid and py.session_id = p_session and py.status = 'verified'
      and (p_from is null or py.payment_date >= p_from) and (p_to is null or py.payment_date <= p_to)
      and (p_mode is null or py.mode = p_mode) and (p_collector is null or py.collector_id = p_collector))
  select jsonb_build_object(
    'by_day', coalesce((select jsonb_agg(jsonb_build_object('label', payment_date, 'count', n, 'amount', a) order by payment_date)
              from (select payment_date, count(*) n, sum(amount) a from pay group by 1) x), '[]'::jsonb),
    'by_month', coalesce((select jsonb_agg(jsonb_build_object('label', to_char(m, 'Mon YYYY'), 'count', n, 'amount', a) order by m)
              from (select date_trunc('month', payment_date) m, count(*) n, sum(amount) a from pay group by 1) x), '[]'::jsonb),
    'by_mode', coalesce((select jsonb_agg(jsonb_build_object('label', mode, 'count', n, 'amount', a) order by a desc)
              from (select mode, count(*) n, sum(amount) a from pay group by 1) x), '[]'::jsonb),
    'by_collector', coalesce((select jsonb_agg(jsonb_build_object('label', up.full_name, 'count', x.n, 'amount', x.a) order by x.a desc)
              from (select collector_id, count(*) n, sum(amount) a from pay group by 1) x
              join public.user_profiles up on up.id = x.collector_id), '[]'::jsonb)) into res;
  return res;
end $$;

create or replace function public.discounts_list(p_session uuid, p_limit int default 100, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_sid uuid; res jsonb;
begin
  select school_id into v_sid from public.academic_sessions where id = p_session;
  perform public.require_perm(v_sid, 'view_fee_amounts');
  with base as (
    select d.id as discount_id, s.name as student_name, s.father_name, e.class_name, d.discount_type, d.value, d.reason, d.status,
           d.created_at, ap.full_name as approved_by_name, f.name as family_name,
           case when d.discount_type = 'full_waiver' then b.gross when d.discount_type = 'percentage' then round(b.gross * d.value / 100, 2)
                else d.value end as discount_amount, d.policy_id, d.scholarship_id
    from public.student_discounts d
    join public.students s on s.id = d.student_id
    join public.student_session_enrollments e on e.id = d.enrollment_id
    join public.v_enrollment_balances b on b.enrollment_id = d.enrollment_id
    left join public.user_profiles ap on ap.id = d.approved_by
    left join public.families f on f.id = d.family_id
    where d.school_id = v_sid and d.session_id = p_session
  ), page as (select * from base order by created_at desc limit least(p_limit, 5000) offset p_offset)
  select jsonb_build_object('total', (select count(*) from base),
     'rows', coalesce((select jsonb_agg(to_jsonb(page) order by created_at desc) from page), '[]'::jsonb)) into res;
  return res;
end $$;

-- ---------------------------------------------------------------------
-- Families
-- ---------------------------------------------------------------------
create or replace function public.family_overview(p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_sid uuid; v_fin boolean; res jsonb;
begin
  select school_id into v_sid from public.academic_sessions where id = p_session;
  perform public.require_perm(v_sid, 'view_student_list');
  v_fin := public.has_perm(v_sid, 'view_fee_amounts');
  select coalesce(jsonb_agg(fam order by fam ->> 'name'), '[]'::jsonb) into res from (
    select jsonb_build_object('family_id', f.id, 'name', f.name, 'family_ref', f.family_ref, 'mobile', f.primary_mobile,
      'members', coalesce((select jsonb_agg(jsonb_build_object('member_id', fm.id, 'student_id', s.id, 'name', s.name, 'verified', fm.verified,
                 'relationship', fm.relationship, 'class_name', e.class_name, 'enrollment_id', e.id,
                 'gross', case when v_fin then b.gross end, 'discount', case when v_fin then b.discount end,
                 'net', case when v_fin then b.net end, 'paid', case when v_fin then b.paid end, 'pending', case when v_fin then b.pending end)
                 order by s.admission_date, s.name)
        from public.family_members fm join public.students s on s.id = fm.student_id
        left join public.student_session_enrollments e on e.student_id = s.id and e.session_id = p_session
        left join public.v_enrollment_balances b on b.enrollment_id = e.id
        where fm.family_id = f.id and fm.removed_at is null), '[]'::jsonb),
      'policy', (select jsonb_build_object('type', fp.policy_type, 'value', fp.value, 'reason', fp.reason, 'payer', fp.payer_student_id)
                 from public.family_policies fp where fp.family_id = f.id and fp.session_id = p_session and fp.status = 'active' limit 1)
    ) as fam
    from public.families f where f.school_id = v_sid
  ) q;
  return res;
end $$;

-- ---------------------------------------------------------------------
-- RTE / scholarship lists
-- ---------------------------------------------------------------------
create or replace function public.rte_list(p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_sid uuid; res jsonb;
begin
  select school_id into v_sid from public.academic_sessions where id = p_session;
  perform public.require_perm(v_sid, 'manage_rte');
  select jsonb_build_object(
    'rte', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'student_id', s.id, 'student_name', s.name, 'father_name', s.father_name,
        'class_name', e.class_name, 'certificate_no', r.certificate_no, 'valid_from', r.valid_from, 'valid_to', r.valid_to, 'status', r.status,
        'expected', r.reimbursement_expected,
        'received', coalesce((select sum(x.amount) from public.rte_reimbursements x where x.rte_record_id = r.id), 0)) order by s.name)
      from public.rte_records r join public.students s on s.id = r.student_id
      left join public.student_session_enrollments e on e.student_id = s.id and e.session_id = r.session_id
      where r.school_id = v_sid and r.session_id = p_session), '[]'::jsonb),
    'scholarships', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'student_name', s.name, 'class_name', e.class_name, 'name', c.name,
        'amount', c.amount, 'percentage', c.percentage, 'status', c.approval_status, 'remarks', c.remarks) order by s.name)
      from public.scholarship_records c join public.students s on s.id = c.student_id
      left join public.student_session_enrollments e on e.student_id = s.id and e.session_id = c.session_id
      where c.school_id = v_sid and c.session_id = p_session), '[]'::jsonb)) into res;
  return res;
end $$;

-- ---------------------------------------------------------------------
-- Owner summary (daily / monthly)
-- ---------------------------------------------------------------------
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

-- School-level notification helper: mark all read
create or replace function public.mark_notifications_read(p_ids uuid[] default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.notifications set is_read = true, read_at = now()
   where user_id = auth.uid() and not is_read and (p_ids is null or id = any(p_ids));
end $$;
