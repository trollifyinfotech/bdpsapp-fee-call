-- =====================================================================
-- Migration 004 : Balances (derived), fee assignment, payments, receipts
--
-- Relationship summary
--   students (permanent)  1--n  student_session_enrollments (per session: class/section/category)
--   enrollment            1--n  student_fee_assignments (one fee line per head)
--   assignment            1--n  fee_installments (due dates)
--   enrollment            1--n  student_discounts (concessions, per student)
--   enrollment            1--n  payments (ledger, append-only)
--   payment               1--n  payment_allocations (sum == payment.amount)
--   payment (verified)    1--1  receipts
--   payment (cancelled)   1--1  transaction_reversals
-- Balance = SUM(active assignments) - discounts - SUM(allocations of VERIFIED payments)
-- =====================================================================

create or replace view public.v_enrollment_balances with (security_invoker = true) as
with g as (
  select enrollment_id, sum(amount) as gross
  from public.student_fee_assignments where status = 'active' group by enrollment_id
), d as (
  select dd.enrollment_id,
         sum(case dd.discount_type
               when 'full_waiver' then coalesce(g.gross, 0)
               when 'percentage'  then round(coalesce(g.gross, 0) * dd.value / 100, 2)
               else dd.value end) as disc
  from public.student_discounts dd left join g on g.enrollment_id = dd.enrollment_id
  where dd.status = 'active' group by dd.enrollment_id
), p as (
  select py.enrollment_id,
         sum(pa.amount) filter (where pa.assignment_id is not null) as paid,
         sum(pa.amount) filter (where pa.assignment_id is null)     as advance
  from public.payments py join public.payment_allocations pa on pa.payment_id = py.id
  where py.status = 'verified' group by py.enrollment_id
), pend as (
  select py.enrollment_id, sum(pa.amount) as awaiting
  from public.payments py join public.payment_allocations pa on pa.payment_id = py.id
  where py.status = 'pending' and pa.assignment_id is not null group by py.enrollment_id
), due as (
  select sfa.enrollment_id, sum(fi.amount) as due_to_date
  from public.fee_installments fi join public.student_fee_assignments sfa on sfa.id = fi.assignment_id
  where sfa.status = 'active' and fi.due_date < public.today_local() group by sfa.enrollment_id
)
select e.id as enrollment_id, e.school_id, e.session_id, e.student_id,
       coalesce(g.gross, 0)                                                       as gross,
       least(coalesce(d.disc, 0), coalesce(g.gross, 0))                           as discount,
       coalesce(g.gross, 0) - least(coalesce(d.disc, 0), coalesce(g.gross, 0))    as net,
       coalesce(p.paid, 0)                                                        as paid,
       coalesce(p.advance, 0)                                                     as advance,
       greatest(coalesce(g.gross, 0) - least(coalesce(d.disc, 0), coalesce(g.gross, 0)) - coalesce(p.paid, 0), 0) as pending,
       coalesce(pend.awaiting, 0)                                                 as awaiting_verification,
       greatest(least(coalesce(g.gross, 0) - least(coalesce(d.disc, 0), coalesce(g.gross, 0)), coalesce(due.due_to_date, 0))
                - coalesce(p.paid, 0), 0)                                         as overdue_amount,
       case
         when coalesce(g.gross, 0) - least(coalesce(d.disc, 0), coalesce(g.gross, 0)) = 0 then 'zero_fee'
         when coalesce(g.gross, 0) - least(coalesce(d.disc, 0), coalesce(g.gross, 0)) - coalesce(p.paid, 0) <= 0 then 'paid'
         when coalesce(p.paid, 0) = 0 then 'unpaid'
         else 'partial' end                                                       as pay_status
from public.student_session_enrollments e
left join g on g.enrollment_id = e.id
left join d on d.enrollment_id = e.id
left join p on p.enrollment_id = e.id
left join pend on pend.enrollment_id = e.id
left join due on due.enrollment_id = e.id;

-- ---------------------------------------------------------------------
-- Fee assignment
-- ---------------------------------------------------------------------
create or replace function public._make_installments(p_assignment uuid, p_sid uuid, p_session uuid, p_amount numeric,
  p_freq text, p_count int, p_first date) returns void
language plpgsql security definer set search_path = public as $$
declare n int; step int; start date; per numeric; i int; dd int;
begin
  n := case p_freq when 'annual' then 1 when 'one_time' then 1 when 'monthly' then 12
                   when 'quarterly' then 4 when 'half_yearly' then 2 else greatest(coalesce(p_count,1),1) end;
  step := case when n = 1 then 0 else greatest(12 / n, 1) end;
  select coalesce((select (value #>> '{}')::int from public.school_settings where school_id=p_sid and key='default_due_days'),30)
    into dd;
  start := coalesce(p_first, (select start_date from public.academic_sessions where id=p_session) + dd);
  per := round(p_amount / n, 2);
  delete from public.fee_installments where assignment_id = p_assignment;
  for i in 1..n loop
    insert into public.fee_installments (school_id, session_id, assignment_id, installment_no, due_date, amount)
    values (p_sid, p_session, p_assignment, i, (start + make_interval(months => step * (i - 1)))::date,
            case when i = n then p_amount - per * (n - 1) else per end);
  end loop;
end $$;
revoke all on function public._make_installments(uuid,uuid,uuid,numeric,text,int,date) from public, anon, authenticated;

create or replace function public._assign_fees(p_sid uuid, p_session uuid, p_enrollment uuid) returns int
language plpgsql security definer set search_path = public as $$
declare e public.student_session_enrollments; fs record; aid uuid; n int := 0;
begin
  select * into e from public.student_session_enrollments where id = p_enrollment and school_id = p_sid;
  if not found then return 0; end if;
  for fs in
    select distinct on (f.fee_head_id) f.* from public.fee_structures f
    where f.school_id = p_sid and f.session_id = p_session and f.class_name = e.class_name
      and (f.section is null or f.section = e.section)
      and (f.category is null or f.category = e.category)
      and not f.is_optional
      and not (e.category = 'rte' and f.category is null)     -- RTE: parent fee zero unless an RTE-specific line exists
    order by f.fee_head_id, (f.category is not null) desc, (f.section is not null) desc
  loop
    if exists (select 1 from public.student_fee_assignments where enrollment_id = e.id and fee_head_id = fs.fee_head_id
               and status = 'active' and structure_id is distinct from fs.id) then continue; end if;
    insert into public.student_fee_assignments (school_id, session_id, enrollment_id, student_id, fee_head_id, structure_id, amount, source, created_by)
    values (p_sid, p_session, e.id, e.student_id, fs.fee_head_id, fs.id, fs.amount, 'structure', auth.uid())
    on conflict (enrollment_id, structure_id) where structure_id is not null
      do update set status = 'active', amount = excluded.amount
      where public.student_fee_assignments.status = 'cancelled'
    returning id into aid;
    if aid is not null then
      perform public._make_installments(aid, p_sid, p_session, fs.amount, fs.frequency, fs.installments_count, fs.first_due_date);
      n := n + 1;
    end if;
    aid := null;
  end loop;
  return n;
end $$;
revoke all on function public._assign_fees(uuid,uuid,uuid) from public, anon, authenticated;

create or replace function public._set_specific_fee(p_sid uuid, p_session uuid, p_enrollment uuid, p_head text,
  p_amount numeric, p_reason text, p_source text default 'student_specific') returns uuid
language plpgsql security definer set search_path = public as $$
declare hid uuid; aid uuid; st uuid;
begin
  select id into hid from public.fee_heads where school_id = p_sid and lower(name) = lower(p_head);
  if hid is null then
    insert into public.fee_heads (school_id, name) values (p_sid, p_head) returning id into hid;
  end if;
  select student_id into st from public.student_session_enrollments where id = p_enrollment;
  insert into public.student_fee_assignments (school_id, session_id, enrollment_id, student_id, fee_head_id, amount, source, reason, created_by)
  values (p_sid, p_session, p_enrollment, st, hid, p_amount, p_source, p_reason, auth.uid())
  on conflict (enrollment_id, fee_head_id) where source in ('student_specific','carry_forward') and status = 'active'
    do update set amount = excluded.amount, reason = excluded.reason
  returning id into aid;
  perform public._make_installments(aid, p_sid, p_session, p_amount, 'annual', 1, null);
  return aid;
end $$;
revoke all on function public._set_specific_fee(uuid,uuid,uuid,text,numeric,text,text) from public, anon, authenticated;

create or replace function public.apply_structure_to_session(p_session uuid, p_class text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sid uuid; e record; total int := 0; ens int := 0;
begin
  select school_id into sid from public.academic_sessions where id = p_session;
  perform public.require_perm(sid, 'edit_fee_structure');
  if not public.session_is_open(sid, p_session) then raise exception 'Session is closed'; end if;
  for e in select id from public.student_session_enrollments
           where session_id = p_session and status = 'active' and (p_class is null or class_name = p_class) loop
    total := total + public._assign_fees(sid, p_session, e.id); ens := ens + 1;
  end loop;
  return jsonb_build_object('enrollments', ens, 'fee_lines_created', total);
end $$;

create or replace function public.set_student_fee(p_enrollment uuid, p_head uuid, p_amount numeric, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare e public.student_session_enrollments; a uuid; hname text;
begin
  select * into e from public.student_session_enrollments where id = p_enrollment;
  perform public.require_perm(e.school_id, 'edit_fee_structure');
  if not public.session_is_open(e.school_id, e.session_id) then raise exception 'Session is closed'; end if;
  select id into a from public.student_fee_assignments where enrollment_id = e.id and fee_head_id = p_head and status = 'active';
  if a is not null then
    perform public.adjust_fee(a, p_amount, p_reason);
    return a;
  end if;
  select name into hname from public.fee_heads where id = p_head and school_id = e.school_id;
  if hname is null then raise exception 'Fee head not found'; end if;
  return public._set_specific_fee(e.school_id, e.session_id, e.id, hname, p_amount, p_reason);
end $$;

create or replace function public.adjust_fee(p_assignment uuid, p_new numeric, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare a public.student_fee_assignments; allocated numeric; cnt int; first_due date;
begin
  select * into a from public.student_fee_assignments where id = p_assignment for update;
  if not found then raise exception 'Fee line not found'; end if;
  perform public.require_perm(a.school_id, 'edit_fee_structure');
  if not public.session_is_open(a.school_id, a.session_id) then raise exception 'Session is closed'; end if;
  if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Reason is required for fee adjustments'; end if;
  if p_new is null or p_new < 0 then raise exception 'Invalid amount'; end if;
  select coalesce(sum(pa.amount),0) into allocated from public.payment_allocations pa
    join public.payments py on py.id = pa.payment_id where pa.assignment_id = a.id and py.status in ('verified','pending');
  if p_new < allocated then
    raise exception 'New amount (%) is below the amount already paid against this fee line (%). Cancel the payment first.', p_new, allocated;
  end if;
  insert into public.fee_adjustments (school_id, session_id, assignment_id, old_amount, new_amount, reason, adjusted_by)
  values (a.school_id, a.session_id, a.id, a.amount, p_new, p_reason, auth.uid());
  select count(*), min(due_date) into cnt, first_due from public.fee_installments where assignment_id = a.id;
  update public.student_fee_assignments set amount = p_new where id = a.id;
  perform public._make_installments(a.id, a.school_id, a.session_id, p_new, 'installment', greatest(cnt,1), first_due);
end $$;

create or replace function public.carry_forward_dues(p_from uuid, p_to uuid, p_student_ids uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sid uuid; sid2 uuid; r record; n int := 0; fname text; toenr uuid;
begin
  select school_id, name into sid, fname from public.academic_sessions where id = p_from;
  select school_id into sid2 from public.academic_sessions where id = p_to;
  if sid is null or sid <> sid2 then raise exception 'Sessions must belong to your school'; end if;
  perform public.require_perm(sid, 'manage_sessions');
  perform public.require_perm(sid, 'edit_fee_structure');
  if not public.session_is_open(sid, p_to) then raise exception 'Target session is closed'; end if;
  for r in select b.student_id, b.pending from public.v_enrollment_balances b
           where b.session_id = p_from and b.pending > 0 and (p_student_ids is null or b.student_id = any(p_student_ids)) loop
    select id into toenr from public.student_session_enrollments where session_id = p_to and student_id = r.student_id;
    if toenr is null then continue; end if;
    perform public._set_specific_fee(sid, p_to, toenr, 'Previous Dues', r.pending, 'Carried forward from ' || fname, 'carry_forward');
    n := n + 1;
  end loop;
  perform public.audit_write(sid, 'dues.carry_forward', 'academic_sessions', p_to::text, null,
          jsonb_build_object('from', p_from, 'students', n), 'Explicitly approved carry forward');
  return jsonb_build_object('carried_students', n);
end $$;

-- ---------------------------------------------------------------------
-- Payments
-- ---------------------------------------------------------------------
create or replace function public.collect_payment(
  p_enrollment uuid, p_amount numeric, p_date date, p_mode text,
  p_reference text default null, p_hard_receipt text default null, p_remarks text default null,
  p_idempotency_key text default null, p_attachment text default null,
  p_allocations jsonb default null, p_allow_advance boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e public.student_session_enrollments; sess public.academic_sessions; bal record; ex public.payments;
  available numeric; adv numeric := 0; to_alloc numeric; rules jsonb; need_approval boolean; st text;
  pid uuid; rno text; tno text; a record; rem numeric; take numeric; x jsonb; sum_x numeric := 0;
  allow_adv boolean;
begin
  select * into e from public.student_session_enrollments where id = p_enrollment;
  if not found then raise exception 'Enrollment not found'; end if;
  perform public.require_perm(e.school_id, 'collect_fee');
  select * into sess from public.academic_sessions where id = e.session_id;
  if sess.status <> 'open' then raise exception 'Session % is closed. Re-open it to collect fees.', sess.name; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Payment amount must be greater than zero'; end if;
  if p_amount <> round(p_amount, 2) then raise exception 'Amount can have at most 2 decimals'; end if;
  if p_date is null or p_date > public.today_local() then raise exception 'Payment date cannot be in the future'; end if;
  if p_mode not in ('cash','upi','bank_transfer','cheque','card','other') then raise exception 'Invalid payment mode'; end if;

  if p_idempotency_key is not null then
    select * into ex from public.payments where school_id = e.school_id and idempotency_key = p_idempotency_key;
    if found then
      return jsonb_build_object('payment_id', ex.id, 'receipt_no', ex.receipt_no, 'status', ex.status, 'duplicate', true);
    end if;
  end if;

  perform 1 from public.student_session_enrollments where id = e.id for update;   -- serialise payments per enrollment
  select * into bal from public.v_enrollment_balances where enrollment_id = e.id;
  available := greatest(bal.pending - bal.awaiting_verification, 0);
  allow_adv := coalesce((select (value #>> '{}') = 'true' from public.school_settings where school_id = e.school_id and key = 'allow_advance_payment'), false);

  if p_amount > available then
    if p_allow_advance and allow_adv then
      adv := p_amount - available;
    else
      raise exception 'Amount % exceeds the outstanding balance % (advance payments are not enabled).', p_amount, available;
    end if;
  end if;
  to_alloc := p_amount - adv;

  select value into rules from public.school_settings where school_id = e.school_id and key = 'verification_rules';
  need_approval := coalesce(rules ->> p_mode, 'false') = 'true';
  st := case when need_approval and not public.has_perm(e.school_id, 'approve_payment') then 'pending' else 'verified' end;

  rno := 'RCP/' || sess.name || '/' || lpad(public.next_counter(e.school_id, 'receipt:' || sess.id)::text, 6, '0');
  tno := 'TXN' || to_char(now(), 'YYMMDD') || lpad(public.next_counter(e.school_id, 'txn')::text, 7, '0');

  perform set_config('app.audit_reason', 'Fee collection', true);
  insert into public.payments (school_id, session_id, student_id, enrollment_id, txn_id, receipt_no, amount, payment_date, mode,
      status, collector_id, reference, hard_copy_receipt_no, remarks, attachment_path, idempotency_key, advance_amount,
      verified_by, verified_at)
  values (e.school_id, e.session_id, e.student_id, e.id, tno, rno, p_amount, p_date, p_mode, st, auth.uid(),
      p_reference, p_hard_receipt, p_remarks, p_attachment, p_idempotency_key, adv,
      case when st = 'verified' then auth.uid() end, case when st = 'verified' then now() end)
  returning id into pid;

  if to_alloc > 0 then
    if p_allocations is not null and jsonb_typeof(p_allocations) = 'array' and jsonb_array_length(p_allocations) > 0 then
      for x in select * from jsonb_array_elements(p_allocations) loop
        select sfa.id, sfa.amount - coalesce((select sum(pa.amount) from public.payment_allocations pa
               join public.payments py on py.id = pa.payment_id
               where pa.assignment_id = sfa.id and py.status in ('verified','pending') and py.id <> pid), 0) as remaining
          into a from public.student_fee_assignments sfa
          where sfa.id = (x ->> 'assignment_id')::uuid and sfa.enrollment_id = e.id and sfa.status = 'active';
        if not found then raise exception 'Invalid fee line in allocation'; end if;
        take := (x ->> 'amount')::numeric;
        if take <= 0 or take > a.remaining then raise exception 'Allocation exceeds the remaining amount of a fee line'; end if;
        insert into public.payment_allocations (school_id, session_id, payment_id, assignment_id, amount)
        values (e.school_id, e.session_id, pid, a.id, take);
        sum_x := sum_x + take;
      end loop;
      if sum_x <> to_alloc then
        raise exception 'Allocation total % must equal payable amount %', sum_x, to_alloc;
      end if;
    else
      rem := to_alloc;
      for a in
        select sfa.id,
               sfa.amount - coalesce((select sum(pa.amount) from public.payment_allocations pa
                   join public.payments py on py.id = pa.payment_id
                   where pa.assignment_id = sfa.id and py.status in ('verified','pending') and py.id <> pid), 0) as remaining
        from public.student_fee_assignments sfa
        where sfa.enrollment_id = e.id and sfa.status = 'active'
        order by (select min(due_date) from public.fee_installments where assignment_id = sfa.id) nulls last, sfa.created_at
      loop
        exit when rem <= 0;
        take := least(rem, greatest(a.remaining, 0));
        if take > 0 then
          insert into public.payment_allocations (school_id, session_id, payment_id, assignment_id, amount)
          values (e.school_id, e.session_id, pid, a.id, take);
          rem := rem - take;
        end if;
      end loop;
      if rem > 0 then raise exception 'Could not allocate the full amount to fee lines (remaining %)', rem; end if;
    end if;
  end if;
  if adv > 0 then
    insert into public.payment_allocations (school_id, session_id, payment_id, assignment_id, amount)
    values (e.school_id, e.session_id, pid, null, adv);
  end if;

  if st = 'verified' then
    insert into public.receipts (school_id, session_id, payment_id, receipt_no, issued_by)
    values (e.school_id, e.session_id, pid, rno, auth.uid());
    perform public.resolve_student_tasks(e.student_id, e.session_id, pid);
    perform public.notify_perm(e.school_id, 'view_financial_dashboard', 'fee_payment_received', 'Fee payment received',
        'Receipt ' || rno || ' for Rs. ' || p_amount, '/app.html#/transactions', 'paid:' || pid);
  else
    perform public.notify_perm(e.school_id, 'approve_payment', 'online_payment_pending', 'Payment pending approval',
        'Receipt ' || rno || ' (' || p_mode || ') of Rs. ' || p_amount || ' needs approval', '/app.html#/transactions', 'pend:' || pid);
  end if;
  return jsonb_build_object('payment_id', pid, 'receipt_no', rno, 'txn_id', tno, 'status', st, 'duplicate', false);
end $$;

create or replace function public.review_payment(p_payment uuid, p_approve boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare py public.payments;
begin
  select * into py from public.payments where id = p_payment for update;
  if not found then raise exception 'Payment not found'; end if;
  perform public.require_perm(py.school_id, 'approve_payment');
  if py.status <> 'pending' then raise exception 'Only pending payments can be reviewed (current: %)', py.status; end if;
  if not p_approve and length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Rejection reason is required'; end if;
  perform set_config('app.audit_reason', coalesce(p_reason,'Approved'), true);
  insert into public.payment_verifications (school_id, payment_id, decision, decided_by, reason)
  values (py.school_id, py.id, case when p_approve then 'approved' else 'rejected' end, auth.uid(), p_reason);
  update public.payments set status = case when p_approve then 'verified' else 'rejected' end,
         verified_by = auth.uid(), verified_at = now() where id = py.id;
  if p_approve then
    insert into public.receipts (school_id, session_id, payment_id, receipt_no, issued_by)
    values (py.school_id, py.session_id, py.id, py.receipt_no, auth.uid());
    perform public.resolve_student_tasks(py.student_id, py.session_id, py.id);
    perform public.notify(py.school_id, py.collector_id, 'online_payment_approved', 'Payment approved',
        'Receipt ' || py.receipt_no || ' was approved', '/app.html#/transactions', 'appr:' || py.id);
  else
    perform public.notify(py.school_id, py.collector_id, 'online_payment_rejected', 'Payment rejected',
        'Receipt ' || py.receipt_no || ' rejected: ' || coalesce(p_reason,''), '/app.html#/transactions', 'rej:' || py.id);
  end if;
  return jsonb_build_object('status', case when p_approve then 'verified' else 'rejected' end);
end $$;

create or replace function public.cancel_payment(p_payment uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare py public.payments;
begin
  select * into py from public.payments where id = p_payment for update;
  if not found then raise exception 'Payment not found'; end if;
  perform public.require_perm(py.school_id, 'cancel_receipt');
  if py.status <> 'verified' then raise exception 'Only verified payments can be cancelled (current: %)', py.status; end if;
  if length(trim(coalesce(p_reason,''))) < 5 then raise exception 'A cancellation reason (min 5 characters) is required'; end if;
  perform set_config('app.audit_reason', p_reason, true);
  insert into public.transaction_reversals (school_id, session_id, payment_id, amount, reason, cancelled_by)
  values (py.school_id, py.session_id, py.id, py.amount, p_reason, auth.uid());
  update public.payments set status = 'cancelled' where id = py.id;
  -- promises that were resolved by this payment become pending again
  update public.payment_promises set status = 'pending', resolved_payment_id = null, resolved_at = null
   where resolved_payment_id = py.id and status = 'kept';
  perform public.notify_roles(py.school_id, array['school_owner','principal'], 'transaction_cancelled', 'Transaction cancelled',
      'Receipt ' || py.receipt_no || ' (Rs. ' || py.amount || ') cancelled: ' || p_reason, '/app.html#/transactions', 'cancel:' || py.id);
end $$;

create or replace function public.mark_receipt_printed(p_payment uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sid uuid; pc int;
begin
  select school_id into sid from public.payments where id = p_payment;
  perform public.require_perm(sid, 'print_receipt');
  update public.receipts set print_count = print_count + 1 where payment_id = p_payment returning print_count - 1 into pc;
  return jsonb_build_object('previous_prints', coalesce(pc, 0));
end $$;

create or replace function public.get_receipt(p_payment uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare py public.payments; s public.schools; st public.students; e public.student_session_enrollments; b record;
        paid_before numeric; paid_now numeric; r public.receipts; heads jsonb; collector text; rset jsonb; sessname text;
begin
  select * into py from public.payments where id = p_payment;
  if not found then raise exception 'Payment not found'; end if;
  perform public.require_perm(py.school_id, 'print_receipt');
  select * into s from public.schools where id = py.school_id;
  select * into st from public.students where id = py.student_id;
  select * into e from public.student_session_enrollments where id = py.enrollment_id;
  select * into b from public.v_enrollment_balances where enrollment_id = py.enrollment_id;
  select * into r from public.receipts where payment_id = py.id;
  select name into sessname from public.academic_sessions where id = py.session_id;
  select full_name into collector from public.user_profiles where id = py.collector_id;
  select value into rset from public.school_settings where school_id = py.school_id and key = 'receipt';
  select coalesce(sum(pa.amount), 0) into paid_before
    from public.payment_allocations pa join public.payments p2 on p2.id = pa.payment_id
   where p2.enrollment_id = py.enrollment_id and p2.status = 'verified' and pa.assignment_id is not null
     and p2.id <> py.id and (p2.created_at, p2.id) < (py.created_at, py.id);
  select coalesce(sum(amount), 0) into paid_now from public.payment_allocations where payment_id = py.id and assignment_id is not null;
  select coalesce(jsonb_agg(jsonb_build_object('head', fh.name, 'amount', pa.amount) order by fh.name), '[]'::jsonb) into heads
    from public.payment_allocations pa
    left join public.student_fee_assignments sfa on sfa.id = pa.assignment_id
    left join public.fee_heads fh on fh.id = sfa.fee_head_id
   where pa.payment_id = py.id;
  return jsonb_build_object(
    'school', jsonb_build_object('name', s.name, 'address', concat_ws(', ', s.address, s.city, s.district, s.state),
                                 'phone', coalesce(nullif(rset ->> 'phone',''), s.phone, s.mobile), 'email', s.email, 'logo_path', s.logo_path),
    'receipt_no', py.receipt_no, 'txn_id', py.txn_id, 'date', py.payment_date, 'status', py.status,
    'student', jsonb_build_object('name', st.name, 'father_name', st.father_name, 'admission_no', st.admission_no, 'student_code', st.student_code),
    'class_name', e.class_name, 'section', e.section, 'session', sessname,
    'amount', py.amount, 'advance_amount', py.advance_amount, 'mode', py.mode, 'reference', py.reference,
    'hard_copy_receipt_no', py.hard_copy_receipt_no, 'remarks', py.remarks,
    'heads', heads,
    'net_fee', b.net, 'previous_balance', greatest(b.net - paid_before, 0),
    'total_paid', paid_before + paid_now, 'remaining_balance', greatest(b.net - paid_before - paid_now, 0),
    'collector', collector, 'is_provisional', py.status = 'pending', 'is_cancelled', py.status = 'cancelled',
    'print_count', coalesce(r.print_count, 0), 'footer', coalesce(rset ->> 'footer', ''));
end $$;
