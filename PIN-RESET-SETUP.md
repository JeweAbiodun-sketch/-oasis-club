# Self-service PIN reset by email — setup runbook

Members can reset their own PIN: **Sign in → "Forgot your PIN?" → enter registered
email → get a 6-digit code by email → set a new PIN.**

Three parts are already built for you:
- `20_pin_reset_setup.sql` — the reset-codes table (locked down)
- `supabase/functions/pin-reset/index.ts` — the Edge Function (sends the code, resets the PIN)
- The client UI in `index.html` (the "Forgot your PIN?" flow)

You need to do the 5 steps below once.

---

## 1. Run the SQL migration
In the **Supabase dashboard → SQL editor**, paste and run the contents of
`20_pin_reset_setup.sql`.

## 2. Get an email sender (Resend — free)
1. Create a free account at **https://resend.com**.
2. **API Keys → Create API Key** → copy it (starts with `re_...`).
3. Sender address:
   - **Quick test:** use `onboarding@resend.dev` as the sender. ⚠️ In test mode
     Resend only delivers to **your own Resend account email**, so you can only
     test the reset with that one address.
   - **For all members:** add and **verify your domain** in Resend (Domains →
     Add), then use a sender like `Oasis Club <noreply@yourdomain.com>`. This is
     required before real members' emails will actually be delivered.

## 3. Deploy the Edge Function
Install the Supabase CLI if needed (https://supabase.com/docs/guides/cli), then:

```bash
supabase login
supabase link --project-ref qowhysikdxlhbntimdgr
supabase secrets set RESEND_API_KEY=re_your_key_here
supabase secrets set RESET_FROM_EMAIL="Oasis Club <onboarding@resend.dev>"
supabase functions deploy pin-reset --no-verify-jwt
```

`--no-verify-jwt` is required (your project uses the new `sb_publishable_...`
key, which isn't a JWT). The function is still safe: it reveals nothing without
the emailed code, and only that code lets anyone change a PIN.

> Prefer the dashboard? **Edge Functions → Create a function → `pin-reset`**,
> paste `supabase/functions/pin-reset/index.ts`, set the two secrets under the
> function's settings, and turn **"Verify JWT" OFF**.

## 4. Deploy the updated app
Publish the updated `index.html` the way you normally deploy. Members will see
**"Forgot your PIN?"** on the sign-in screen.

## 5. Test it
1. Sign-in screen → pick your name → **Forgot your PIN?**
2. Enter your registered email → **Send reset code**.
3. Check your inbox, enter the 6-digit code + a new 4-digit PIN → **Set new PIN**.
4. Sign in with the new PIN.

---

## Notes & limits
- Codes expire in **15 minutes**, are **single-use**, and lock after **5 wrong tries**.
- The "send code" step always shows the same message whether or not the email is
  on file — so it never reveals who is a member.
- A member with **no email on file** (or a wrong one) can't use this — they still
  ask the Secretary. (Currently ~15 of 21 members have an email saved.)
- Honest security note: PINs are stored in plain text and login is checked in the
  browser, so this recovery is as strong as email ownership — good — but the wider
  PIN system stays lightweight. A fully hardened design (server-side hashed PINs +
  server-side login) is a larger, separate project.
