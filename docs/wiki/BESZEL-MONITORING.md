# Beszel Monitoring over Tailscale

[Beszel](https://beszel.dev/) gives you CPU, memory, disk, network and per-container stats for every VM on the tailnet. Two halves:

- The hub (web UI + database) plus a Tailscale sidecar, from `templates/beszel-hub.compose.yml`. Deploy on one server only.
- The agent, installed as a **host binary under systemd** on every monitored VM. No Docker stack. The install script adds the `beszel` user to the `docker` group, so per-container stats still work.

## Why the sidecar

The hub shares the sidecar's network namespace (`network_mode: service:tailscale`). Port 8090 is then published on the hub's tailnet node, not on the VM's public interface. Nobody outside the tailnet can reach the UI, and you need no Traefik route, no domain and no certificate.

The trade-off: in Dokploy's Domain tab you must target the `tailscale` service, not `beszel`, because `beszel` has no address of its own on the Dokploy network. Section 3 covers that.

The sidecar runs with `--accept-dns=false`. MagicDNS inside a container rewrites the resolver and breaks Docker service name lookups, so keep that flag.

## Agents need no sidecar

Each VM already runs Tailscale on the host, and the agent runs on the host as well. It therefore sees real host metrics and reaches the hub through the `tailscale0` interface. The agent opens an outgoing WebSocket to the hub URL, so the VM needs no open port for monitoring.

## 1. Deploy the hub

1. In the Tailscale admin console, create a **reusable, ephemeral-off auth key**. Tag it if you use ACL tags.
2. Create a Docker Compose service in Dokploy and paste `templates/beszel-hub.compose.yml`.
3. Set the environment variables:

   ```
   TS_AUTHKEY=tskey-auth-...
   TS_HOSTNAME=beszel
   APP_URL=http://beszel:8090
   ```

4. Deploy. Check the sidecar logs for the node's address, or run `tailscale status` on any tailnet machine.
5. Open `http://<tailscale-ip>:8090` from a machine on the tailnet and create the first admin user. Do this immediately: the first visitor owns the hub.

If MagicDNS is on for your tailnet, `http://beszel:8090` works too. `APP_URL` only affects links in alert emails.

## 2. Add each VM

Repeat per VM:

1. In the hub UI, click **Add System**. Enter the name and the VM's Tailscale IP. Copy the **token** and the **public key**.
2. On that VM, as root, run the install script:

   ```bash
   curl -sL https://get.beszel.dev -o /tmp/install-agent.sh
   sh /tmp/install-agent.sh \
     -k "ssh-ed25519 AAAA..." \
     -t "<token from the hub>" \
     -url "http://100.x.y.z:8090" \
     --auto-update true
   ```

   Use the hub's Tailscale IP in `-url`, not its public IP. `--auto-update true` installs a timer that updates the agent daily.
3. The system turns green in the hub within about 30 seconds.

Run the same script on the hub's own VM to monitor it. Its `-url` is still the hub's Tailscale address: the hub lives in the sidecar namespace and is not on the host's `127.0.0.1`.

Flags worth knowing:

| Flag | Meaning |
|---|---|
| `-k` | Public key from **Add System**. Required. |
| `-t` | Token from **Add System**. |
| `-url` | Hub address on the tailnet. |
| `-p` | Listen port. Default 45876. Not needed with `-url`. |
| `-v` | Version to install. Default latest. |
| `--auto-update true\|false` | Daily update timer. Prompts if omitted. |
| `-u` | Uninstall the agent and its unit files. |

## 3. Optional: a custom domain for the hub UI

Skip this unless you need the UI from a device that is not on the tailnet. A public login page is a new attack surface, and the tailnet URL costs nothing to keep.

Traefik reaches a container by its IP on the Dokploy network. The `beszel` service has no such IP: it borrows the sidecar's namespace. So point the domain at the **`tailscale` service**, port **8090**. The hub answers there, and the tailnet route keeps working at the same time.

1. 🖐 DNS: **A record** `status.example.com` → the VPS **public IP**. Leave it DNS-only (grey cloud) until the certificate is issued.
2. 🖐 Dokploy → the Beszel Compose service → **Domains** tab → **Add Domain**.
   - Host: `status.example.com`
   - Service Name: `tailscale`
   - Container Port: `8090`
   - Path: `/`
   - HTTPS: on, Certificate: **Let's Encrypt**
3. 🖐 Save, then **Redeploy** the stack.
4. 🖐 Set `APP_URL=https://status.example.com` in the stack environment and redeploy again, so alert emails link to the public URL.
5. ⛔ `curl -sI https://status.example.com` returns `200` and a valid certificate.
6. ⛔ The tailnet URL `http://<tailscale-ip>:8090` still answers.

If the certificate fails to issue, check that port 80 is open on the VPS and that DNS resolves to the VPS, not to Cloudflare. Cloudflare proxying breaks the HTTP-01 challenge; turn the cloud orange only after the certificate exists.

**Harden it before you leave it public.** Give the admin account a long unique password. Wire an OAuth provider in the hub settings, then set `DISABLE_PASSWORD_AUTH=true`. Beszel's public sign-up closes after the first user, so create that user before the domain goes live.

### If you drop the sidecar instead

You can also run the hub with no Tailscale sidecar and reach it only by domain. Delete the `tailscale` service, its `ts_state` volume and the `depends_on` block, then remove `network_mode: service:tailscale` from `beszel`. Point the domain at service `beszel`, port 8090; Traefik publishes it, so the stack needs no `ports` entry. Every agent then needs `-url https://status.example.com` instead of the tailnet address, and monitoring traffic leaves the tailnet. Reinstall each agent with the new URL before you delete the sidecar.

## Hub variables

| Variable | Default | Meaning |
|---|---|---|
| `TS_AUTHKEY` | — | Tailscale auth key. Required. |
| `TS_HOSTNAME` | `beszel` | Tailnet node name for the hub. |
| `TS_EXTRA_ARGS` | `--accept-dns=false` | Extra `tailscale up` flags. |
| `APP_URL` | `http://beszel:8090` | Base URL used in alert emails. |
| `DISABLE_PASSWORD_AUTH` | `false` | Set `true` after you wire up OAuth. |

Memory, CPU and PID limits follow the same pattern as the WordPress template. See [WORDPRESS-STACK-TUNING](WORDPRESS-STACK-TUNING.md) for the reasoning. The hub uses about 100 MB, each agent about 20 MB.

## Checks

```bash
# On the hub VM
docker compose logs tailscale | tail -20
docker compose exec tailscale tailscale status

# On a monitored VM
systemctl status beszel-agent
journalctl -u beszel-agent -n 30 --no-pager
curl -sI http://100.x.y.z:8090        # hub reachable over the tailnet
```

An agent that logs `connection refused` cannot reach the hub URL. Confirm from the VM shell that `curl` hits the hub, then confirm the Tailscale ACL allows port 8090 from that node.

If per-container stats are missing, the `beszel` user is not in the `docker` group. Run `id beszel`, then `usermod -aG docker beszel && systemctl restart beszel-agent`.
