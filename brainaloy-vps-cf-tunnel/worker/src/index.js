// Forwards /<provider>/<token>/<path> to the provider's VPC Service binding, so the upstream
// sees the VPS IP. Callers set e.g. KHUDEBARTA_URL=https://<worker-host>/khudebarta/<token>.

// Keep each base URL identical to its services.conf line. The binding pins the IP and port;
// the URL sets the scheme, the Host header and the SNI name.
const PROVIDERS = {
  khudebarta: { binding: "EGRESS_KHUDEBARTA", baseUrl: "http://118.67.213.114:3775" },
};

// Headers that Cloudflare adds on the way in. Do not pass them to the upstream.
const DROP_HEADERS = ["host", "cf-connecting-ip", "cf-ipcountry", "cf-ray", "cf-visitor", "cf-worker", "x-forwarded-for", "x-forwarded-proto", "x-real-ip"];

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const [, provider, token, ...rest] = url.pathname.split("/");
    const target = PROVIDERS[provider];
    if (!target || !env.BRAINALOY_VPS_CF_TUNNEL_TOKEN || !(await tokenMatches(token ?? "", env.BRAINALOY_VPS_CF_TUNNEL_TOKEN))) {
      return new Response("Not found", { status: 404 });
    }

    const headers = new Headers(request.headers);
    for (const name of DROP_HEADERS) headers.delete(name);
    const hasBody = request.method !== "GET" && request.method !== "HEAD";

    try {
      // No retry: an SMS gateway can bill a message before the connection fails.
      return await env[target.binding].fetch(`${target.baseUrl}/${rest.join("/")}${url.search}`, {
        method: request.method,
        headers,
        body: hasBody ? request.body : undefined,
        redirect: "manual",
        signal: AbortSignal.timeout(15_000),
      });
    } catch (error) {
      console.error(`egress ${provider} failed`, error);
      return new Response(`Egress failed: ${error?.message ?? error}`, { status: 502 });
    }
  },
};

// Compares SHA-256 digests with timingSafeEqual, so the length and content of the token do not leak.
async function tokenMatches(given, expected) {
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([given, expected].map((s) => crypto.subtle.digest("SHA-256", enc.encode(s))));
  return crypto.subtle.timingSafeEqual(a, b);
}
