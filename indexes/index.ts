// supabase/functions/oasis-assistant/index.ts
// Secure proxy: the browser never sees your Anthropic key — it lives here as a secret.
// The Oasis app calls this with sb.functions.invoke('oasis-assistant', { body: { system, messages } }).

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Swap to a Sonnet model for richer answers (and higher cost), e.g. "claude-sonnet-4-20250514".
const MODEL = "claude-3-5-haiku-latest";

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...cors, "content-type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);

  const key = Deno.env.get("ANTHROPIC_API_KEY");
  if (!key) return json({ error: "ANTHROPIC_API_KEY secret is not set" }, 500);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON" }, 400); }

  const { system, messages, max_tokens } = body || {};
  if (!Array.isArray(messages) || messages.length === 0) {
    return json({ error: "messages[] required" }, 400);
  }

  try {
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": key,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: Math.min(Number(max_tokens) || 1024, 1024),
        system: system || "",
        messages,
      }),
    });
    const data = await r.json();
    if (!r.ok) return json({ error: data?.error?.message || "Anthropic error" }, r.status);
    const text = (data.content || []).map((b: any) => b.text || "").join("").trim();
    return json({ text });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
