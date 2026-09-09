// Oasis Club - Self-service PIN reset by email (Supabase Edge Function).
//
// Two actions, both POSTed as JSON:
//   { action: "request", email }               -> emails a 6-digit code
//   { action: "confirm", email, code, newPin }  -> verifies code, sets new PIN
//
// Secrets required (set with `supabase secrets set ...`):
//   RESEND_API_KEY    - from https://resend.com (free tier)
//   RESET_FROM_EMAIL  - a verified sender, e.g. "Oasis Club <noreply@yourdomain>"
//                       (for quick testing you may use "onboarding@resend.dev")
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.
//
// Deploy:  supabase functions deploy pin-reset
// The function is safe to call with the public anon key from the browser; it
// never trusts the client for identity — only the emailed code proves it.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CODE_TTL_MINUTES = 15;
const MAX_ATTEMPTS = 5;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

async function sha256(text: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function sixDigitCode(): string {
  const n = crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000;
  return n.toString().padStart(6, "0");
}

Deno.serve(async (req: Request) => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
    if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
    const FROM = Deno.env.get("RESET_FROM_EMAIL") || "onboarding@resend.dev";
    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    let body: any;
    try { body = await req.json(); } catch { return json({ error: "Bad request" }, 400); }
    const action = String(body?.action || "");
    const email = String(body?.email || "").trim().toLowerCase();

    // Generic message so we never reveal whether an email is registered.
    const GENERIC = "If that email is registered to a member, a reset code has been sent to it.";

    if (action === "request") {
      if (!email || !email.includes("@")) return json({ ok: true, message: GENERIC });

      // Find the member by their registered email (case-insensitive).
      const { data: members } = await admin
        .from("members").select("id,email,status").ilike("email", email).limit(1);
      const member = members && members[0];

      // Only send to active members; always return the generic message.
      if (member && member.status !== "suspended" && member.status !== "dismissed") {
        const code = sixDigitCode();
        const code_hash = await sha256(code);
        const expires_at = new Date(Date.now() + CODE_TTL_MINUTES * 60_000).toISOString();

        // Invalidate any earlier unused codes for this member, then store the new one.
        await admin.from("pin_reset_codes").update({ used: true }).eq("member_id", member.id).eq("used", false);
        await admin.from("pin_reset_codes").insert({
          member_id: member.id, email, code_hash, expires_at,
        });

        if (RESEND_API_KEY) {
          const html = `
            <div style="font-family:system-ui,Arial,sans-serif;max-width:460px;margin:auto">
              <h2 style="color:#0A4F40">Oasis Club — PIN reset</h2>
              <p>Use this code to set a new PIN. It expires in ${CODE_TTL_MINUTES} minutes and can be used once.</p>
              <p style="font-size:30px;font-weight:700;letter-spacing:8px;color:#0A4F40">${code}</p>
              <p style="color:#666;font-size:13px">If you did not request this, you can ignore this email — your PIN stays unchanged.</p>
            </div>`;
          const r = await fetch("https://api.resend.com/emails", {
            method: "POST",
            headers: { "Authorization": `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
            body: JSON.stringify({
              from: FROM, to: [member.email], subject: "Your Oasis Club PIN reset code", html,
            }),
          });
          if (!r.ok) console.error("Resend error:", await r.text());
        } else {
          console.error("RESEND_API_KEY not set — code was created but not emailed.");
        }
      }
      return json({ ok: true, message: GENERIC });
    }

    if (action === "confirm") {
      const code = String(body?.code || "").trim();
      const newPin = String(body?.newPin || "").trim();
      if (!/^\d{6}$/.test(code)) return json({ error: "Enter the 6-digit code from your email." }, 400);
      if (!/^\d{4}$/.test(newPin)) return json({ error: "Your new PIN must be exactly 4 digits." }, 400);
      if (!email) return json({ error: "Missing email." }, 400);

      const { data: members } = await admin
        .from("members").select("id,email").ilike("email", email).limit(1);
      const member = members && members[0];
      if (!member) return json({ error: "That code is invalid or has expired." }, 400);

      // Latest unused code for this member.
      const { data: rows } = await admin
        .from("pin_reset_codes").select("*")
        .eq("member_id", member.id).eq("used", false)
        .order("created_at", { ascending: false }).limit(1);
      const row = rows && rows[0];
      if (!row) return json({ error: "That code is invalid or has expired." }, 400);
      if (new Date(row.expires_at).getTime() < Date.now()) return json({ error: "That code has expired — request a new one." }, 400);
      if (row.attempts >= MAX_ATTEMPTS) {
        await admin.from("pin_reset_codes").update({ used: true }).eq("id", row.id);
        return json({ error: "Too many attempts — request a new code." }, 400);
      }

      if (row.code_hash !== await sha256(code)) {
        await admin.from("pin_reset_codes").update({ attempts: row.attempts + 1 }).eq("id", row.id);
        return json({ error: "That code is incorrect." }, 400);
      }

      // Ensure the chosen PIN isn't already taken by another member.
      const { data: clash } = await admin
        .from("members").select("id").eq("pin", newPin).neq("id", member.id).limit(1);
      if (clash && clash.length) return json({ error: "That PIN is already in use — please choose a different one." }, 409);

      const { error: upErr } = await admin.from("members").update({ pin: newPin }).eq("id", member.id);
      if (upErr) return json({ error: "Could not update your PIN, please try again." }, 500);

      await admin.from("pin_reset_codes").update({ used: true }).eq("id", row.id);
      return json({ ok: true, message: "Your PIN has been updated. You can now sign in." });
    }

    return json({ error: "Unknown action" }, 400);
});
