-- Trollify: ALL migrations 001-011 in one file. FRESH install only: paste into Supabase SQL Editor and press Run (once).
-- Already installed earlier? Do NOT run this; run only the newest migration(s) you have not run yet (see SETUP-GUIDE.md).
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
  status           text not null default 'pending' check (status in ('pending','in_progress','promised','completed','cancelled','expired')),
  priority         text not null default 'normal' check (priority in ('low','normal','high','urgent')),
  deadline         date,
  last_call_at     timestamptz,
  call_count       integer not null default 0,
  not_answered_streak integer not null default 0,
  next_followup_date date,
  last_status      text,
  last_remark      text,
  completed_at     timestamptz,
  expired_at       timestamptz,      -- set when the deadline passed without completion
  renewed_at       timestamptz,      -- set when a new task replaced this expired one
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
  to_user    uuid references auth.users(id),      -- null = a teacher was removed from the task
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
-- =====================================================================
-- Migration 002 : Authorization helpers, triggers, reference data
-- =====================================================================

-- ---------------------------------------------------------------------
-- Authorization helpers (SECURITY DEFINER so RLS policies can call them
-- without recursive policy evaluation).
-- ---------------------------------------------------------------------
create or replace function public.is_super_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.is_super_admin from public.user_profiles p where p.id = auth.uid()), false);
$$;

create or replace function public.school_is_usable(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.schools s where s.id = sid and s.status = 'active')
     and not exists (select 1 from public.school_subscriptions ss
                     where ss.school_id = sid and ss.status = 'active'
                       and ss.expires_on is not null and ss.expires_on < current_date);
$$;

create or replace function public.is_member(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.school_memberships m
                 where m.school_id = sid and m.user_id = auth.uid() and m.is_active)
     and public.school_is_usable(sid);
$$;

create or replace function public.my_role(sid uuid) returns text
language sql stable security definer set search_path = public as $$
  select m.role_code from public.school_memberships m
  where m.school_id = sid and m.user_id = auth.uid() and m.is_active
$$;

-- Effective permission = explicit per-user override (grant OR deny) else role default.
create or replace function public.user_has_perm(uid uuid, sid uuid, code text) returns boolean
language sql stable security definer set search_path = public as $$
  select
    exists (select 1 from public.school_memberships m
            where m.school_id = sid and m.user_id = uid and m.is_active)
    and public.school_is_usable(sid)
    and coalesce(
      (select up.granted from public.user_permissions up
        where up.school_id = sid and up.user_id = uid and up.permission_code = code),
      exists (select 1 from public.school_memberships m
              join public.role_permissions rp on rp.role_code = m.role_code
              where m.school_id = sid and m.user_id = uid and m.is_active and rp.permission_code = code)
    );
$$;

create or replace function public.has_perm(sid uuid, code text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.user_has_perm(auth.uid(), sid, code);
$$;

-- Returns the caller's school (first active membership). The frontend still
-- sends no school_id for sensitive operations: RPCs derive it from here.
create or replace function public.my_school_id() returns uuid
language sql stable security definer set search_path = public as $$
  select m.school_id from public.school_memberships m
  where m.user_id = auth.uid() and m.is_active and public.school_is_usable(m.school_id)
  order by m.created_at limit 1;
$$;

-- Raises unless caller holds the permission in the school.
create or replace function public.require_perm(sid uuid, code text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if sid is null or not public.has_perm(sid, code) then
    raise exception 'Permission denied: % required', code using errcode = '42501';
  end if;
end $$;

-- School-local date (India). All due-date / reminder logic uses this, not UTC current_date.
create or replace function public.today_local() returns date
language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- ---------------------------------------------------------------------
-- Counters / notifications / audit helpers
-- ---------------------------------------------------------------------
create or replace function public.next_counter(sid uuid, k text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  insert into public.counters (school_id, key, value) values (sid, k, 1)
  on conflict (school_id, key) do update set value = public.counters.value + 1
  returning value into v;
  return v;
end $$;
revoke all on function public.next_counter(uuid, text) from public, anon, authenticated;

create or replace function public.notify(sid uuid, uid uuid, ntype text, ntitle text, nbody text,
                                         nlink text default null, ndedupe text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if uid is null then return; end if;
  insert into public.notifications (school_id, user_id, type, title, body, link, dedupe_key)
  values (sid, uid, ntype, ntitle, nbody, nlink, ndedupe)
  on conflict (user_id, dedupe_key) where dedupe_key is not null do nothing;
end $$;
revoke all on function public.notify(uuid, uuid, text, text, text, text, text) from public, anon, authenticated;

-- Notify every active member of the school who holds a permission.
create or replace function public.notify_perm(sid uuid, perm text, ntype text, ntitle text, nbody text,
                                              nlink text default null, ndedupe text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select m.user_id from public.school_memberships m where m.school_id = sid and m.is_active loop
    if public.user_has_perm(r.user_id, sid, perm) then
      perform public.notify(sid, r.user_id, ntype, ntitle, nbody, nlink,
                            case when ndedupe is null then null else ndedupe || ':' || r.user_id end);
    end if;
  end loop;
end $$;
revoke all on function public.notify_perm(uuid, text, text, text, text, text, text) from public, anon, authenticated;

create or replace function public.notify_roles(sid uuid, roles text[], ntype text, ntitle text, nbody text,
                                               nlink text default null, ndedupe text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select m.user_id from public.school_memberships m
           where m.school_id = sid and m.is_active and m.role_code = any(roles) loop
    perform public.notify(sid, r.user_id, ntype, ntitle, nbody, nlink,
                          case when ndedupe is null then null else ndedupe || ':' || r.user_id end);
  end loop;
end $$;
revoke all on function public.notify_roles(uuid, text[], text, text, text, text, text) from public, anon, authenticated;

create or replace function public.audit_write(sid uuid, act text, rtype text, rid text,
                                              oldv jsonb, newv jsonb, why text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_logs (school_id, user_id, action, record_type, record_id, old_values, new_values, reason)
  values (sid, auth.uid(), act, rtype, rid, oldv, newv, why);
end $$;
revoke all on function public.audit_write(uuid, text, text, text, jsonb, jsonb, text) from public, anon, authenticated;

-- Client-callable audit for events the database cannot observe (login/logout/export).
create or replace function public.log_audit(p_action text, p_record_type text default null, p_details jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid := public.my_school_id();
begin
  if p_action not in ('login','logout','data_export','report_print') then
    raise exception 'Action not allowed from client';
  end if;
  insert into public.audit_logs (school_id, user_id, action, record_type, new_values)
  values (sid, auth.uid(), p_action, p_record_type, p_details);
end $$;

-- Generic row-level audit trigger
create or replace function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  rec jsonb; oldj jsonb; sid uuid; rid text; why text;
begin
  why := nullif(current_setting('app.audit_reason', true), '');
  if tg_op = 'DELETE' then rec := to_jsonb(old); oldj := rec;
  elsif tg_op = 'UPDATE' then
    rec := to_jsonb(new); oldj := to_jsonb(old);
    if rec = oldj then return new; end if;
  else rec := to_jsonb(new); end if;
  sid := nullif(rec->>'school_id', '')::uuid;
  if tg_table_name = 'schools' then sid := (rec->>'id')::uuid; end if;
  rid := coalesce(rec->>'id', rec->>'user_id');
  insert into public.audit_logs (school_id, user_id, action, record_type, record_id, old_values, new_values, reason)
  values (sid, auth.uid(), lower(tg_table_name || '.' || tg_op), tg_table_name, rid, oldj,
          case when tg_op = 'DELETE' then null else rec end, why);
  return case when tg_op = 'DELETE' then old else new end;
end $$;

do $$
declare t text;
begin
  foreach t in array array['students','student_session_enrollments','families','family_members','family_policies',
    'fee_heads','fee_structures','student_fee_assignments','fee_adjustments','student_discounts','rte_records','rte_reimbursements',
    'scholarship_records','payments','payment_verifications','receipts','transaction_reversals','calling_tasks',
    'task_assignment_history','calling_logs','payment_promises','school_memberships','user_permissions',
    'academic_sessions','school_settings','schools','import_batches','teacher_calling_targets','school_subscriptions']
  loop
    execute format('create trigger trg_audit_%1$s after insert or update or delete on public.%1$s for each row execute function public.audit_row()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Immutability: financial + audit records are never silently erased.
-- ---------------------------------------------------------------------
create or replace function public.forbid_delete() returns trigger language plpgsql as $$
begin
  -- only delete_students_permanently() sets this flag; it first refuses students with payments / fee adjustments / RTE reimbursements
  if tg_table_name in ('task_assignment_history','calling_logs') and current_setting('app.student_purge', true) = 'on' then
    return old;
  end if;
  raise exception 'Deleting % records is not allowed (append-only). Use cancellation/reversal.', tg_table_name
    using errcode = '42501';
end $$;

create or replace function public.forbid_update() returns trigger language plpgsql as $$
begin
  raise exception '% records are immutable.', tg_table_name using errcode = '42501';
end $$;

do $$
declare t text;
begin
  foreach t in array array['payments','payment_allocations','payment_verifications','receipts',
      'transaction_reversals','calling_logs','audit_logs','task_assignment_history','fee_adjustments','rte_reimbursements']
  loop
    execute format('create trigger trg_nodelete_%1$s before delete on public.%1$s for each row execute function public.forbid_delete()', t);
  end loop;
  foreach t in array array['payment_allocations','payment_verifications','transaction_reversals',
      'calling_logs','audit_logs','task_assignment_history','fee_adjustments']
  loop
    execute format('create trigger trg_noupdate_%1$s before update on public.%1$s for each row execute function public.forbid_update()', t);
  end loop;
end $$;

-- Payments: only status / verification columns may change after creation.
create or replace function public.payments_guard() returns trigger language plpgsql as $$
begin
  if new.amount is distinct from old.amount or new.school_id is distinct from old.school_id
     or new.session_id is distinct from old.session_id or new.student_id is distinct from old.student_id
     or new.enrollment_id is distinct from old.enrollment_id or new.receipt_no is distinct from old.receipt_no
     or new.txn_id is distinct from old.txn_id or new.payment_date is distinct from old.payment_date
     or new.mode is distinct from old.mode or new.collector_id is distinct from old.collector_id then
    raise exception 'Payment core fields are immutable. Cancel and re-enter instead.' using errcode = '42501';
  end if;
  if old.status in ('rejected','cancelled') and new.status is distinct from old.status then
    raise exception 'A % payment cannot change status.', old.status using errcode = '42501';
  end if;
  if old.status = 'verified' and new.status not in ('verified','cancelled') then
    raise exception 'Verified payment can only be cancelled.' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger trg_payments_guard before update on public.payments
  for each row execute function public.payments_guard();

-- Allocations must equal payment amount (checked at commit so batches can insert rows one by one)
create or replace function public.check_allocation_total() returns trigger
language plpgsql as $$
declare p record; s numeric;
begin
  select id, amount into p from public.payments where id = new.payment_id;
  select coalesce(sum(amount), 0) into s from public.payment_allocations where payment_id = new.payment_id;
  if s <> p.amount then
    raise exception 'Allocation total % does not equal payment amount % (payment %)', s, p.amount, p.id;
  end if;
  return null;
end $$;
create constraint trigger trg_alloc_total after insert on public.payment_allocations
  deferrable initially deferred for each row execute function public.check_allocation_total();

-- ---------------------------------------------------------------------
-- Students: permanent ID, subscription limit, protected columns
-- ---------------------------------------------------------------------
create or replace function public.students_before_write() returns trigger
language plpgsql security definer set search_path = public as $$
declare maxs int; cnt int;
begin
  if tg_op = 'INSERT' then
    if new.student_code is null or new.student_code = '' then
      new.student_code := 'STU-' || lpad(public.next_counter(new.school_id, 'student')::text, 6, '0');
    end if;
    new.created_by := coalesce(new.created_by, auth.uid());
    select ss.max_students into maxs from public.school_subscriptions ss
      where ss.school_id = new.school_id and ss.status = 'active';
    if maxs is not null then
      select count(*) into cnt from public.students where school_id = new.school_id and status = 'active';
      if cnt >= maxs then
        raise exception 'Subscription student limit (%) reached for this school.', maxs;
      end if;
    end if;
  else
    if new.student_code is distinct from old.student_code or new.school_id is distinct from old.school_id then
      raise exception 'Student ID and school are permanent and cannot be changed.' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
create trigger trg_students_before before insert or update on public.students
  for each row execute function public.students_before_write();

-- ---------------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.user_profiles (id, email, full_name, mobile)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data->>'full_name', ''),
          new.raw_user_meta_data->>'mobile')
  on conflict (id) do nothing;
  return new;
end $$;
create trigger trg_on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.profile_guard() returns trigger language plpgsql as $$
begin
  if new.is_super_admin is distinct from old.is_super_admin
     and current_setting('role', true) in ('authenticated', 'anon') then
    raise exception 'Cannot change platform role.' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger trg_profile_guard before update on public.user_profiles
  for each row execute function public.profile_guard();

-- Memberships: nobody can alter their own role/activation via any path.
create or replace function public.membership_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and old.user_id = auth.uid()
     and (new.role_code is distinct from old.role_code or new.is_active is distinct from old.is_active)
     and current_setting('role', true) in ('authenticated', 'anon') then
    raise exception 'You cannot change your own role or status.' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger trg_membership_guard before update on public.school_memberships
  for each row execute function public.membership_guard();

-- ---------------------------------------------------------------------
-- Session validation: an enrollment's session must be open for new financial work
-- ---------------------------------------------------------------------
create or replace function public.session_is_open(sid uuid, sess uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.academic_sessions s where s.id = sess and s.school_id = sid and s.status = 'open');
$$;

-- ---------------------------------------------------------------------
-- Reference data: roles, permissions, role defaults, plans
-- ---------------------------------------------------------------------
insert into public.roles (code, name, description, rank) values
 ('super_admin','Super Admin','Platform owner (platform-level only)',100),
 ('school_owner','School Owner','Full control of the school account',90),
 ('principal','Principal','Administrative access, approvals and monitoring',80),
 ('accountant','Accountant','Fee collection, ledgers and financial reports',60),
 ('fee_manager','Fee Manager','Fee collection and fee structure',50),
 ('teacher','Teacher','Parent calling only; no financial amounts',30),
 ('viewer','Viewer / Auditor','Read-only reports and audit',10);

insert into public.permissions (code, name, category) values
 ('view_student_list','View Student List','Students'),
 ('add_student','Add Student','Students'),
 ('edit_student','Edit Student','Students'),
 ('archive_student','Archive Student','Students'),
 ('delete_student','Delete Student Permanently (wrong entries)','Students'),
 ('import_students','Import Students','Students'),
 ('manage_families','Manage Families & Siblings','Students'),
 ('manage_rte','Manage RTE & Scholarships','Students'),
 ('view_fee_details','View Fee Details (status)','Fees'),
 ('view_fee_amounts','View Fee Amounts','Fees'),
 ('collect_fee','Collect Fee','Fees'),
 ('edit_fee_structure','Edit Fee Structure','Fees'),
 ('apply_discount','Apply Discount','Fees'),
 ('approve_payment','Approve Online Payment','Fees'),
 ('cancel_receipt','Cancel Receipt','Fees'),
 ('print_receipt','Print Receipt','Fees'),
 ('view_fee_reports','View Fee Reports','Reports'),
 ('export_csv','Export CSV','Reports'),
 ('export_pdf','Export PDF','Reports'),
 ('view_financial_dashboard','View Financial Dashboard','Reports'),
 ('view_calling_crm','View Calling CRM','Calling CRM'),
 ('make_calls','Make Parent Calls','Calling CRM'),
 ('add_call_remarks','Add Calling Remarks','Calling CRM'),
 ('assign_calling_tasks','Assign Calling Tasks','Calling CRM'),
 ('view_teacher_performance','View Teacher Performance','Calling CRM'),
 ('manage_sessions','Manage Sessions','Administration'),
 ('manage_users','Manage Users','Administration'),
 ('manage_permissions','Manage Roles & Permissions','Administration'),
 ('manage_settings','Manage Settings','Administration'),
 ('view_audit_logs','View Audit Logs','Administration');

-- owner: everything
insert into public.role_permissions select 'school_owner', code from public.permissions;
-- principal: everything except permission management
insert into public.role_permissions select 'principal', code from public.permissions where code <> 'manage_permissions';
-- accountant
insert into public.role_permissions select 'accountant', code from public.permissions where code in
 ('view_student_list','view_fee_details','view_fee_amounts','collect_fee','print_receipt','view_fee_reports',
  'export_csv','export_pdf','view_financial_dashboard','manage_rte');
-- fee manager
insert into public.role_permissions select 'fee_manager', code from public.permissions where code in
 ('view_student_list','view_fee_details','view_fee_amounts','collect_fee','edit_fee_structure','print_receipt',
  'view_fee_reports','export_csv');
-- teacher: calling only, NO financial permission
insert into public.role_permissions select 'teacher', code from public.permissions where code in
 ('view_calling_crm','make_calls','add_call_remarks');
-- viewer / auditor
insert into public.role_permissions select 'viewer', code from public.permissions where code in
 ('view_student_list','view_fee_details','view_fee_amounts','view_fee_reports','view_financial_dashboard',
  'view_teacher_performance','view_audit_logs','export_csv','export_pdf');

insert into public.subscription_plans (code, name, max_students, max_users, price_monthly) values
 ('trial','Trial',300,10,0),
 ('standard','Standard',1500,30,999),
 ('premium','Premium',10000,100,2999);
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
-- =====================================================================
-- Migration 005 : Calling CRM, promises, follow-ups, reminder engine
--
-- Privacy: calling functions NEVER return fee amounts unless the caller
-- holds view_fee_amounts. This is enforced here (database), not in HTML.
-- A dialer launch is NOT a call: only a saved calling_logs row counts.
-- =====================================================================

-- A task can be shared by several teachers (assigned_to + co_assignees). One task row = one completion for everybody.
create or replace function public.task_has_assignee(p_assigned uuid, p_co uuid[], p_user uuid) returns boolean
language sql immutable as $$ select p_user is not null and (p_user = p_assigned or p_user = any(coalesce(p_co, '{}'))) $$;

-- Statuses that mean a conversation happened (parent was reached)
create or replace function public.call_is_connected(s text) returns boolean language sql immutable as $$
  select s in ('connected','callback_requested','promised_to_pay','refused','payment_done','dispute')
$$;

-- ---------------------------------------------------------------------
-- Task assignment
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- Deadline handling: an assignment ends at its deadline. After that the task is EXPIRED, disappears
-- from the teachers' lists and the administrator has to assign a NEW task (or "Renew" the old one).
-- ---------------------------------------------------------------------
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

-- Called by the app (any staff member) so deadlines are enforced the moment somebody opens a page.
create or replace function public.expire_my_tasks() returns int
language plpgsql security definer set search_path = public as $$
declare sid uuid := public.my_school_id();
begin
  if sid is null then return 0; end if;
  return public.expire_overdue_tasks(sid);
end $$;

-- ---------------------------------------------------------------------
-- Bulk change of who is responsible for tasks.  mode: set (replace all teachers = TRANSFER / CHANGE),
-- add (also give to more teachers), remove (take the task away from these teachers).
-- The first teacher of a task is its main assignee; the others share the very same task.
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- Renew: after a deadline is over, start a NEW task for the same student (same teachers unless you choose others).
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- Auto-resolution when a verified payment arrives
-- ---------------------------------------------------------------------
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
-- =====================================================================
-- Migration 008 : Storage buckets and policies
-- Path convention for every bucket: <school_id>/<anything>
-- so policies can verify school membership from the first folder name.
-- Buckets are PRIVATE (served through signed URLs) except school-logos
-- which is public-read so the login/registration pages can show logos.
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('school-logos',      'school-logos',      true,  2097152,  array['image/png','image/jpeg','image/webp']),
  ('student-photos',    'student-photos',    false, 2097152,  array['image/png','image/jpeg','image/webp']),
  ('receipt-attachments','receipt-attachments', false, 5242880, array['image/png','image/jpeg','application/pdf']),
  ('rte-documents',     'rte-documents',     false, 5242880,  array['image/png','image/jpeg','application/pdf'])
on conflict (id) do nothing;

-- Registration logos are uploaded by the new (not yet approved) owner into  pending/<auth.uid()>/...
create policy "logos public read" on storage.objects for select using (bucket_id = 'school-logos');
create policy "logos pending upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'school-logos' and (storage.foldername(name))[1] = 'pending'
              and (storage.foldername(name))[2] = auth.uid()::text);
create policy "logos school upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'school-logos' and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
              and public.has_perm(((storage.foldername(name))[1])::uuid, 'manage_settings'));

create policy "photos read" on storage.objects for select to authenticated
  using (bucket_id = 'student-photos' and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
         and public.has_perm(((storage.foldername(name))[1])::uuid, 'view_student_list'));
create policy "photos write" on storage.objects for insert to authenticated
  with check (bucket_id = 'student-photos' and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
              and (public.has_perm(((storage.foldername(name))[1])::uuid, 'add_student')
                   or public.has_perm(((storage.foldername(name))[1])::uuid, 'edit_student')));

create policy "receipt att read" on storage.objects for select to authenticated
  using (bucket_id = 'receipt-attachments' and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
         and public.has_perm(((storage.foldername(name))[1])::uuid, 'view_fee_amounts'));
create policy "receipt att write" on storage.objects for insert to authenticated
  with check (bucket_id = 'receipt-attachments' and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
              and public.has_perm(((storage.foldername(name))[1])::uuid, 'collect_fee'));

create policy "rte read" on storage.objects for select to authenticated
  using (bucket_id = 'rte-documents' and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
         and public.has_perm(((storage.foldername(name))[1])::uuid, 'manage_rte'));
create policy "rte write" on storage.objects for insert to authenticated
  with check (bucket_id = 'rte-documents' and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
              and public.has_perm(((storage.foldername(name))[1])::uuid, 'manage_rte'));
-- No UPDATE/DELETE policies on any bucket for end users: files are never silently removed.
-- =====================================================================
-- 009: Everything that used to need Edge Functions / CLI, done in SQL.
-- After this migration NO Edge Function and NO service_role key is needed.
--   * submit_registration       : school self-registration (after browser signUp)
--   * admin_attach_user         : attach a freshly signed-up account to my school
--   * admin_reset_password      : owner/principal resets a user's password
--   * set_member_active         : activate / deactivate a user
--   * run_my_reminders          : throttled reminder run, triggered from the app
--   * pg_cron job               : optional, runs reminders every 30 minutes
-- =====================================================================

-- ---------- 1. School self-registration ----------
create or replace function public.submit_registration(
  p_school_name text, p_school_code text, p_udise text, p_address text, p_city text, p_district text, p_state text,
  p_owner_name text, p_mobile text, p_logo_path text, p_terms boolean)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); em text; mob text; code text := upper(trim(coalesce(p_school_code,'')));
        sa record;
begin
  if uid is null then raise exception 'Not signed in' using errcode='42501'; end if;
  select email into em from auth.users where id = uid;
  if exists (select 1 from public.school_memberships where user_id = uid)
     or exists (select 1 from public.user_profiles where id = uid and is_super_admin)
     or exists (select 1 from public.school_registration_requests where owner_user_id = uid) then
    raise exception 'This account is already linked to a school or registration.';
  end if;
  mob := regexp_replace(coalesce(p_mobile,''), '\D', '', 'g');
  if length(mob) = 12 and left(mob,2) = '91' then mob := substr(mob,3); end if;
  if length(trim(coalesce(p_school_name,''))) < 3 then raise exception 'School name is required'; end if;
  if code !~ '^[A-Z0-9_-]{3,20}$' then raise exception 'School code must be 3-20 letters/numbers'; end if;
  if length(trim(coalesce(p_owner_name,''))) < 2 then raise exception 'Principal/Owner name is required'; end if;
  if mob !~ '^[6-9][0-9]{9}$' then raise exception 'Enter a valid 10-digit mobile number'; end if;
  if p_terms is not true then raise exception 'You must accept the Terms and Conditions'; end if;
  if p_logo_path is not null and p_logo_path not like 'pending/' || uid::text || '/%' then
    raise exception 'Invalid logo path'; end if;
  if exists (select 1 from public.schools where lower(school_code) = lower(code))
     or exists (select 1 from public.school_registration_requests where lower(school_code) = lower(code) and status in ('pending','approved')) then
    raise exception 'This school code is already registered'; end if;
  if nullif(trim(p_udise),'') is not null and exists (select 1 from public.school_registration_requests
       where udise_code = trim(p_udise) and status in ('pending','approved')) then
    raise exception 'This UDISE code is already registered'; end if;

  insert into public.school_registration_requests (school_name, school_code, udise_code, address, state, district, city,
      owner_name, mobile, email, owner_user_id, logo_path, terms_accepted)
  values (trim(p_school_name), code, nullif(trim(p_udise),''), trim(coalesce(p_address,'')), trim(coalesce(p_state,'')),
      trim(coalesce(p_district,'')), trim(coalesce(p_city,'')), trim(p_owner_name), mob, lower(em), uid, p_logo_path, true);
  update public.user_profiles set full_name = trim(p_owner_name), mobile = mob where id = uid;

  for sa in select id from public.user_profiles where is_super_admin loop
    insert into public.notifications (user_id, type, title, body, link, dedupe_key)
    values (sa.id, 'school_registration', 'New school registration',
            trim(p_school_name) || ' (' || code || ') is awaiting approval', '/super-admin/index.html', 'reg:' || uid)
    on conflict do nothing;
  end loop;
end $$;

-- ---------- 2. Add a user to my school ----------
-- The browser creates the login with auth.signUp (separate, non-persisting client);
-- this RPC then attaches that brand-new account. Safety rules: the account must be
-- < 10 minutes old, must have no school/registration yet, and the caller needs manage_users.
create or replace function public.admin_attach_user(p_user uuid, p_full_name text, p_mobile text, p_role text, p_designation text)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid := public.my_school_id(); myrole text; mob text; created timestamptz; lim int; cnt int; em text;
begin
  perform public.require_perm(sid, 'manage_users');
  myrole := public.my_role(sid);
  if p_role not in ('principal','accountant','fee_manager','teacher','viewer') then raise exception 'Invalid role'; end if;
  if p_role = 'principal' and myrole <> 'school_owner' then
    raise exception 'Only the School Owner can create a Principal' using errcode='42501'; end if;
  if length(trim(coalesce(p_full_name,''))) < 2 then raise exception 'Name is required'; end if;
  mob := regexp_replace(coalesce(p_mobile,''), '\D', '', 'g');
  if length(mob) = 12 and left(mob,2) = '91' then mob := substr(mob,3); end if;
  if mob <> '' and mob !~ '^[6-9][0-9]{9}$' then raise exception 'Invalid mobile number'; end if;
  select created_at, email into created, em from auth.users where id = p_user;
  if created is null then raise exception 'Account not found'; end if;
  if created < now() - interval '10 minutes' then raise exception 'This account was not created just now and cannot be attached'; end if;
  if exists (select 1 from public.school_memberships where user_id = p_user)
     or exists (select 1 from public.school_registration_requests where owner_user_id = p_user)
     or exists (select 1 from public.user_profiles where id = p_user and is_super_admin) then
    raise exception 'This account already belongs to a school'; end if;
  select max_users into lim from public.school_subscriptions where school_id = sid and status = 'active';
  select count(*) into cnt from public.school_memberships where school_id = sid and is_active;
  if lim is not null and cnt >= lim then raise exception 'User limit (%) of your subscription is reached', lim; end if;

  insert into public.school_memberships (school_id, user_id, role_code, designation, created_by)
  values (sid, p_user, p_role, nullif(trim(p_designation),''), auth.uid());
  update public.user_profiles set full_name = trim(p_full_name), mobile = nullif(mob,'') where id = p_user;
  perform public.audit_write(sid, 'user.created', 'user', p_user::text, null,
          jsonb_build_object('email', em, 'role', p_role, 'full_name', trim(p_full_name)), null);
end $$;

-- ---------- 3. Reset password / activate / deactivate ----------
create or replace function public._target_member_check(p_user uuid, p_for_active boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid := public.my_school_id(); myrole text; trole text;
begin
  perform public.require_perm(sid, 'manage_users');
  myrole := public.my_role(sid);
  select role_code into trole from public.school_memberships where school_id = sid and user_id = p_user;
  if trole is null then raise exception 'User not found in your school'; end if;
  if p_for_active and p_user = auth.uid() then raise exception 'You cannot deactivate your own account'; end if;
  if trole = 'school_owner' and myrole <> 'school_owner' then
    raise exception 'Only the Owner can modify the Owner account' using errcode='42501'; end if;
  if trole = 'principal' and myrole not in ('school_owner') and p_user <> auth.uid() then
    raise exception 'Only the Owner can modify a Principal' using errcode='42501'; end if;
  return sid;
end $$;

create or replace function public.admin_reset_password(p_user uuid, p_password text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare sid uuid;
begin
  sid := public._target_member_check(p_user);
  if length(coalesce(p_password,'')) < 8 or p_password !~ '[A-Za-z]' or p_password !~ '[0-9]' then
    raise exception 'Password must be at least 8 characters with letters and numbers'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now()
   where id = p_user;
  begin delete from auth.sessions where user_id = p_user; exception when undefined_table then null; end;
  perform public.audit_write(sid, 'user.password_reset', 'user', p_user::text, null, null, null);
end $$;

create or replace function public.set_member_active(p_user uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  sid := public._target_member_check(p_user, true);
  update public.school_memberships set is_active = coalesce(p_active, false) where school_id = sid and user_id = p_user;
  if not coalesce(p_active, false) then
    begin delete from auth.sessions where user_id = p_user; exception when undefined_table then null; end;
  end if;
end $$;

-- ---------- 4. Reminders without any scheduler ----------
create table if not exists public.reminder_runs (school_id uuid primary key references public.schools(id) on delete cascade, last_run timestamptz not null);
alter table public.reminder_runs enable row level security;   -- no policies: RPC only

-- Called by the app when any staff member opens it. Idempotent and throttled to once per 20 minutes per school.
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

-- Optional: pg_cron every 30 minutes (enable "pg_cron" under Database > Extensions; harmless if unavailable)
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('trollify-reminders', '*/30 * * * *', 'select public.expire_overdue_tasks(null); select public.run_reminders(null)');
exception when others then
  raise notice 'pg_cron not available (%). Reminders will still run when staff open the app.', sqlerrm;
end $$;

-- ---------- privileges ----------
revoke all on function public.submit_registration(text,text,text,text,text,text,text,text,text,text,boolean) from public, anon;
revoke all on function public.admin_attach_user(uuid,text,text,text,text) from public, anon;
revoke all on function public.admin_reset_password(uuid,text) from public, anon;
revoke all on function public.set_member_active(uuid,boolean) from public, anon;
revoke all on function public.run_my_reminders() from public, anon;
revoke all on function public._target_member_check(uuid,boolean) from public, anon, authenticated;
grant execute on function public.submit_registration(text,text,text,text,text,text,text,text,text,text,boolean) to authenticated;
grant execute on function public.admin_attach_user(uuid,text,text,text,text) to authenticated;
grant execute on function public.admin_reset_password(uuid,text) to authenticated;
grant execute on function public.set_member_active(uuid,boolean) to authenticated;
grant execute on function public.run_my_reminders() to authenticated;
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
