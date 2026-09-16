# brainaloy-vps-cf-tunnel

A Cloudflare Tunnel connector on the VPS that gives Cloudflare Workers a fixed egress IP. Many Bangladeshi SMS gateways, Khudebarta among them, accept API calls only from allow-listed IPs. A deployed Worker sends from shared Cloudflare IPs that change, and a dev machine sends from rotating ISP IPs. With this stack, a Worker sends the request through a [Workers VPC](https://developers.cloudflare.com/workers-vpc/) binding, `cloudflared` on the VPS opens the upstream connection, and the gateway sees the VPS IP.

There is no relay service to maintain. The stack is one `cloudflared` container, a list of upstreams in `services.conf`, and a script that syncs that list to Cloudflare.

```
Worker ──env.EGRESS_KHUDEBARTA.fetch()──▶ Cloudflare ──tunnel──▶ cloudflared (VPS 139.99.90.200) ──▶ gateway
```

## Files

| File | Purpose |
|---|---|
| `compose.yml` | The `cloudflared` stack for Dokploy. Two connectors, outbound only, read-only filesystem, no capabilities. |
| `services.conf` | One line per upstream: a VPC Service name and a base URL. |
| `services.sh` | Creates or updates the VPC Services from `services.conf`, and prints the Worker bindings. |

## Evidence

A throwaway test Worker checked this design on 2026-09-16 with wrangler 4.132.0 and cloudflared 2026.9.1. The test kit was deleted after the checks passed.

| Check | Result |
|---|---|
| Egress IP through the binding | `139.99.90.200`, from `wrangler dev` and from a deployed Worker |
| Fixed upstream | A request for another host through the httpbin binding failed with a certificate hostname mismatch |
| `redirect: "manual"` | The binding returns the raw 302 |
| Khudebarta send over `http://118.67.213.114:3775` | `Status 0`, SMS received |
| Time added | 125 to 318 ms deployed, about 1.2 s from `wrangler dev` |
| Tunnel stopped | The call fails in 20 ms with `destination_unavailable` |

Workers VPC was in beta on that date. Features and APIs can change before general availability.

## Deploy

### 1. Create the tunnel

1. Open `https://dash.cloudflare.com/?to=/:account/workers/vpc/tunnels`.
2. Create a tunnel, or reuse `brainaloy-vps-egress` from the test.
3. Copy the tunnel ID.
4. Copy the token: only the `eyJ...` string, not the install command around it.

Your Cloudflare user needs the "Connectivity Directory Admin" role to create services, or "Connectivity Directory Bind" to only bind them.

### 2. Run the connector in Dokploy

1. Create a Compose app on the VPS, and paste `compose.yml`.
2. In the environment tab, set `TUNNEL_TOKEN=eyJ...` with no quotes and no spaces.
3. Add no domain and no port.
4. Deploy the app.
5. Check the logs for `Registered tunnel connection`.
6. Run `npx wrangler tunnel info <TUNNEL_ID>`, and check that the status is `healthy`.

If the logs show `Provided Tunnel token is not valid`, the value is not a clean token. Set it again and redeploy, because a restart does not load new environment values.

### 3. Create the VPC Services

1. Run `npx wrangler login`.
2. Put `TUNNEL_ID=<uuid>` in `brainaloy-vps-cf-tunnel/.env`. The file is git-ignored.
3. Run `./services.sh apply`.
4. Run `./services.sh bindings`, and copy the output.

`services.sh` finds a service by name. It creates a missing service and updates an existing one to match `services.conf`. It never deletes a service.

### 4. Add the IP to the provider

Add the VPS public IPv4 address to the provider allow-list. For Khudebarta, use the portal.

## Use it from a Worker

Add the bindings to the Worker's `wrangler.jsonc`. For unishopr-reborn, this is `apps/api/wrangler.jsonc`:

```jsonc
"vpc_services": [
  { "binding": "EGRESS_KHUDEBARTA", "service_id": "<id from ./services.sh bindings>", "remote": true }
]
```

`"remote": true` makes `wrangler dev` use the real binding, so local development also sends from the VPS IP. Add the entry to every named environment, because `vpc_services` is not inherited.

In the provider, call the binding in place of the global `fetch`. Keep the base URL identical to the `services.conf` line:

```ts
// The binding sets the destination IP and port. The URL sets the scheme, the path, the Host header
// and, for https, the SNI name.
const send = env.EGRESS_KHUDEBARTA ? env.EGRESS_KHUDEBARTA.fetch.bind(env.EGRESS_KHUDEBARTA) : fetch;
const response = await send(`${baseUrl}/sendtext`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify(payload),
  redirect: "manual",
  signal: AbortSignal.timeout(15_000),
});
```

Rules for the provider:

- Treat `destination_unavailable` as "tunnel down". A deployed Worker gets it as a thrown error. `wrangler dev` returns it as an HTTP 500 with the body `ProxyError: destination_unavailable`. Do not retry an SMS send, because the gateway can bill a message before a connection fails.
- A plain Worker `fetch()` drops a custom port from an `http` URL. Through the binding, the port comes from the VPC Service, so `http://118.67.213.114:3775` works.
- Keep `KHUDEBARTA_API_URL` in `.dev.vars` and in `wrangler secret put` identical to `services.conf`.

## Add a provider

1. Add a line to `services.conf`, in the form `egress-<provider> <base-url>`, for example `egress-acme https://api.acme-sms.example`.
2. Run `./services.sh apply`.
3. Run `./services.sh bindings`, and add the new entry to the Worker config.
4. Add the VPS IP to the provider allow-list.
5. Deploy the Worker.

The binding name comes from the service name: `egress-acme` becomes `EGRESS_ACME`.

## Security

- **No public ingress.** The VPS opens no port for this stack. Only a Worker in your account with the binding can send through it.
- **Fixed destination.** Each VPC Service allows one host and one port. A Worker cannot use the binding to reach another IP. This is the upstream allow-list.
- **Shared CDN hosts.** The binding fixes the destination IP, not the site. If an upstream sits on a shared edge such as Cloudflare, the URL host can select another site on the same edge. The test showed this with `api.ipify.org` and `example.com`. Prefer upstreams with their own IP or hostname.
- **Clear text on `http` upstreams.** The tunnel encrypts the path from Cloudflare to the VPS. From the VPS to an `http` gateway, the API key, the secret, the phone number and the message travel in clear text. Ask each provider for HTTPS, and switch the `services.conf` line when it exists.
- **Reach of the connector.** A VPC Service can target any address that the VPS can reach, including host ports and the tailnet. The compose file puts `cloudflared` on its own bridge network, so it cannot reach other stacks by container name. The real control is the Cloudflare role: only give "Connectivity Directory Admin" to people who manage this stack.
- **Credentials stay in the Worker.** The tunnel stores no provider keys. It carries the request as the Worker built it. For an `http` upstream, `cloudflared` and the network after the VPS see the keys in transit.

## Operations

| Task | How |
|---|---|
| Check the tunnel | `npx wrangler tunnel info <TUNNEL_ID>` shows `healthy`. The Dokploy logs show registered connections. |
| Check a service | `./services.sh list`, or `npx wrangler vpc service get <id>` |
| Prove the egress IP | Add `egress-ipify https://api.ipify.org` to `services.conf`, run `./services.sh apply`, bind it to a Worker, and fetch `https://api.ipify.org/?format=json` through the binding. The answer must be the VPS IP. Remove the line and the service after the check. |
| Rotate the token | Get a new token for the tunnel from the Cloudflare dashboard or API, set `TUNNEL_TOKEN` in Dokploy, and redeploy. |
| Upgrade cloudflared | Change the image tag in `compose.yml`, and redeploy. Expect a short gap in egress while Dokploy recreates the containers. |
| Remove a provider | Remove the line and the Worker binding, deploy the Worker, then run `npx wrangler vpc service delete <id>`. |

## Limits and open points

- **One VPS.** If the VPS stops, every call fails fast with `destination_unavailable`. Two replicas protect against a container restart, not a host outage. For failover, run the same tunnel token on a second VPS and add that IP to every allow-list.
- **Beta.** Workers VPC is in beta. Check the [changelog](https://developers.cloudflare.com/changelog/) before a wrangler upgrade.
- **Email.** Most email APIs do not need an allow-list. For one that does, add its HTTPS API to `services.conf`. SMTP through Workers VPC is not tested, and `connect()` over VPC Networks supports plaintext TCP only.
- **Not tested:** the IPv6 path. If the VPS gets IPv6, check which address the provider sees.
