// 면허 인증 — 지금은 MOCK. 실제 카카오/PASS 간편인증 + 보건복지부 면허조회 API 키가
// 생기면 verifyWithGovernment()만 실제 호출로 바꾸면 된다.
// 주민번호/면허번호는 이 함수 밖(간편인증 단계)에서만 쓰이고 여기로는 넘어오지 않는 전제.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: userRes, error: userErr } = await admin.auth.getUser(jwt);
  if (userErr || !userRes.user) {
    return json({ error: "로그인이 필요해요." }, 401);
  }
  const userId = userRes.user.id;

  const body = await req.json().catch(() => ({}));
  const licenseType = body.license_type;
  if (licenseType !== "RN" && licenseType !== "SN") {
    return json({ error: "license_type은 RN 또는 SN이어야 해요." }, 400);
  }

  const existing = await admin
    .from("license_verifications")
    .select("licensed")
    .eq("user_id", userId)
    .maybeSingle();
  if (existing.data) {
    return json({ licensed: existing.data.licensed });
  }

  const licensed = await verifyWithGovernment(licenseType);
  const licenseHash = await sha256(userId + ":" + licenseType);

  const { error: insertErr } = await admin.from("license_verifications").insert({
    user_id: userId,
    license_type: licenseType,
    licensed,
    license_hash: licenseHash,
    verification_method: "mock",
  });
  if (insertErr) {
    return json({ error: insertErr.message }, 500);
  }

  return json({ licensed });
});

// TODO: 간편인증(카카오/PASS) 결과를 받아 보건복지부 면허조회 API로 교체.
// 지금은 항상 통과시키는 mock.
async function verifyWithGovernment(_licenseType: string): Promise<boolean> {
  return true;
}

async function sha256(input: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
