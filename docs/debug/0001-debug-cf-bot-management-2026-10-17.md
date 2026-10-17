# Cloudflare Bot Fight Mode failure

## Current result

The cause is confirmed and the fix is applied. Cloudflare rejects `fight_mode: true` when `enable_js` remains false. The script now sends `--enable-js --fight-mode` in one request. It reads both values back after an apply.

The approved isolated request returns HTTP 400 with this response detail:

```json
{
  "errors": [{"code": 10400, "message": "Bad Request"}],
  "messages": [{"code": 10400, "message": "cannot enable Fight_Mode while EnableJS is disabled"}]
}
```

The CLI displays `errors` but omits the useful detail in `messages`. Full response capture reveals the prerequisite. The failed request has `cf-ray: a4c0d20878ba7d0d-DAC`.

The corrected isolated request sends `{"enable_js":true,"fight_mode":true}`. Cloudflare returns HTTP 200 with `success: true` and `cf-ray: a4c0d40c0ed47c0c-DAC`. A separate GET confirms that both settings are true on `gramaloy.com`. The other Bot Management values match the earlier read.

The regression test first fails with the captured prerequisite message. All 13 offline tests pass after the fix. The tests also cover an incorrect verification result and unchanged settings for API or WordPress hosts. Bash syntax, ShellCheck warning checks, and diff checks pass. No production setting is disabled for a proof test.

The live update changes only Bot Fight Mode and its JavaScript prerequisite. The full security setup does not run again. The script, tests, and documentation remain unstaged.

## Initial investigation

Instrumentation plan. The failed operation is identified, but the server rejection cause remains unproven. No production write is necessary for this investigation. No fix is applied.

## Expected and actual behavior

The script should enable Bot Fight Mode when the selected zone has no API or WordPress hosts. The supplied screenshot shows HTTP 400 and Cloudflare error 10400 for zone `65a251f706e71665085d18c2b4bc7337`, which belongs to `gramaloy.com`.

The request comes from `scripts/cf-security-setup.sh:265`. The script pins `cf@1.0.0-beta.12`. This operation follows the rule updates and zone setting updates. The failure exits the zone subshell before the rule verification starts. The script records `FAILED` and does not restore earlier settings. Thus, `FAILED` does not mean that every change fails.

## Evidence

- The saved backup at `cf-backup/gramaloy.com-20261017T162357Z/bot_management.json` contains `fight_mode: false` and `enable_js: false`.
- A live read with the zone ID on 2026-10-17 returns the same Bot Management values. Bot Fight Mode remains off.
- The exact update flags in a CLI dry run produce `PUT /zones/gramaloy.com/bot_management` with `{"fight_mode":true}`. Dry run does not resolve the domain to its zone ID.
- An offline request capture uses the installed CLI and a placeholder token. It intercepts all fetch calls and confirms the real update request contains `{"fight_mode":true}`. It sends no request to Cloudflare.
- The installed CLI SDK passes that body to the PUT request without a body wrapper.
- Cloudflare documents `fight_mode` as an optional boolean in its [update endpoint](https://developers.cloudflare.com/api/resources/bot_management/methods/update/).
- A live read with the domain initially fails because the shell has no account selection. A live read with the screenshot zone ID succeeds. This account selection error does not explain the screenshot, which already contains a resolved zone ID.

The flag parsing hypothesis is excluded. The screenshot does not establish a permission failure, a plan restriction, or a configuration conflict. The live HTTP 400 cannot be reproduced safely without a production write. No on/off proof runs against production.

## Candidate causes and measurements

1. The server rejects a zone configuration constraint. Capture the full error response from the isolated Bot Fight Mode update. Inspect nested `errors` and `error_chain` entries for a field or prerequisite.
2. The server rejects the write because of the active plan or authorization. Compare the full error response with the zone plan and active authentication scopes. A successful GET does not establish write access.
3. The server has a transient failure or an undocumented validation rule. If the response contains only error 10400, retain the UTC request time and `cf-ray` value for Cloudflare support.

These are untested hypotheses. Do not add settings or change authentication until the response supports that change.

## Response capture procedure

Use this procedure on the next intended attempt to enable Bot Fight Mode. The command changes that setting if Cloudflare accepts it. It does not repeat the other zone updates.

1. Create a response capture module.

```sh
cat > /tmp/cf-bot-response.mjs <<'JS'
const originalFetch = globalThis.fetch;
globalThis.fetch = async (input, init) => {
  const response = await originalFetch(input, init);
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  if (new URL(url).pathname.endsWith('/bot_management')) {
    console.error(JSON.stringify({status: response.status, ray: response.headers.get('cf-ray'), response: await response.clone().text()}));
  }
  return response;
};
JS
```

2. Run the isolated update with response capture.

```sh
NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--import=/tmp/cf-bot-response.mjs" pnpm --silent dlx cf@1.0.0-beta.12 bot-management update --zone 65a251f706e71665085d18c2b4bc7337 --fight-mode --quiet
```

3. Record the UTC request time.
4. Keep the status, response body, and `cf-ray` value.
5. Run debugkit again with that evidence.

The module prints no request headers or credentials. An offline fixture confirms that it preserves nested error details and leaves the response readable by the CLI. This procedure does not promise that Cloudflare supplies more detail.

## Baseline and retained files

The working tree and index are clean at the start. HEAD is `22b43f6d8d4c3e0e5bdf3cf9aaa4eb264bd08c4d`. No existing repository file changes during the investigation. The HEAD and index checks pass. The status check differs only by this report.

```text
baseline snapshot: none (no tracked change at start) · probe patches in /private/tmp/cf-security-debug-20261017
```

The scratch directory contains the baseline records and offline capture modules. No probe patches exist because no existing file is edited. This report remains unstaged. No failing test remains because the server rejection is not reproduced locally.

## Checks before approval on 2026-10-17

The user reports the same HTTP 400 after the redirect expression correction. The failed endpoint remains `/bot_management`. This failure is separate from Redirect Rules.

A live zone read confirms the Free Website plan and active status. A live authentication read confirms a valid OAuth token with `bot-management.read` and `bot-management.write`. The [update endpoint](https://developers.cloudflare.com/api/resources/bot_management/methods/update/) requires Bot Management Write. A missing token scope is therefore less likely, but these reads do not prove that the write succeeds.

Automatic approval review rejects the isolated live update because success can enable Bot Fight Mode on the production zone. The update does not run. The assistant requests explicit approval to retry this intended setting change with response capture. No alternative transport runs the rejected update.

The response capture module remains at `/private/tmp/cf-security-debug-20261017/capture-response.mjs`. It records the status, response body, and `cf-ray` value without request headers. The pending operation targets only the requested Bot Fight Mode setting. It does not repeat the security or redirect updates.

No fix for error 10400 is applied during these read-only checks. The full server response remains necessary to identify the rejection cause.
