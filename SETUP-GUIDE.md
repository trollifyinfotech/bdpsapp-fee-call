# Trollify — Setup Guide (NO Node.js, NO CLI, NO Edge Functions)

> **Already installed an earlier version?** Do NOT re-run `ALL_IN_ONE.sql`. Open the SQL Editor, paste the content of
> `supabase/migrations/010_delete_and_shared_tasks.sql` and Run it **once**, then upload the new website files.
> It adds: permanent delete of wrong-entry students (single / bulk), one student shared with several teachers, and the archived-student import message.

You only need: a free Supabase project, its **Project URL**, its **anon key**, and a way to host static files.

1. **Create a Supabase project** at supabase.com (Region: Mumbai).
2. **Copy** *Project Settings → API*: the Project URL and the anon / publishable key.
3. **Paste them** in `js/supabase-config.js` (the only config file). Never use the service_role key.
4. **Database:** Supabase → *SQL Editor → New query*. Open `supabase/ALL_IN_ONE.sql`, copy everything, paste, press **Run** (once). It creates all tables, security rules, storage buckets and the reminder job. (Same content as migrations 001–010 if you prefer running them one by one.)
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
`psql "$SCRATCH_DB" -f supabase/tests/run_tests.sql` — 153 checks. Use a scratch DB, never production.

## Honest notes
- No email/SMS/WhatsApp provider: reminders are in-app notifications.
- The CALL button opens the dialer; a call counts only after the teacher saves the call form.
- The database logic is tested (153/153 on real PostgreSQL). The browser UI has not been run end to end in my build environment, so do a quick smoke test: register → approve → session → student → collect fee → log call.
- Because there is no server-side function, new staff logins are created by the browser (signUp) and then attached by a database function that only accepts accounts created in the last 10 minutes. Anyone can sign up on the Supabase auth endpoint, but such an account has no school access until approved/attached.

## New in this version
- **Delete permanently:** Students → tick students (or open a student) → *Delete permanently* (Owner/Principal only, reason required). Removes the student with class record, fee set-up, calling tasks and call history, so the same admission number can be imported again. Students that have any **fee payment** are never deleted (archive them instead) because payment records are permanent.
- **Archived students:** filter *Status → Archived* in the Students list to see them (they are hidden from the Active list).
- **Shared calling tasks:** Calling CRM → Task Assignment → tick *Same student to every selected teacher*, or use the green “+ person” button on an existing task. Any assigned teacher can call; when one completes the task or the fee is fully paid, it disappears for all of them.
