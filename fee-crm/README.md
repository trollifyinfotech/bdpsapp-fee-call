# Trollify — School Fee & Recovery Management System

Multi-school SaaS for fee collection, receipts, dues recovery and a Calling CRM. Vanilla HTML/CSS/JS, Bootstrap 5, Supabase.

**Start with [SETUP-GUIDE.md](SETUP-GUIDE.md).**

## Layout
```
index.html login.html register.html app.html     entry pages (app.html = SPA for all school roles)
super-admin/index.html                           platform console (approvals, schools, subscriptions)
js/supabase-config.js                            ONLY config file (URL + anon key)
js/*.js                                          modules: students, fees, payments, receipts, calling-crm, reports, admin...
css/app.css
supabase/ALL_IN_ONE.sql                          all migrations in ONE paste-and-run file
supabase/migrations/001..011                     schema, functions, RLS, storage, no-CLI user admin, delete, shared tasks, deadlines + bulk assign
supabase/tests/run_tests.sql                     182 DB tests
supabase/seed.sql                                demo data functions (never auto-run)
templates/students-import-template.csv
```

## Security model
- Every table has `school_id` and RLS; the school is derived server-side from the JWT (`my_school_id()`), never from client input.
- Writes go through SECURITY DEFINER RPCs that check permissions (`has_perm`); privileged actions are SECURITY DEFINER RPCs that verify the caller (no Edge Functions needed).
- The service_role key is never used anywhere.
- Teachers hold no fee-amount permissions: RLS returns no payment/fee rows and the CRM RPCs return NULL amounts.
- Money is `NUMERIC`; balances are derived (view `v_enrollment_balances`); payments, receipts and audit logs are append-only; cancellation is a reversal record.
- Payment submission is idempotent (`idempotency_key`).

## Roles
Super Admin (platform), School Owner, Principal, Accountant, Clerk, Teacher — plus per-user permission grants/denials.
