-- =====================================================================
-- TROLLIFY School Fee & Recovery Management System
-- Migration 001 : Core schema (tables, constraints, indexes)
-- =====================================================================
-- Design notes
--  * Multi-tenant: every school-owned row carries school_id.
--  * Money is NUMERIC(12,2) only. Balances are NEVER stored; they are derived
--    from fee assignments, discounts and VERIFIED payment allocations
--    (see view v_enrollment_balances in migration 005).
--  * Student identity is permanent (students). Everything session specific
--    (class, section, fees, payments) hangs off student_session_enrollments.
--  * Financial rows are append-only (no DELETE, cancellations via reversal).
-- =====================================================================

create extension if not exists pg_trgm;

-- ---------------------------------------------------------------------
-- Generic helpers
-- ---------------------------------------------------------------------
create or replace function public.set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------
-- Users / profiles
-- ---------------------------------------------------------------------
create table public.user_profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  full_name      text not null default '',
  email          text,
  mobile         text,
  is_super_admin boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Schools, registration, subscriptions
-- ---------------------------------------------------------------------
create table public.schools (
  id           uuid primary key default gen_random_uuid(),
  school_code  text not null,
  name         text not null,
  udise_code   text,
  address      text,
  state        text,
  district     text,
  city         text,
  owner_name   text,
  mobile       text,
  phone        text,
  email        text,
  logo_path    text,
  status       text not null default 'active' check (status in ('active','suspended','inactive')),
  is_demo      boolean not null default false,
  approved_at  timestamptz,
  approved_by  uuid references auth.users(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create unique index uq_schools_code on public.schools (lower(school_code));
create unique index uq_schools_udise on public.schools (udise_code) where udise_code is not null and udise_code <> '';

create table public.school_registration_requests (
  id             uuid primary key default gen_random_uuid(),
  school_name    text not null,
  school_code    text not null,
  udise_code     text,
  address        text,
  state          text,
  district       text,
  city           text,
  owner_name     text not null,
  mobile         text not null,
  email          text not null,
  owner_user_id  uuid references auth.users(id) on delete set null,
  logo_path      text,
  terms_accepted boolean not null default false,
  status         text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by    uuid references auth.users(id),
  reviewed_at    timestamptz,
  reject_reason  text,
  school_id      uuid references public.schools(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
-- Prevent duplicate registrations (pending or approved) for same code / email / UDISE
create unique index uq_reg_code on public.school_registration_requests (lower(school_code)) where status in ('pending','approved');
create unique index uq_reg_email on public.school_registration_requests (lower(email)) where status in ('pending','approved');
create unique index uq_reg_udise on public.school_registration_requests (udise_code)
  where status in ('pending','approved') and udise_code is not null and udise_code <> '';

create table public.subscription_plans (
  code          text primary key,
  name          text not null,
  max_students  integer not null,
  max_users     integer not null,
  price_monthly numeric(12,2) not null default 0,
  is_active     boolean not null default true
);

create table public.school_subscriptions (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  plan_code     text references public.subscription_plans(code),
  max_students  integer not null default 1000,
  max_users     integer not null default 25,
  starts_on     date not null default current_date,
  expires_on    date,
  status        text not null default 'active' check (status in ('active','expired','cancelled')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create unique index uq_active_subscription on public.school_subscriptions (school_id) where status = 'active';

create table public.platform_payments (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id),
  amount      numeric(12,2) not null check (amount > 0),
  paid_on     date not null default current_date,
  mode        text,
  reference   text,
  note        text,
  recorded_by uuid references auth.users(id),
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- RBAC
-- ---------------------------------------------------------------------
create table public.roles (
  code        text primary key,
  name        text not null,
  description text,
  rank        integer not null default 0
);

create table public.permissions (
  code     text primary key,
  name     text not null,
  category text not null default 'general'
);

create table public.role_permissions (
  role_code       text not null references public.roles(code) on delete cascade,
  permission_code text not null references public.permissions(code) on delete cascade,
  primary key (role_code, permission_code)
);

create table public.school_memberships (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  role_code   text not null references public.roles(code),
  designation text,
  is_active   boolean not null default true,
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (school_id, user_id)
);
create index ix_memberships_user on public.school_memberships (user_id) where is_active;

create table public.user_permissions (
  school_id       uuid not null references public.schools(id) on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  permission_code text not null references public.permissions(code) on delete cascade,
  granted         boolean not null,
  granted_by      uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  primary key (school_id, user_id, permission_code)
);

create table public.school_settings (
  school_id  uuid not null references public.schools(id) on delete cascade,
  key        text not null,
  value      jsonb not null,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  primary key (school_id, key)
);

create table public.counters (
  school_id uuid not null references public.schools(id) on delete cascade,
  key       text not null,
  value     bigint not null default 0,
  primary key (school_id, key)
);

-- ---------------------------------------------------------------------
-- Academic sessions
-- ---------------------------------------------------------------------
create table public.academic_sessions (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null references public.schools(id) on delete cascade,
  name       text not null,
  start_date date not null,
  end_date   date not null,
  is_active  boolean not null default false,
  status     text not null default 'open' check (status in ('open','closed')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_date > start_date),
  unique (school_id, name),
  unique (school_id, id)
);
create unique index uq_one_active_session on public.academic_sessions (school_id) where is_active;

-- ---------------------------------------------------------------------
-- Students (permanent identity) and session enrollments
-- ---------------------------------------------------------------------
create table public.students (
  id             uuid primary key default gen_random_uuid(),
  school_id      uuid not null references public.schools(id) on delete cascade,
  student_code   text not null,                 -- permanent Student ID (auto)
  admission_no   text not null,
  name           text not null,
  father_name    text,
  mother_name    text,
  gender         text check (gender in ('male','female','other')),
  dob            date,
  admission_date date,
  mobile         text,
  alt_mobile     text,
  whatsapp       text,
  address        text,
  village        text,
  district       text,
  parent_email   text,
  photo_path     text,
  status         text not null default 'active' check (status in ('active','archived','transferred','passed_out')),
  remarks        text,
  created_by     uuid references auth.users(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (school_id, student_code),
  unique (school_id, admission_no),
  unique (school_id, id)
);
create index ix_students_school_status on public.students (school_id, status);
create index ix_students_name_trgm on public.students using gin (name gin_trgm_ops);
create index ix_students_father_trgm on public.students using gin (father_name gin_trgm_ops);
create index ix_students_mobile on public.students (school_id, mobile);

create table public.student_session_enrollments (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null references public.schools(id) on delete cascade,
  session_id uuid not null,
  student_id uuid not null,
  class_name text not null check (class_name in
    ('Nursery','LKG','UKG','Class 1','Class 2','Class 3','Class 4','Class 5','Class 6',
     'Class 7','Class 8','Class 9','Class 10','Class 11','Class 12')),
  section    text,
  roll_no    text,
  category   text not null default 'general' check (category in
    ('general','rte','scholarship','full_waiver','partial_waiver','staff_ward','sibling_concession','custom')),
  custom_category text,
  status     text not null default 'active' check (status in ('active','promoted','left')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (school_id, session_id) references public.academic_sessions (school_id, id) on delete cascade,
  foreign key (school_id, student_id) references public.students (school_id, id) on delete cascade,
  unique (session_id, student_id),
  unique (school_id, id)
);
create index ix_enroll_session_class on public.student_session_enrollments (school_id, session_id, class_name, section);

-- ---------------------------------------------------------------------
-- Families / siblings
-- ---------------------------------------------------------------------
create table public.families (
  id             uuid primary key default gen_random_uuid(),
  school_id      uuid not null references public.schools(id) on delete cascade,
  family_ref     text,
  name           text not null,
  primary_mobile text,
  notes          text,
  created_by     uuid references auth.users(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (school_id, id)
);
create unique index uq_family_ref on public.families (school_id, lower(family_ref)) where family_ref is not null and family_ref <> '';

create table public.family_members (
  id             uuid primary key default gen_random_uuid(),
  school_id      uuid not null references public.schools(id) on delete cascade,
  family_id      uuid not null,
  student_id     uuid not null,
  relationship   text not null default 'sibling',
  verified       boolean not null default false,   -- admin must confirm; never auto-assumed
  verified_by    uuid references auth.users(id),
  verified_at    timestamptz,
  removed_at     timestamptz,
  removed_by     uuid references auth.users(id),
  removed_reason text,
  created_by     uuid references auth.users(id),
  created_at     timestamptz not null default now(),
  foreign key (school_id, family_id)  references public.families (school_id, id) on delete cascade,
  foreign key (school_id, student_id) references public.students (school_id, id) on delete cascade
);
create unique index uq_family_member_active on public.family_members (student_id) where removed_at is null;
create index ix_family_members_family on public.family_members (family_id) where removed_at is null;

create table public.family_policies (
  id               uuid primary key default gen_random_uuid(),
  school_id        uuid not null references public.schools(id) on delete cascade,
  family_id        uuid not null,
  session_id       uuid not null,
  policy_type      text not null check (policy_type in
     ('first_pays_rest_free','first_pays_rest_percent','selected_free','fixed_each','percent_each','custom')),
  payer_student_id uuid,
  value            numeric(12,2) not null default 0,
  reason           text not null,
  approved_by      uuid not null references auth.users(id),
  status           text not null default 'active' check (status in ('active','revoked')),
  created_at       timestamptz not null default now(),
  foreign key (school_id, family_id)  references public.families (school_id, id) on delete cascade,
  foreign key (school_id, session_id) references public.academic_sessions (school_id, id) on delete cascade
);

-- ---------------------------------------------------------------------
-- Fee structure and student fee assignments
-- ---------------------------------------------------------------------
create table public.fee_heads (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  name        text not null,
  is_optional boolean not null default false,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (school_id, name),
  unique (school_id, id)
);

create table public.fee_structures (
  id                 uuid primary key default gen_random_uuid(),
  school_id          uuid not null references public.schools(id) on delete cascade,
  session_id         uuid not null,
  class_name         text not null,
  section            text,
  category           text,
  fee_head_id        uuid not null,
  amount             numeric(12,2) not null check (amount >= 0),
  frequency          text not null default 'annual' check (frequency in
                       ('annual','monthly','quarterly','half_yearly','installment','one_time')),
  installments_count integer not null default 1 check (installments_count between 1 and 36),
  first_due_date     date,
  is_optional        boolean not null default false,
  created_by         uuid references auth.users(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  foreign key (school_id, session_id)  references public.academic_sessions (school_id, id) on delete cascade,
  foreign key (school_id, fee_head_id) references public.fee_heads (school_id, id)
);
create unique index uq_fee_structure on public.fee_structures
  (school_id, session_id, class_name, coalesce(section,''), coalesce(category,''), fee_head_id);

create table public.student_fee_assignments (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  session_id    uuid not null,
  enrollment_id uuid not null,
  student_id    uuid not null,
  fee_head_id   uuid not null,
  structure_id  uuid references public.fee_structures(id) on delete set null,
  amount        numeric(12,2) not null check (amount >= 0),
  source        text not null default 'structure' check (source in ('structure','student_specific','carry_forward')),
  status        text not null default 'active' check (status in ('active','cancelled')),
  reason        text,
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  foreign key (school_id, session_id)    references public.academic_sessions (school_id, id) on delete cascade,
  foreign key (school_id, enrollment_id) references public.student_session_enrollments (school_id, id) on delete cascade,
  foreign key (school_id, fee_head_id)   references public.fee_heads (school_id, id),
  unique (school_id, id)
);
create unique index uq_assign_structure on public.student_fee_assignments (enrollment_id, structure_id) where structure_id is not null;
create unique index uq_assign_specific on public.student_fee_assignments (enrollment_id, fee_head_id)
  where source in ('student_specific','carry_forward') and status = 'active';
create index ix_assign_enrollment on public.student_fee_assignments (enrollment_id);
create index ix_assign_session on public.student_fee_assignments (school_id, session_id);

create table public.fee_installments (
  id             uuid primary key default gen_random_uuid(),
  school_id      uuid not null references public.schools(id) on delete cascade,
  session_id     uuid not null,
  assignment_id  uuid not null references public.student_fee_assignments(id) on delete cascade,
  installment_no integer not null,
  due_date       date not null,
  amount         numeric(12,2) not null check (amount >= 0),
  unique (assignment_id, installment_no)
);
create index ix_installments_due on public.fee_installments (school_id, session_id, due_date);

create table public.fee_adjustments (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  session_id    uuid not null,
  assignment_id uuid not null references public.student_fee_assignments(id),
  old_amount    numeric(12,2) not null,
  new_amount    numeric(12,2) not null,
  reason        text not null,
  adjusted_by   uuid not null references auth.users(id),
  adjusted_at   timestamptz not null default now()
);

create table public.student_discounts (
  id             uuid primary key default gen_random_uuid(),
  school_id      uuid not null references public.schools(id) on delete cascade,
  session_id     uuid not null,
  enrollment_id  uuid not null,
  student_id     uuid not null,
  family_id      uuid,
  policy_id      uuid references public.family_policies(id),
  scholarship_id uuid,
  discount_type  text not null check (discount_type in ('fixed','percentage','full_waiver')),
  value          numeric(12,2) not null default 0 check (value >= 0),  -- rupees for fixed, % for percentage
  reason         text not null,
  approved_by    uuid not null references auth.users(id),
  status         text not null default 'active' check (status in ('active','revoked')),
  revoked_by     uuid references auth.users(id),
  revoked_reason text,
  revoked_at     timestamptz,
  created_at     timestamptz not null default now(),
  foreign key (school_id, session_id)    references public.academic_sessions (school_id, id) on delete cascade,
  foreign key (school_id, enrollment_id) references public.student_session_enrollments (school_id, id) on delete cascade,
  check (discount_type <> 'percentage' or value <= 100)
);
create index ix_discount_enrollment on public.student_discounts (enrollment_id) where status = 'active';

-- ---------------------------------------------------------------------
-- RTE & scholarships
-- ---------------------------------------------------------------------
create table public.rte_records (
  id              uuid primary key default gen_random_uuid(),
  school_id       uuid not null references public.schools(id) on delete cascade,
  student_id      uuid not null,
  session_id      uuid not null,
  certificate_no  text,
  valid_from      date,
  valid_to        date,
  status          text not null default 'active' check (status in ('active','expired','withdrawn')),
  reimbursement_expected numeric(12,2) not null default 0 check (reimbursement_expected >= 0),
  document_path   text,
  remarks         text,
  created_by      uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  foreign key (school_id, student_id) references public.students (school_id, id) on delete cascade,
  foreign key (school_id, session_id) references public.academic_sessions (school_id, id) on delete cascade,
  unique (student_id, session_id)
);

-- Government reimbursement is tracked here and is NEVER counted as parent collection.
create table public.rte_reimbursements (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  rte_record_id uuid not null references public.rte_records(id),
  amount        numeric(12,2) not null check (amount > 0),
  received_on   date not null,
  reference     text,
  recorded_by   uuid references auth.users(id),
  created_at    timestamptz not null default now()
);

create table public.scholarship_records (
  id              uuid primary key default gen_random_uuid(),
  school_id       uuid not null references public.schools(id) on delete cascade,
  student_id      uuid not null,
  session_id      uuid not null,
  name            text not null,
  amount          numeric(12,2) check (amount >= 0),
  percentage      numeric(5,2) check (percentage between 0 and 100),
  approval_status text not null default 'pending' check (approval_status in ('pending','approved','rejected')),
  approved_by     uuid references auth.users(id),
  document_path   text,
  remarks         text,
  created_by      uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  foreign key (school_id, student_id) references public.students (school_id, id) on delete cascade,
  foreign key (school_id, session_id) references public.academic_sessions (school_id, id) on delete cascade,
  check (amount is not null or percentage is not null)
);
alter table public.student_discounts
  add constraint fk_discount_scholarship foreign key (scholarship_id) references public.scholarship_records(id);

-- ---------------------------------------------------------------------
-- Payments (append-only ledger)
-- ---------------------------------------------------------------------
create table public.payments (
  id                   uuid primary key default gen_random_uuid(),
  school_id            uuid not null references public.schools(id) on delete cascade,
  session_id           uuid not null,
  student_id           uuid not null,
  enrollment_id        uuid not null,
  txn_id               text not null,
  receipt_no           text not null,
  amount               numeric(12,2) not null check (amount > 0),
  payment_date         date not null,
  mode                 text not null check (mode in ('cash','upi','bank_transfer','cheque','card','other')),
  status               text not null default 'verified' check (status in ('pending','verified','rejected','cancelled')),
  collector_id         uuid not null references auth.users(id),
  reference            text,
  hard_copy_receipt_no text,
  remarks              text,
  attachment_path      text,
  idempotency_key      text,
  advance_amount       numeric(12,2) not null default 0 check (advance_amount >= 0),
  verified_by          uuid references auth.users(id),
  verified_at          timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  foreign key (school_id, session_id)    references public.academic_sessions (school_id, id),
  foreign key (school_id, enrollment_id) references public.student_session_enrollments (school_id, id),
  unique (school_id, receipt_no),
  unique (school_id, txn_id),
  unique (school_id, id)
);
create unique index uq_payment_idem on public.payments (school_id, idempotency_key) where idempotency_key is not null;
create index ix_payments_enrollment on public.payments (enrollment_id, status);
create index ix_payments_date on public.payments (school_id, session_id, payment_date);
create index ix_payments_student on public.payments (student_id);

create table public.payment_allocations (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  session_id    uuid not null,
  payment_id    uuid not null references public.payments(id),
  assignment_id uuid references public.student_fee_assignments(id),  -- null = advance credit
  amount        numeric(12,2) not null check (amount > 0),
  created_at    timestamptz not null default now()
);
create unique index uq_alloc_pay_assign on public.payment_allocations (payment_id, assignment_id) where assignment_id is not null;
create index ix_alloc_assignment on public.payment_allocations (assignment_id);
create index ix_alloc_payment on public.payment_allocations (payment_id);

create table public.payment_verifications (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null references public.schools(id) on delete cascade,
  payment_id uuid not null references public.payments(id),
  decision   text not null check (decision in ('approved','rejected')),
  decided_by uuid not null references auth.users(id),
  reason     text,
  decided_at timestamptz not null default now()
);

create table public.receipts (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null references public.schools(id) on delete cascade,
  session_id uuid not null,
  payment_id uuid not null unique references public.payments(id),
  receipt_no text not null,
  issued_by  uuid references auth.users(id),
  issued_at  timestamptz not null default now(),
  print_count integer not null default 0,
  unique (school_id, receipt_no)
);

create table public.transaction_reversals (
  id           uuid primary key default gen_random_uuid(),
  school_id    uuid not null references public.schools(id) on delete cascade,
  session_id   uuid not null,
  payment_id   uuid not null unique references public.payments(id),
  amount       numeric(12,2) not null,
  reason       text not null check (length(trim(reason)) >= 5),
  cancelled_by uuid not null references auth.users(id),
  cancelled_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Calling CRM
-- ---------------------------------------------------------------------
create table public.calling_tasks (
  id               uuid primary key default gen_random_uuid(),
  school_id        uuid not null references public.schools(id) on delete cascade,
  session_id       uuid not null,
  student_id       uuid not null,
  enrollment_id    uuid not null,
  assigned_to      uuid not null references auth.users(id),
  co_assignees     uuid[] not null default '{}',   -- extra teachers sharing the SAME task (one completion closes it for all)
  assigned_by      uuid references auth.users(id),
  status           text not null default 'pending' check (status in ('pending','in_progress','promised','completed','cancelled')),
  priority         text not null default 'normal' check (priority in ('low','normal','high','urgent')),
  deadline         date,
  last_call_at     timestamptz,
  call_count       integer not null default 0,
  not_answered_streak integer not null default 0,
  next_followup_date date,
  last_status      text,
  last_remark      text,
  completed_at     timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  foreign key (school_id, session_id)    references public.academic_sessions (school_id, id) on delete cascade,
  foreign key (school_id, student_id)    references public.students (school_id, id) on delete cascade,
  foreign key (school_id, enrollment_id) references public.student_session_enrollments (school_id, id) on delete cascade,
  unique (school_id, id)
);
-- Two teachers can never hold the same active task for one student/session.
create unique index uq_active_calling_task on public.calling_tasks (school_id, session_id, student_id)
  where status in ('pending','in_progress','promised');
create index ix_tasks_assignee on public.calling_tasks (school_id, assigned_to, status);

create table public.task_assignment_history (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null references public.schools(id) on delete cascade,
  task_id    uuid not null references public.calling_tasks(id) on delete cascade,
  from_user  uuid references auth.users(id),
  to_user    uuid not null references auth.users(id),
  changed_by uuid references auth.users(id),
  reason     text,
  changed_at timestamptz not null default now()
);

create table public.calling_logs (
  id               uuid primary key default gen_random_uuid(),
  school_id        uuid not null references public.schools(id) on delete cascade,
  session_id       uuid not null,
  task_id          uuid references public.calling_tasks(id),
  student_id       uuid not null,
  called_by        uuid not null references auth.users(id),
  parent_name      text,
  parent_mobile    text,
  called_at        timestamptz not null default now(),
  call_status      text not null check (call_status in
    ('connected','not_answered','busy','switched_off','wrong_number','callback_requested',
     'promised_to_pay','refused','payment_done','dispute','other')),
  outcome          text,
  parent_response  text,
  remark           text not null check (length(trim(remark)) >= 3),
  promised_date    date,
  next_followup_date date,
  followup_time    time,
  priority         text,
  notes            text,
  created_at       timestamptz not null default now(),
  foreign key (school_id, student_id) references public.students (school_id, id) on delete cascade
);
create index ix_calllogs_student on public.calling_logs (student_id, called_at desc);
create index ix_calllogs_user on public.calling_logs (school_id, called_by, called_at desc);

-- promised_amount lives here (financial visibility rules apply)
create table public.payment_promises (
  id              uuid primary key default gen_random_uuid(),
  school_id       uuid not null references public.schools(id) on delete cascade,
  session_id      uuid not null,
  student_id      uuid not null,
  enrollment_id   uuid not null,
  task_id         uuid references public.calling_tasks(id),
  log_id          uuid references public.calling_logs(id),
  promised_by_user uuid not null references auth.users(id),
  promised_date   date not null,
  promised_amount numeric(12,2) check (promised_amount is null or promised_amount > 0),
  status          text not null default 'pending' check (status in ('pending','kept','overdue','cancelled')),
  resolved_payment_id uuid references public.payments(id),
  resolved_at     timestamptz,
  created_at      timestamptz not null default now(),
  foreign key (school_id, student_id) references public.students (school_id, id) on delete cascade
);
create index ix_promises_status on public.payment_promises (school_id, status, promised_date);

create table public.follow_up_tasks (
  id               uuid primary key default gen_random_uuid(),
  school_id        uuid not null references public.schools(id) on delete cascade,
  session_id       uuid not null,
  task_id          uuid references public.calling_tasks(id),
  student_id       uuid not null,
  assigned_to      uuid not null references auth.users(id),
  kind             text not null default 'follow_up' check (kind in
                     ('follow_up','promise_due','promise_overdue','no_recent_call')),
  due_date         date not null,
  due_time         time,
  status           text not null default 'pending' check (status in ('pending','done','overdue','cancelled')),
  promise_id       uuid references public.payment_promises(id),
  log_id           uuid references public.calling_logs(id),
  dedupe_key       text not null,
  reminder_count   integer not null default 0,
  last_reminded_at timestamptz,
  completed_at     timestamptz,
  completed_log_id uuid references public.calling_logs(id),
  created_at       timestamptz not null default now(),
  foreign key (school_id, student_id) references public.students (school_id, id) on delete cascade,
  unique (school_id, dedupe_key)
);
create index ix_followups_due on public.follow_up_tasks (school_id, assigned_to, status, due_date);

create table public.teacher_calling_targets (
  id             uuid primary key default gen_random_uuid(),
  school_id      uuid not null references public.schools(id) on delete cascade,
  teacher_id     uuid not null references auth.users(id),
  daily_target   integer not null check (daily_target >= 0),
  effective_from date not null default current_date,
  set_by         uuid references auth.users(id),
  created_at     timestamptz not null default now(),
  unique (school_id, teacher_id, effective_from)
);

-- ---------------------------------------------------------------------
-- Notifications (in-app; external channels are extensible via channel col)
-- ---------------------------------------------------------------------
create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid references public.schools(id) on delete cascade,  -- null = platform notification
  user_id     uuid not null references auth.users(id) on delete cascade,
  type        text not null,
  title       text not null,
  body        text,
  link        text,
  channel     text not null default 'in_app' check (channel in ('in_app','email','sms','whatsapp')),
  delivery_status text not null default 'delivered' check (delivery_status in ('delivered','queued','not_configured','failed')),
  is_read     boolean not null default false,
  read_at     timestamptz,
  dedupe_key  text,
  created_at  timestamptz not null default now()
);
create unique index uq_notif_dedupe on public.notifications (user_id, dedupe_key) where dedupe_key is not null;
create index ix_notif_user on public.notifications (user_id, is_read, created_at desc);

-- ---------------------------------------------------------------------
-- Audit log (append-only)
-- ---------------------------------------------------------------------
create table public.audit_logs (
  id          bigint generated always as identity primary key,
  school_id   uuid,
  user_id     uuid,
  action      text not null,
  record_type text,
  record_id   text,
  old_values  jsonb,
  new_values  jsonb,
  reason      text,
  created_at  timestamptz not null default now()
);
create index ix_audit_school_time on public.audit_logs (school_id, created_at desc);
create index ix_audit_record on public.audit_logs (record_type, record_id);

-- ---------------------------------------------------------------------
-- Import, attachments
-- ---------------------------------------------------------------------
create table public.import_batches (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  session_id  uuid,
  filename    text,
  file_hash   text,
  total_rows  integer not null default 0,
  imported    integer not null default 0,
  skipped     integer not null default 0,
  failed      integer not null default 0,
  status      text not null default 'processing' check (status in ('processing','completed','failed')),
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now(),
  unique (school_id, id)
);

create table public.import_errors (
  id        uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  batch_id  uuid not null references public.import_batches(id) on delete cascade,
  row_no    integer not null,
  raw       jsonb,
  errors    text[] not null,
  kind      text not null default 'error' check (kind in ('error','duplicate','skipped'))
);

create table public.file_attachments (
  id           uuid primary key default gen_random_uuid(),
  school_id    uuid not null references public.schools(id) on delete cascade,
  bucket       text not null,
  path         text not null,
  entity_type  text not null,
  entity_id    uuid,
  filename     text,
  content_type text,
  size_bytes   bigint,
  uploaded_by  uuid references auth.users(id),
  created_at   timestamptz not null default now()
);

-- updated_at triggers
do $$
declare t text;
begin
  for t in select c.table_name from information_schema.columns c
           where c.table_schema='public' and c.column_name='updated_at'
             and c.table_name in (select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE')
  loop
    execute format('create trigger trg_%1$s_updated before update on public.%1$s for each row execute function public.set_updated_at()', t);
  end loop;
end $$;
