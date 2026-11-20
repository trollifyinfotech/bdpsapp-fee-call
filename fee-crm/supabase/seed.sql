-- =====================================================================
-- OPTIONAL DEMO DATA  (sample data - NOT for production schools)
--
-- This file only CREATES a function. It never inserts anything by itself and
-- is not part of the migrations. To load the demo, create 3 users first
-- (Authentication > Users > Add user), then run in the SQL editor:
--
--   select public.seed_demo_school('owner@example.com', 'teacher1@example.com', 'teacher2@example.com');
--
-- The school is created as "Bhuni Dada Public School, Gumgaon [DEMO]" with is_demo = true
-- (shown with a DEMO badge in the app). Remove it with:  select public.remove_demo_school('<school_id>');
-- The function refuses to run if the school code DEMO001 already exists.
-- =====================================================================

create or replace function public.seed_demo_school(p_owner_email text, p_teacher1_email text default null, p_teacher2_email text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_owner uuid; v_t1 uuid; v_t2 uuid; v_sid uuid; v_sess uuid; v_head_t uuid; v_head_a uuid; v_head_d uuid; v_head_o uuid;
  prem uuid; rani uuid; amit uuid; sita uuid; rahul uuid; neha uuid; fam uuid; n int;
  e_amit uuid; e_neha uuid; e_sita uuid; tsk uuid; lg uuid; pr uuid; cnt int; v_today date := public.today_local();
begin
  if exists (select 1 from public.schools where lower(school_code) = 'demo001') then
    raise exception 'Demo school already exists (code DEMO001)'; end if;
  select id into v_owner from auth.users where lower(email) = lower(p_owner_email);
  if v_owner is null then raise exception 'Owner user % not found. Create it in Authentication > Users first.', p_owner_email; end if;
  if p_teacher1_email is not null then select id into v_t1 from auth.users where lower(email) = lower(p_teacher1_email); end if;
  if p_teacher2_email is not null then select id into v_t2 from auth.users where lower(email) = lower(p_teacher2_email); end if;

  -- act as the owner so audit trail & permission checks behave exactly like the real app
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  insert into public.schools (school_code, name, address, state, district, city, owner_name, mobile, email, status, is_demo, approved_at)
  values ('DEMO001', 'Bhuni Dada Public School, Gumgaon [DEMO]', 'Gumgaon', 'Madhya Pradesh', 'Seoni', 'Gumgaon',
          'Demo Owner', '9999900000', p_owner_email, 'active', true, now()) returning id into v_sid;
  insert into public.school_memberships (school_id, user_id, role_code) values (v_sid, v_owner, 'school_owner');
  if v_t1 is not null then insert into public.school_memberships (school_id, user_id, role_code) values (v_sid, v_t1, 'teacher'); end if;
  if v_t2 is not null then insert into public.school_memberships (school_id, user_id, role_code) values (v_sid, v_t2, 'teacher'); end if;
  insert into public.school_subscriptions (school_id, plan_code, max_students, max_users, expires_on)
  values (v_sid, 'trial', 300, 10, current_date + 90);
  perform public.init_school_defaults(v_sid);

  v_sess := public.create_session('2026-27', '2026-04-01', '2027-03-31', true);
  select id into v_head_t from public.fee_heads where school_id = v_sid and name = 'Tuition Fee';
  select id into v_head_a from public.fee_heads where school_id = v_sid and name = 'Admission Fee';
  select id into v_head_d from public.fee_heads where school_id = v_sid and name = 'Development Fee';
  select id into v_head_o from public.fee_heads where school_id = v_sid and name = 'Other Charges';

  -- class totals: Class 8 = 9000, Class 5 = 9000, Class 6 = 7000, Class 7 = 8000, Class 4 = 6000 (RTE student pays 0), Class 3 = 6000
  insert into public.fee_structures (school_id, session_id, class_name, fee_head_id, amount, frequency, installments_count, first_due_date)
  select v_sid, v_sess, c.cls, h.hid, h.mult * c.base, 'annual', 1, date '2026-07-31'
  from (values ('Class 8', 9000), ('Class 5', 9000), ('Class 6', 7000), ('Class 7', 8000), ('Class 4', 6000), ('Class 3', 6000)) c(cls, base)
  cross join (values (v_head_t, 0.6667), (v_head_a, 0.1111), (v_head_d, 0.1111), (v_head_o, 0.1111)) h(hid, mult);
  -- fix rounding so every class sums exactly to its total
  update public.fee_structures fs set amount = amount + (t.total - s.sum_now)
  from (values ('Class 8', 9000), ('Class 5', 9000), ('Class 6', 7000), ('Class 7', 8000), ('Class 4', 6000), ('Class 3', 6000)) t(cls, total),
       lateral (select sum(amount) sum_now from public.fee_structures x where x.session_id = v_sess and x.class_name = t.cls) s
  where fs.session_id = v_sess and fs.class_name = t.cls and fs.fee_head_id = v_head_t;
  update public.fee_structures set amount = round(amount, 2) where session_id = v_sess;

  prem  := public.add_student('{"name":"Prem Janghela","father_name":"Ramesh Janghela","mother_name":"Sunita Janghela","admission_no":"D-001","mobile":"9876500001","address":"Gumgaon","gender":"male"}', v_sess, 'Class 8');
  rani  := public.add_student('{"name":"Rani Janghela","father_name":"Ramesh Janghela","mother_name":"Sunita Janghela","admission_no":"D-002","mobile":"9876500001","address":"Gumgaon","gender":"female"}', v_sess, 'Class 5');
  amit  := public.add_student('{"name":"Amit","father_name":"Suresh Kumar","admission_no":"D-003","mobile":"9876500003","address":"Gumgaon","gender":"male"}', v_sess, 'Class 6');
  sita  := public.add_student('{"name":"Sita","father_name":"Mohan Lal","admission_no":"D-004","mobile":"9876500004","address":"Bhuni","gender":"female"}', v_sess, 'Class 7');
  rahul := public.add_student('{"name":"Rahul","father_name":"Vijay Singh","admission_no":"D-005","mobile":"9876500005","address":"Bhuni","gender":"male"}', v_sess, 'Class 4', null, null, 'rte');
  neha  := public.add_student('{"name":"Neha","father_name":"Anil Verma","admission_no":"D-006","mobile":"9876500006","address":"Gumgaon","gender":"female"}', v_sess, 'Class 3');

  fam := public.create_family('Janghela Family', '9876500001', 'Prem pays full fee; Rani studies free (sibling policy). DEMO', array[prem, rani]);
  perform public.apply_family_policy(fam, v_sess, 'first_pays_rest_free', prem, 0, 'Sibling concession - second child free (DEMO)');

  select id into e_amit from public.student_session_enrollments where student_id = amit and session_id = v_sess;
  select id into e_neha from public.student_session_enrollments where student_id = neha and session_id = v_sess;
  select id into e_sita from public.student_session_enrollments where student_id = sita and session_id = v_sess;
  perform public.collect_payment(e_amit, 3000, v_today - 20, 'cash', null, 'DEMO-HC-1', 'Demo payment', 'demo-amit-1');
  perform public.collect_payment(e_neha, 2000, v_today - 10, 'cash', null, 'DEMO-HC-2', 'Demo payment', 'demo-neha-1');

  if v_t1 is not null then
    -- tasks for students who still owe fees; calling history below is sample data
    perform public.create_calling_tasks(v_sess, 'all_pending', null, null,
            case when v_t2 is not null then array[v_t1, v_t2] else array[v_t1] end, 'normal', v_today + 7);
    for cnt in 1..1 loop
      select id into tsk from public.calling_tasks where student_id = amit and session_id = v_sess and status in ('pending','in_progress','promised');
      if tsk is not null then
        -- connected call + promise to pay (a few days ahead, relative to today)
        perform set_config('request.jwt.claim.sub', (select assigned_to from public.calling_tasks where id = tsk)::text, true);
        perform public.log_call(amit, v_sess, tsk, 'promised_to_pay',
          'Father se baat hui. Unhone kaha ki 25 November tak Rs. 3,000 jama kar denge. Remaining amount ke liye next month follow-up karna hai.',
          'Promise to pay', 'Will pay soon', 'Suresh Kumar', '9876500003', null, v_today + 5, 3000, v_today + 5);
      end if;
      select id into tsk from public.calling_tasks where student_id = sita and session_id = v_sess and status in ('pending','in_progress','promised');
      if tsk is not null then
        perform set_config('request.jwt.claim.sub', (select assigned_to from public.calling_tasks where id = tsk)::text, true);
        perform public.log_call(sita, v_sess, tsk, 'not_answered', 'Phone nahi uthaya. Shaam ko dobara try karna hai.', null, null, 'Mohan Lal', '9876500004', null, null, null, v_today + 1);
        -- sample "follow-up overdue": back-date an older follow-up (demo data only)
        insert into public.follow_up_tasks (school_id, session_id, task_id, student_id, assigned_to, kind, due_date, status, dedupe_key)
        values (v_sid, v_sess, tsk, sita, (select assigned_to from public.calling_tasks where id = tsk), 'follow_up', v_today - 3, 'overdue', 'demo-overdue-' || sita);
      end if;
    end loop;
  end if;
  perform set_config('request.jwt.claim.sub', '', true);
  return v_sid;
end $$;
revoke all on function public.seed_demo_school(text, text, text) from public, anon, authenticated;

-- Hard-removes ONLY a school flagged is_demo (bypasses append-only triggers deliberately; run from SQL editor).
create or replace function public.remove_demo_school(p_school uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.schools where id = p_school and is_demo) then
    raise exception 'Refusing: school is not a demo school'; end if;
  alter table public.payments disable trigger user;
  alter table public.payment_allocations disable trigger user;
  alter table public.receipts disable trigger user;
  alter table public.transaction_reversals disable trigger user;
  alter table public.payment_verifications disable trigger user;
  alter table public.calling_logs disable trigger user;
  alter table public.task_assignment_history disable trigger user;
  alter table public.fee_adjustments disable trigger user;
  alter table public.rte_reimbursements disable trigger user;
  alter table public.audit_logs disable trigger user;
  delete from public.audit_logs where school_id = p_school;
  delete from public.schools where id = p_school;
  alter table public.payments enable trigger user;
  alter table public.payment_allocations enable trigger user;
  alter table public.receipts enable trigger user;
  alter table public.transaction_reversals enable trigger user;
  alter table public.payment_verifications enable trigger user;
  alter table public.calling_logs enable trigger user;
  alter table public.task_assignment_history enable trigger user;
  alter table public.fee_adjustments enable trigger user;
  alter table public.rte_reimbursements enable trigger user;
  alter table public.audit_logs enable trigger user;
end $$;
revoke all on function public.remove_demo_school(uuid) from public, anon, authenticated;
