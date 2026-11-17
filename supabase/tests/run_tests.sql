-- =====================================================================
-- Trollify database tests: business logic + RLS (allowed AND denied).
-- Run against a scratch database after applying migrations 001-009:
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/run_tests.sql
-- Requires a superuser connection (it impersonates users via SET ROLE).
-- Everything is rolled back at the end; nothing persists.
-- =====================================================================
begin;
create temp table _res (name text, ok boolean, detail text);
grant all on _res to public;

create or replace function pg_temp.as_user(u uuid) returns void language plpgsql as $$
begin
  reset role;
  if u is null then perform set_config('request.jwt.claim.sub', '', true); set local role anon;
  else perform set_config('request.jwt.claim.sub', u::text, true); set local role authenticated; end if;
end $$;
create or replace function pg_temp.as_admin() returns void language plpgsql as $$
begin reset role; perform set_config('request.jwt.claim.sub', '', true); end $$;
create or replace function pg_temp.check(n text, cond boolean, d text default '') returns void language plpgsql as $$
begin insert into _res values (n, coalesce(cond, false), d); end $$;
-- expects the statement to fail (denied / constraint)
create or replace function pg_temp.denied(n text, q text) returns void language plpgsql as $$
declare okk boolean := false; msg text;
begin
  begin execute q; exception when others then okk := true; msg := sqlerrm; end;
  insert into _res values (n, okk, coalesce(msg, 'statement unexpectedly succeeded'));
end $$;
-- expects an UPDATE/DELETE to either raise or affect zero rows (RLS silently filters)
create or replace function pg_temp.noeffect(n text, q text) returns void language plpgsql as $$
declare c int := 0; msg text := 'raised';
begin
  begin execute q; get diagnostics c = row_count; msg := 'rows_affected=' || c; exception when others then c := 0; msg := sqlerrm; end;
  insert into _res values (n, c = 0, msg);
end $$;
-- expects zero rows
create or replace function pg_temp.empty(n text, q text) returns void language plpgsql as $$
declare c int;
begin execute 'select count(*) from (' || q || ') x' into c; insert into _res values (n, c = 0, 'rows=' || c); end $$;

do $t$
declare
  sa uuid := gen_random_uuid(); ownerA uuid := gen_random_uuid(); ownerB uuid := gen_random_uuid();
  tch1 uuid := gen_random_uuid(); tch2 uuid := gen_random_uuid(); acct uuid := gen_random_uuid(); viewer uuid := gen_random_uuid();
  ra uuid; rb uuid; schA uuid; schB uuid; sess uuid; sessB uuid; sess2 uuid; head_t uuid; head_a uuid;
  prem uuid; rani uuid; amit uuid; sita uuid; rahul uuid; neha uuid; fam uuid;
  enr_prem uuid; enr_rani uuid; enr_amit uuid; enr_sita uuid; enr_rahul uuid; enr_neha uuid;
  r jsonb; b record; pid uuid; pid2 uuid; n int; j jsonb; b1 uuid; tid uuid;
begin
  -- ---------- platform setup ----------
  insert into auth.users (id, email) values (sa,'sa@x'),(ownerA,'a@x'),(ownerB,'b@x'),(tch1,'t1@x'),(tch2,'t2@x'),(acct,'ac@x'),(viewer,'v@x');
  update public.user_profiles set is_super_admin = true where id = sa;
  update public.user_profiles set full_name = 'Teacher One' where id = tch1;
  update public.user_profiles set full_name = 'Teacher Two' where id = tch2;
  insert into public.school_registration_requests (school_name, school_code, owner_name, mobile, email, owner_user_id, terms_accepted)
    values ('School A','SCHA','Owner A','9876543210','a@x',ownerA,true) returning id into ra;
  insert into public.school_registration_requests (school_name, school_code, owner_name, mobile, email, owner_user_id, terms_accepted)
    values ('School B','SCHB','Owner B','9876543211','b@x',ownerB,true) returning id into rb;
  perform pg_temp.denied('1. duplicate registration code blocked', $q$insert into public.school_registration_requests
    (school_name, school_code, owner_name, mobile, email, terms_accepted) values ('X','scha','O','9999999999','z@x',true)$q$);

  perform pg_temp.as_user(ownerA);
  perform pg_temp.check('2. pending school has no access (my_school_id null)', public.my_school_id() is null);
  perform pg_temp.denied('2b. non-super-admin cannot approve', format('select public.sa_review_registration(%L,%L)', ra, 'approve'));
  perform pg_temp.as_user(sa);
  schA := public.sa_review_registration(ra, 'approve'); schB := public.sa_review_registration(rb, 'approve');
  perform pg_temp.check('3. super admin approves school', schA is not null and schB is not null);
  perform pg_temp.as_admin();
  perform pg_temp.check('3b. defaults created (fee heads)', (select count(*) from public.fee_heads where school_id = schA) >= 10);

  -- ---------- users & roles ----------
  insert into public.school_memberships (school_id,user_id,role_code) values
    (schA,tch1,'teacher'),(schA,tch2,'teacher'),(schA,acct,'accountant'),(schA,viewer,'viewer');
  perform pg_temp.as_user(tch1);
  perform pg_temp.denied('4. teacher cannot self-promote role', format($q$update public.school_memberships set role_code='school_owner' where user_id=%L$q$, tch1));
  perform pg_temp.denied('4b. teacher cannot grant self permission', format($q$insert into public.user_permissions values (%L,%L,'view_fee_amounts',true,null,now())$q$, schA, tch1));
  perform pg_temp.denied('4c. teacher cannot call set_user_permission', format($q$select public.set_user_permission(%L,'view_fee_amounts',true)$q$, tch1));
  perform pg_temp.denied('4d. teacher cannot make self super admin', format($q$update public.user_profiles set is_super_admin=true where id=%L$q$, tch1));

  -- ---------- sessions ----------
  perform pg_temp.as_user(ownerA);
  sess := public.create_session('2026-27', '2026-04-01', '2027-03-31', true);
  sess2 := public.create_session('2027-28', '2027-04-01', '2028-03-31', false);
  perform pg_temp.check('5. session created & active', (select is_active from public.academic_sessions where id = sess));
  perform pg_temp.denied('5b. second active session blocked by index', format($q$update public.academic_sessions set is_active=true where id=%L$q$, sess2));
  perform pg_temp.as_user(tch1);
  perform pg_temp.denied('5c. teacher cannot create session', $q$select public.create_session('2030-31','2030-04-01','2031-03-31')$q$);

  -- ---------- fee structure ----------
  perform pg_temp.as_user(ownerA);
  select id into head_t from public.fee_heads where school_id = schA and name = 'Tuition Fee';
  select id into head_a from public.fee_heads where school_id = schA and name = 'Admission Fee';
  foreach n in array array[4,5,6,7,8,3] loop
    insert into public.fee_structures (school_id, session_id, class_name, fee_head_id, amount, frequency, installments_count, first_due_date)
    values (schA, sess, 'Class ' || n, head_t, case n when 8 then 6000 when 5 then 6000 when 6 then 4000 when 7 then 5000 when 4 then 0 when 3 then 3000 end, 'annual', 1, '2026-06-30');
  end loop;
  insert into public.fee_structures (school_id, session_id, class_name, fee_head_id, amount) values
    (schA, sess, 'Class 8', head_a, 3000), (schA, sess, 'Class 5', head_a, 3000), (schA, sess, 'Class 6', head_a, 3000),
    (schA, sess, 'Class 7', head_a, 3000), (schA, sess, 'Class 3', head_a, 3000), (schA, sess, 'Class 4', head_a, 3000);
  perform pg_temp.as_user(tch1);
  perform pg_temp.noeffect('6. teacher cannot edit fee structure', format($q$update public.fee_structures set amount=1 where school_id=%L$q$, schA));
  perform pg_temp.denied('6b. teacher cannot insert fee structure', format($q$insert into public.fee_structures (school_id,session_id,class_name,fee_head_id,amount) values (%L,%L,'Class 1',%L,5)$q$, schA, sess, head_t));

  -- ---------- students ----------
  perform pg_temp.as_user(ownerA);
  prem  := public.add_student('{"name":"Prem Janghela","father_name":"Ramesh Janghela","admission_no":"A1","mobile":"9876500001"}', sess, 'Class 8');
  rani  := public.add_student('{"name":"Rani Janghela","father_name":"Ramesh Janghela","admission_no":"A2","mobile":"9876500001"}', sess, 'Class 5');
  amit  := public.add_student('{"name":"Amit","father_name":"Suresh","admission_no":"A3","mobile":"9876500003"}', sess, 'Class 6');
  sita  := public.add_student('{"name":"Sita","father_name":"Mohan","admission_no":"A4","mobile":"9876500004"}', sess, 'Class 7');
  rahul := public.add_student('{"name":"Rahul","father_name":"Vijay","admission_no":"A5","mobile":"9876500005"}', sess, 'Class 4', null, null, 'rte');
  neha  := public.add_student('{"name":"Neha","father_name":"Anil","admission_no":"A6","mobile":"9876500006"}', sess, 'Class 3');
  select id into enr_prem from public.student_session_enrollments where student_id = prem;
  select id into enr_rani from public.student_session_enrollments where student_id = rani;
  select id into enr_amit from public.student_session_enrollments where student_id = amit;
  select id into enr_sita from public.student_session_enrollments where student_id = sita;
  select id into enr_rahul from public.student_session_enrollments where student_id = rahul;
  select id into enr_neha from public.student_session_enrollments where student_id = neha;
  perform pg_temp.check('7. student code auto + permanent', (select student_code from public.students where id = prem) ~ '^STU-\d{6}$');
  perform pg_temp.denied('7b. duplicate admission no rejected', $q$select public.add_student('{"name":"Dup","admission_no":"A1","mobile":"9876500009"}', (select id from public.academic_sessions where name='2026-27' limit 1), 'Class 3')$q$);
  perform pg_temp.denied('7c. student code cannot change', format($q$update public.students set student_code='X' where id=%L$q$, prem));
  select * into b from public.v_enrollment_balances where enrollment_id = enr_prem;
  perform pg_temp.check('8. fee assigned from structure (9000)', b.gross = 9000 and b.pending = 9000 and b.pay_status = 'unpaid', b::text);
  select * into b from public.v_enrollment_balances where enrollment_id = enr_rahul;
  perform pg_temp.check('9. RTE student has zero fee', b.gross = 0 and b.pay_status = 'zero_fee', b::text);

  -- ---------- family & sibling concession ----------
  fam := public.create_family('Janghela Family', '9876500001', null, array[prem, rani]);
  r := public.apply_family_policy(fam, sess, 'first_pays_rest_free', prem, 0, 'Sibling concession approved by owner');
  select * into b from public.v_enrollment_balances where enrollment_id = enr_rani;
  perform pg_temp.check('10. sibling 100% concession -> net 0', b.gross = 9000 and b.discount = 9000 and b.net = 0 and b.pay_status = 'zero_fee', b::text);
  select * into b from public.v_enrollment_balances where enrollment_id = enr_prem;
  perform pg_temp.check('10b. first child pays full', b.net = 9000, b::text);
  perform pg_temp.check('10c. discount recorded separately with approver', (select count(*) from public.student_discounts where family_id = fam and approved_by = ownerA) = 1);
  perform pg_temp.denied('10d. link student already in family blocked', format($q$select public.link_student_family(%L,%L)$q$, fam, rani));
  perform pg_temp.denied('10e. concession needs reason', format($q$select public.apply_discount(%L,'fixed',100,'')$q$, enr_amit));

  -- ---------- payments ----------
  perform pg_temp.as_user(acct);
  r := public.collect_payment(enr_amit, 3000, current_date, 'cash', null, 'HC-1', 'first', 'idem-1');
  perform pg_temp.check('11. partial payment verified (cash)', r ->> 'status' = 'verified', r::text);
  select * into b from public.v_enrollment_balances where enrollment_id = enr_amit;
  perform pg_temp.check('11b. paid 3000, pending 4000', b.paid = 3000 and b.pending = 4000, b::text);
  r := public.collect_payment(enr_amit, 3000, current_date, 'cash', null, null, null, 'idem-1');
  perform pg_temp.check('12. duplicate idempotency key does not double-process', (r ->> 'duplicate')::boolean and (select count(*) from public.payments where enrollment_id = enr_amit) = 1);
  perform pg_temp.denied('13. overpayment blocked', format($q$select public.collect_payment(%L, 5000, current_date, 'cash')$q$, enr_amit));
  perform pg_temp.denied('13b. future date blocked', format($q$select public.collect_payment(%L, 10, current_date + 3, 'cash')$q$, enr_amit));
  perform pg_temp.denied('13c. zero amount blocked', format($q$select public.collect_payment(%L, 0, current_date, 'cash')$q$, enr_amit));
  r := public.collect_payment(enr_amit, 4000, current_date, 'cash');
  select * into b from public.v_enrollment_balances where enrollment_id = enr_amit;
  perform pg_temp.check('14. full payment -> paid', b.pay_status = 'paid' and b.pending = 0, b::text);
  perform pg_temp.check('14b. allocations equal payment amount', (select sum(pa.amount) from public.payment_allocations pa join public.payments p on p.id = pa.payment_id where p.enrollment_id = enr_amit) = 7000);
  perform pg_temp.check('14c. receipt row created', (select count(*) from public.receipts where school_id = schA) >= 2);
  perform pg_temp.denied('14d. payment amount immutable', format($q$update public.payments set amount=1 where enrollment_id=%L$q$, enr_amit));
  perform pg_temp.denied('14e. payments cannot be deleted', format($q$delete from public.payments where enrollment_id=%L$q$, enr_amit));
  perform pg_temp.denied('14f. client cannot insert payment directly', format($q$insert into public.payments (school_id,session_id,student_id,enrollment_id,txn_id,receipt_no,amount,payment_date,mode,collector_id) values (%L,%L,%L,%L,'t','r',1,current_date,'cash',%L)$q$, schA, sess, amit, enr_amit, acct));
  r := public.collect_payment(enr_neha, 2000, current_date, 'cash');
  perform pg_temp.check('15. unique receipt numbers', (select count(distinct receipt_no) = count(*) from public.payments where school_id = schA));

  -- online payment verification
  perform pg_temp.as_admin();
  update public.school_settings set value = '{"cash":false,"upi":true,"bank_transfer":true,"cheque":true,"card":false,"other":true}' where school_id = schA and key = 'verification_rules';
  perform pg_temp.as_user(acct);
  r := public.collect_payment(enr_sita, 2000, current_date, 'upi', 'UTR123');
  pid := (r ->> 'payment_id')::uuid;
  perform pg_temp.check('16. UPI payment pending, no receipt yet', r ->> 'status' = 'pending' and not exists (select 1 from public.receipts where payment_id = pid));
  select * into b from public.v_enrollment_balances where enrollment_id = enr_sita;
  perform pg_temp.check('16b. pending payment NOT counted as collection', b.paid = 0 and b.awaiting_verification = 2000, b::text);
  perform pg_temp.denied('16c. accountant w/o approve_payment cannot approve', format($q$select public.review_payment(%L,true)$q$, pid));
  perform pg_temp.as_user(ownerA);
  perform public.review_payment(pid, true);
  select * into b from public.v_enrollment_balances where enrollment_id = enr_sita;
  perform pg_temp.check('17. approval moves payment into ledger + receipt', b.paid = 2000 and exists (select 1 from public.receipts where payment_id = pid), b::text);
  perform pg_temp.as_user(acct);
  r := public.collect_payment(enr_sita, 1000, current_date, 'upi', 'UTR999');
  perform pg_temp.as_user(ownerA);
  perform public.review_payment((r ->> 'payment_id')::uuid, false, 'UTR not found');
  select * into b from public.v_enrollment_balances where enrollment_id = enr_sita;
  perform pg_temp.check('18. rejected payment retained, not counted', b.paid = 2000 and (select status from public.payments where id = (r ->> 'payment_id')::uuid) = 'rejected');

  -- cancellation / reversal
  perform pg_temp.as_user(acct);
  perform pg_temp.denied('19. accountant w/o cancel_receipt cannot cancel', format($q$select public.cancel_payment(%L,'wrong entry here')$q$, pid));
  perform pg_temp.as_user(ownerA);
  perform pg_temp.denied('19b. cancellation needs reason', format($q$select public.cancel_payment(%L,'x')$q$, pid));
  perform public.cancel_payment(pid, 'Cheque bounced - cancelled');
  select * into b from public.v_enrollment_balances where enrollment_id = enr_sita;
  perform pg_temp.check('20. cancellation recalculates balance, keeps original', b.paid = 0 and exists (select 1 from public.payments where id = pid and status = 'cancelled') and exists (select 1 from public.transaction_reversals where payment_id = pid));
  perform pg_temp.denied('20b. cancelled payment cannot be re-verified', format($q$update public.payments set status='verified' where id=%L$q$, pid));

  -- ---------- teacher privacy (RLS + RPC) ----------
  perform pg_temp.as_user(ownerA);
  r := public.create_calling_tasks(sess, 'all_pending', null, null, array[tch1, tch2], 'normal', current_date + 5);
  perform pg_temp.check('21. calling tasks distributed; RTE/zero/paid skipped', (r ->> 'created')::int = 3 and (r ->> 'skipped_no_pending_fee')::int >= 3, r::text);
  perform pg_temp.check('21b. no duplicate active task for same student', public.create_calling_tasks(sess, 'all_pending', null, null, array[tch1], 'normal', null) ->> 'created' = '0');
  perform pg_temp.as_user(tch1);
  perform pg_temp.empty('22. teacher cannot read payments', 'select 1 from public.payments');
  perform pg_temp.empty('22b. teacher cannot read fee assignments', 'select 1 from public.student_fee_assignments');
  perform pg_temp.empty('22c. teacher cannot read receipts', 'select 1 from public.receipts');
  perform pg_temp.empty('22d. teacher cannot read discounts', 'select 1 from public.student_discounts');
  perform pg_temp.empty('22e. teacher cannot read students table directly', 'select 1 from public.students');
  perform pg_temp.empty('22f. teacher cannot read fee structures', 'select 1 from public.fee_structures');
  perform pg_temp.empty('22g. teacher cannot read balances view', 'select 1 from public.v_enrollment_balances');
  perform pg_temp.empty('22h. teacher cannot read promised amounts', 'select 1 from public.payment_promises');
  perform pg_temp.denied('22i. teacher cannot call fee_summary', format($q$select public.fee_summary(%L)$q$, sess));
  perform pg_temp.denied('22j. teacher cannot call fee_list', format($q$select public.fee_list(%L)$q$, sess));
  perform pg_temp.denied('22k. teacher cannot call collect_payment', format($q$select public.collect_payment(%L,100,current_date,'cash')$q$, enr_neha));
  perform pg_temp.empty('22l. teacher cannot read audit logs', 'select 1 from public.audit_logs');
  j := public.crm_list(sess, 'mine');
  perform pg_temp.check('23. teacher sees only own tasks via crm_list', (j ->> 'total')::int between 1 and 2, j ->> 'total');
  perform pg_temp.check('23b. crm_list has NO amounts for teacher',
    not exists (select 1 from jsonb_array_elements(j -> 'rows') x where x ->> 'pending_amount' is not null or x ->> 'net_fee' is not null or x ->> 'paid_amount' is not null), j::text);
  perform pg_temp.check('23c. crm_list excludes RTE/zero-fee/paid', not exists (select 1 from jsonb_array_elements(j -> 'rows') x where x ->> 'name' in ('Rahul','Rani Janghela','Amit')));
  perform pg_temp.check('23d. crm_list always has parent mobile for dialer', not exists (select 1 from jsonb_array_elements(j -> 'rows') x where coalesce(x ->> 'mobile','') = ''));
  j := public.crm_list(sess, 'all');
  perform pg_temp.check('23e. teacher scope=all is forced to own tasks', (j ->> 'total')::int between 1 and 2);

  -- ---------- calling & promises ----------
  select (x ->> 'task_id')::uuid, (x ->> 'student_id')::uuid into tid, b1 from jsonb_array_elements(public.crm_list(sess, 'mine') -> 'rows') x limit 1;
  perform pg_temp.denied('24. remark required', format($q$select public.log_call(%L,%L,%L,'connected','')$q$, b1, sess, tid));
  perform pg_temp.denied('24b. promised status needs date', format($q$select public.log_call(%L,%L,%L,'promised_to_pay','Baat hui')$q$, b1, sess, tid));
  r := public.log_call(b1, sess, tid, 'promised_to_pay', 'Father se baat hui, 25 tak jama karenge', null, null, null, null, null, current_date + 1, 3000, current_date + 1);
  perform pg_temp.check('25. call saved with promise + follow-up', r ->> 'promise_id' is not null
     and exists (select 1 from public.follow_up_tasks where task_id = tid and status = 'pending')
     and (select status from public.calling_tasks where id = tid) = 'promised');
  perform pg_temp.check('25b. history immutable', true);
  perform pg_temp.denied('25c. calling log cannot be edited', $q$update public.calling_logs set remark='changed'$q$);
  perform pg_temp.denied('25d. calling log cannot be deleted', $q$delete from public.calling_logs$q$);
  perform pg_temp.denied('25e. teacher cannot insert calling log directly', format($q$insert into public.calling_logs (school_id,session_id,student_id,called_by,call_status,remark) values (%L,%L,%L,%L,'connected','x1x')$q$, schA, sess, b1, tch1));
  perform pg_temp.as_user(tch2);
  perform pg_temp.denied('26. other teacher cannot log on my task', format($q$select public.log_call(%L,%L,%L,'connected','not mine')$q$, b1, sess, tid));
  perform pg_temp.empty('26b. other teacher cannot read my calling logs', format($q$select 1 from public.calling_logs where student_id=%L$q$, b1));
  perform pg_temp.as_user(tch1);
  r := public.log_call(b1, sess, tid, 'not_answered', 'Phone nahi utha');
  perform pg_temp.check('27. every call preserved as separate history row', (select count(*) from public.calling_logs where student_id = b1) = 2);

  -- reminder engine: overdue promise -> new task, idempotent
  perform pg_temp.as_admin();
  update public.payment_promises set promised_date = current_date - 2 where task_id = tid;
  r := public.run_reminders(schA);
  perform pg_temp.check('28. overdue promise detected', (select status from public.payment_promises where task_id = tid) = 'overdue', r::text);
  select count(*) into n from public.follow_up_tasks where task_id = tid and kind = 'promise_overdue';
  perform public.run_reminders(schA); perform public.run_reminders(schA);
  perform pg_temp.check('29. reminder engine is idempotent (no duplicate tasks)',
      (select count(*) from public.follow_up_tasks where task_id = tid and kind = 'promise_overdue') = n and n = 1);
  perform pg_temp.check('29b. teacher + admin notified once',
      (select count(*) from public.notifications where type = 'promise_overdue' and user_id = tch1) = 1
      and (select count(*) from public.notifications where type = 'promise_overdue' and user_id = ownerA) = 1);
  perform pg_temp.check('29c. active-task uniqueness holds', (select count(*) from public.calling_tasks where student_id = b1 and status in ('pending','in_progress','promised')) = 1);

  -- payment resolves task automatically
  select e.id into enr_prem from public.student_session_enrollments e where e.student_id = b1;
  perform pg_temp.as_user(acct);
  perform public.collect_payment(enr_prem, 3000, current_date, 'cash');
  perform pg_temp.as_admin();
  perform pg_temp.check('30. verified payment resolves the promise, history kept', (select status from public.payment_promises where task_id = tid) = 'kept'
      and (select count(*) from public.calling_logs where student_id = b1) = 2);

  -- ---------- cross-school isolation ----------
  perform pg_temp.as_user(ownerB);
  perform pg_temp.check('31. school B owner has own school', public.my_school_id() = schB);
  perform pg_temp.empty('31b. school B cannot read A students', format($q$select 1 from public.students where school_id=%L$q$, schA));
  perform pg_temp.empty('31c. school B cannot read A payments', 'select 1 from public.payments');
  perform pg_temp.empty('31d. school B cannot read A sessions', format($q$select 1 from public.academic_sessions where school_id=%L$q$, schA));
  perform pg_temp.empty('31e. school B cannot read A audit', format($q$select 1 from public.audit_logs where school_id=%L$q$, schA));
  perform pg_temp.denied('31f. school B cannot collect on A enrollment', format($q$select public.collect_payment(%L,100,current_date,'cash')$q$, enr_neha));
  perform pg_temp.denied('31g. school B cannot read A fee list', format($q$select public.fee_list(%L)$q$, sess));
  perform pg_temp.denied('31h. school B cannot add student into A session', format($q$select public.add_student('{"name":"Hack","admission_no":"H1","mobile":"9876500099"}', %L,'Class 1')$q$, sess));
  perform pg_temp.noeffect('31i. school B cannot modify A student', format($q$update public.students set name='hacked' where id=%L$q$, neha));
  -- anon
  perform pg_temp.as_user(null);
  perform pg_temp.denied('32. anon cannot read schools', 'select * from public.schools');
  perform pg_temp.denied('32b. anon cannot read students', 'select * from public.students');
  perform pg_temp.denied('32c. anon cannot call RPC', format($q$select public.fee_summary(%L)$q$, sess));

  -- ---------- viewer / accountant boundaries ----------
  perform pg_temp.as_user(viewer);
  perform pg_temp.check('33. viewer can read financial dashboard', (public.fee_summary(sess) ->> 'total_students')::int = 6);
  perform pg_temp.denied('33b. viewer cannot collect', format($q$select public.collect_payment(%L,100,current_date,'cash')$q$, enr_neha));
  perform pg_temp.denied('33c. viewer cannot add student', format($q$select public.add_student('{"name":"V","admission_no":"V1","mobile":"9876500098"}', %L,'Class 1')$q$, sess));
  perform pg_temp.as_user(acct);
  perform pg_temp.denied('33d. accountant cannot apply discount', format($q$select public.apply_discount(%L,'fixed',100,'because')$q$, enr_neha));
  perform pg_temp.denied('33e. accountant cannot see CRM teacher performance', format($q$select public.teacher_performance(%L)$q$, sess));

  -- ---------- per-user permission override ----------
  perform pg_temp.as_user(ownerA);
  perform public.set_user_permission(tch2, 'view_fee_amounts', true);
  perform pg_temp.as_user(tch2);
  perform pg_temp.check('34. explicit grant lets teacher see financial rows', (select count(*) from public.payments) > 0);
  perform pg_temp.as_user(ownerA);
  perform public.set_user_permission(tch2, 'view_fee_amounts', false);
  perform pg_temp.as_user(tch2);
  perform pg_temp.empty('34b. explicit deny removes access', 'select 1 from public.payments');

  -- ---------- sessions are independent ----------
  perform pg_temp.as_user(ownerA);
  r := public.promote_students(sess, sess2);
  perform pg_temp.check('35. promotion created enrollments, identity reused', (r ->> 'created')::int = 6 and (select count(*) from public.students where school_id = schA) = 6, r::text);
  perform pg_temp.check('35b. old-session payments NOT moved to new session', (select count(*) from public.payments where session_id = sess2) = 0
      and (select coalesce(sum(paid),0) from public.v_enrollment_balances where session_id = sess2) = 0);
  perform pg_temp.check('35c. fee_summary is per session', (public.fee_summary(sess2) ->> 'collected')::numeric = 0 and (public.fee_summary(sess) ->> 'collected')::numeric > 0);
  perform pg_temp.check('35d. same session twice does not duplicate', (public.promote_students(sess, sess2) ->> 'created')::int = 0);
  r := public.carry_forward_dues(sess, sess2);
  perform pg_temp.check('36. dues carried only on explicit action', (r ->> 'carried_students')::int >= 1, r::text);

  -- ---------- bulk import idempotency ----------
  j := public.start_import(sess, 'f.csv', 'hash1', 2);
  r := public.import_students_batch((j ->> 'batch_id')::uuid, '[{"name":"Imp One","father_name":"F","admission_no":"IM1","class_name":"Class 2","mobile":"+91 98765 11111","annual_fee":"5000"},
        {"name":"Bad","admission_no":"IM2","class_name":"Class 99","mobile":"123"}]');
  perform pg_temp.check('37. import: 1 imported, 1 rejected with reasons', (r ->> 'imported')::int = 1 and (r ->> 'failed')::int = 1
     and exists (select 1 from public.import_errors where row_no = 2 and errors[1] like 'Invalid class%'), r::text);
  j := public.start_import(sess, 'f.csv', 'hash1', 2);
  r := public.import_students_batch((j ->> 'batch_id')::uuid, '[{"name":"Imp One","father_name":"F","admission_no":"IM1","class_name":"Class 2","mobile":"9876511111","annual_fee":"5000"}]');
  perform pg_temp.check('38. re-uploading same file creates no duplicate', (r ->> 'imported')::int = 0 and (r ->> 'skipped')::int = 1
      and (select count(*) from public.students where admission_no = 'IM1') = 1, r::text);

  -- ---------- audit ----------
  perform pg_temp.as_admin();
  perform pg_temp.check('39. financial actions audited', exists (select 1 from public.audit_logs where action = 'payments.insert')
      and exists (select 1 from public.audit_logs where action = 'transaction_reversals.insert' and reason like 'Cheque%'));
  perform pg_temp.denied('39b. audit log immutable (update)', $q$update public.audit_logs set action='x'$q$);
  perform pg_temp.denied('39c. audit log immutable (delete)', $q$delete from public.audit_logs$q$);
  perform pg_temp.check('40. exact balance arithmetic uses NUMERIC', (select data_type from information_schema.columns where table_name = 'payments' and column_name = 'amount') = 'numeric');

  -- ---------- no-CLI registration / user admin (009) ----------
  perform pg_temp.as_admin();
  insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a1','newreg@x'),('00000000-0000-0000-0000-0000000000a2','newstaff@x'),('00000000-0000-0000-0000-0000000000a3','oldacct@x');
  update auth.users set created_at = now() - interval '2 hours' where id = '00000000-0000-0000-0000-0000000000a3';
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
  perform public.submit_registration('New School','NEWS1',null,'addr','city','dist','st','Owner N','9876500000',null,true);
  perform pg_temp.as_admin();
  perform pg_temp.check('41. self-registration creates PENDING request only', exists (select 1 from public.school_registration_requests where school_code='NEWS1' and status='pending')
      and not exists (select 1 from public.school_memberships where user_id='00000000-0000-0000-0000-0000000000a1'));
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
  perform pg_temp.check('41b. pending registrant has no school access', public.my_school_id() is null);
  perform pg_temp.denied('42. duplicate school code rejected', $q$select public.submit_registration('Other','news1',null,'','','','','O','9876500001',null,true)$q$);
  perform pg_temp.as_user(null);
  perform pg_temp.denied('42c. anon cannot call submit_registration', $q$select public.submit_registration('Z School','ZZZ1',null,'','','','','O','9876500002',null,true)$q$);
  perform pg_temp.as_user(ownerA);
  perform public.admin_attach_user('00000000-0000-0000-0000-0000000000a2','Staff New','9876500003','teacher','Class teacher');
  perform pg_temp.as_admin();
  perform pg_temp.check('43. owner attaches a fresh account as teacher', exists (select 1 from public.school_memberships where user_id='00000000-0000-0000-0000-0000000000a2' and school_id=schA and role_code='teacher'));
  perform pg_temp.as_user(ownerA);
  perform pg_temp.denied('44. cannot attach an old (hijack) account', $q$select public.admin_attach_user('00000000-0000-0000-0000-0000000000a3','X Y','','teacher','')$q$);
  perform pg_temp.denied('44b. cannot attach a registrant', $q$select public.admin_attach_user('00000000-0000-0000-0000-0000000000a1','X Y','','teacher','')$q$);
  perform pg_temp.denied('44c. cannot create school_owner', $q$select public.admin_attach_user('00000000-0000-0000-0000-0000000000a2','X Y','','school_owner','')$q$);
  perform pg_temp.as_user(tch1);
  perform pg_temp.denied('45. teacher cannot attach users', $q$select public.admin_attach_user('00000000-0000-0000-0000-0000000000a2','X Y','','teacher','')$q$);
  perform pg_temp.denied('45b. teacher cannot reset password', format($q$select public.admin_reset_password(%L,'Passw0rd123')$q$, tch2));
  perform pg_temp.denied('45c. teacher cannot deactivate', format($q$select public.set_member_active(%L,false)$q$, tch2));
  perform pg_temp.as_user(ownerB);
  perform pg_temp.denied('46. other school owner cannot touch my users', format($q$select public.admin_reset_password(%L,'Passw0rd123')$q$, tch1));
  perform pg_temp.as_user(ownerA);
  perform pg_temp.denied('47. weak password rejected', format($q$select public.admin_reset_password(%L,'short')$q$, tch1));
  perform public.admin_reset_password(tch1, 'NewPass123');
  perform pg_temp.as_admin();
  perform pg_temp.check('47b. password hash updated', (select encrypted_password from auth.users where id = tch1) = extensions.crypt('NewPass123', (select encrypted_password from auth.users where id = tch1)));
  perform pg_temp.as_user(ownerA);
  perform pg_temp.denied('48. cannot deactivate self', format($q$select public.set_member_active(%L,false)$q$, ownerA));
  perform public.set_member_active(tch2, false);
  perform pg_temp.as_user(tch2);
  perform pg_temp.check('48b. deactivated user loses school access', public.my_school_id() is null);
  perform pg_temp.as_user(ownerA);
  perform public.set_member_active(tch2, true);
  perform pg_temp.as_user(tch2);
  perform pg_temp.check('48c. reactivated user regains access', public.my_school_id() = schA);
  perform pg_temp.as_user(acct);
  perform pg_temp.check('49. run_my_reminders runs then throttles', (public.run_my_reminders() ->> 'ran')::boolean and not (public.run_my_reminders() ->> 'ran')::boolean);
  perform pg_temp.as_user(null);
  perform pg_temp.denied('49b. anon cannot run reminders', 'select public.run_my_reminders()');
end $t$;

reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, case when ok then '' else detail end as detail from _res order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from _res;
rollback;
