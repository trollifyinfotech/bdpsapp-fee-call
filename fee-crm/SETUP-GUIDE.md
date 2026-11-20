# Trollify — Setup Guide (NO Node.js, NO CLI, NO Edge Functions)

> **Already installed an earlier version?** Do NOT re-run `ALL_IN_ONE.sql`. In the SQL Editor run, **once each and in this order**, only the files you have not run yet:
> `010_delete_and_shared_tasks.sql` (permanent delete, shared tasks) and then `011_task_deadlines_bulk_assign.sql` (deadlines, bulk transfer, filters).
> Then upload the new website files (whole folder).

You only need: a free Supabase project, its **Project URL**, its **anon key**, and a way to host static files.

1. **Create a Supabase project** at supabase.com (Region: Mumbai).
2. **Copy** *Project Settings → API*: the Project URL and the anon / publishable key.
3. **Paste them** in `js/supabase-config.js` (the only config file). Never use the service_role key.
4. **Database:** Supabase → *SQL Editor → New query*. Open `supabase/ALL_IN_ONE.sql`, copy everything, paste, press **Run** (once). It creates all tables, security rules, storage buckets and the reminder job. (Same content as migrations 001–011 if you prefer running them one by one.)
5. **Turn OFF email confirmation:** *Authentication → Sign In / Providers → Email → "Confirm email" = OFF* and Save. (Required: schools and staff get their login instantly, with no email service.)
6. **Create the first Super Admin:** *Authentication → Users → Add user* (tick *Auto Confirm User*). Then in SQL Editor run:
   ```sql
   update public.user_profiles set is_super_admin = true where email = 'YOUR_EMAIL';
   ```
7. **Put the website online** (no command line): drag the whole folder onto https://app.netlify.com/drop (or upload to Cloudflare Pages / GitHub Pages / any hosting). Open the given link → `index.html`.
8. **First use:** sign in as Super Admin → school registers at `register.html` → you click **Approve** → School Owner signs in, creates an **Academic Session**, **Fee Structure**, adds students and staff.

## Reminders
No scheduler is needed: reminders run automatically when any staff member opens the app (throttled to once per 20 min per school). Optionally enable *Database → Extensions → pg_cron* **before** step 4 and an automatic 30-minute job is also created.

## Optional demo data
Run `supabase/seed.sql`, then `select public.seed_demo_school('owner@email','teacher1@email','teacher2@email');` (users must exist). Remove with `select public.remove_demo_school('<school id>');`.

## Tests (optional, developers)
`psql "$SCRATCH_DB" -f supabase/tests/run_tests.sql` — 182 checks. Use a scratch DB, never production.

## Honest notes
- No email/SMS/WhatsApp provider: reminders are in-app notifications.
- The CALL button opens the dialer; a call counts only after the teacher saves the call form.
- The database logic is tested (182/182 on real PostgreSQL). The browser UI has not been run end to end in my build environment, so do a quick smoke test: register → approve → session → student → collect fee → log call.
- Because there is no server-side function, new staff logins are created by the browser (signUp) and then attached by a database function that only accepts accounts created in the last 10 minutes. Anyone can sign up on the Supabase auth endpoint, but such an account has no school access until approved/attached.

## New in this version
- **Delete permanently:** Students → tick students (or open a student) → *Delete permanently* (Owner/Principal only, reason required). Removes the student with class record, fee set-up, calling tasks and call history, so the same admission number can be imported again. Students that have any **fee payment** are never deleted (archive them instead) because payment records are permanent.
- **Archived students:** filter *Status → Archived* in the Students list to see them (they are hidden from the Active list).
- **Shared calling tasks:** Calling CRM → Task Assignment → tick *Same student to every selected teacher*, or use the green “+ person” button on an existing task. Any assigned teacher can call; when one completes the task or the fee is fully paid, it disappears for all of them.
- **Today's Tasks:** filter by search, class, section, call status, priority, deadline and teacher; CALL from the list; tick tasks (or *Select all matching*) and **Transfer / add / remove teachers** in bulk.
- **Task Assignment → Calling tasks:** the people button changes who has a task (several teachers can hold the same task, pick the main teacher, remove any teacher). Tick many tasks for a bulk change.
- **Deadlines:** a task ends at its deadline (e.g. 21 Nov 2026). From the next day it becomes **Expired**, disappears from the teachers' lists and you assign a **new task**: Task Assignment → status *Expired* → **Assign again** (same or other teachers, new deadline), or use the normal Assign flow again. The old task stays in history. Tasks without a deadline never expire.
