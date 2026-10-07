# Canary result reporting

The contract between the canary ([`canary.yml`](../.github/workflows/canary.yml),
via [`scripts/report.sh`](scripts/report.sh)) and the compat board that collects
its results. It is the specification for the compat board's `POST /runs`.

Nothing receives these reports yet. A canary run sends one only when the calling
workflow passes **both** the `report-url` and `report-key` secrets; otherwise it
skips reporting silently, which is the normal case for now.

## Request

One request per canary run, sent from the result job after the issue step.

```http
POST <report-url>
Content-Type: application/json
X-Timestamp: 1791273600
X-Signature: 5d41402abc4b2a76b9719d911017c592...

{"repo":"bynk-lang/compat-board","kind":"example","bynk_version":"0.303.4","result":"pass","commit":"9aec641c...","run_url":"https://github.com/bynk-lang/compat-board/actions/runs/123","finished_at":"2026-10-06T06:40:00Z"}
```

### Body

A single compact JSON object, UTF-8, with no trailing newline. All seven fields
are always present, and there are no others.

| Field | Type | Meaning |
| --- | --- | --- |
| `repo` | string | The repository that ran the canary, `owner/name` (`github.repository`). |
| `kind` | `"example"` \| `"action"` \| `"book"` | The repository's kind in [`repos.json`](repos.json), as the caller passed it in the `kind` input (default `example`). |
| `bynk_version` | string | The exact Bynk version tested, **without** a leading `v`: `0.303.4`, not `v0.303.4`. Resolved by `setup-bynk` even when `latest` was asked for. If the toolchain could not be installed at all, this is the version that was asked for. |
| `result` | `"pass"` \| `"fail"` | `pass` only if every selected check (bynk-ci, and the bynk-deploy dry run when enabled) succeeded, and the caller's `upstream-result` was `success` or `skipped`. |
| `commit` | string | The 40-character SHA of the commit tested (`github.sha`; the default branch's head for a dispatch). |
| `run_url` | string | The workflow run, `https://github.com/<repo>/actions/runs/<id>`. Unique per run; use it as the idempotency key. |
| `finished_at` | string | When the result was decided, RFC 3339 in UTC with seconds precision: `2026-10-06T06:40:00Z`. |

A cancelled run sends no report.

### Signature

The headers are what a Bynk `Signature` actor with a timestamp verifies:

```bynk
actor Canary {
  auth = Signature(
    secret    = "CANARY_REPORT_KEY",
    header    = "X-Signature",
    timestamp = "X-Timestamp",
    tolerance = 300
  )
}
```

| Header | Value |
| --- | --- |
| `X-Timestamp` | The current time in Unix **seconds**, as a decimal integer string. |
| `X-Signature` | The lowercase hex HMAC-SHA256 (64 characters, no `sha256=` prefix) over the signed string below. |

The signed string is the timestamp header value, a full stop, and then the body
exactly as sent:

```text
<X-Timestamp>.<body>
```

The HMAC key is the UTF-8 bytes of `report-key` as given (it is not hex- or
base64-decoded). The receiver rejects, with `401`, a signature that does not
match, or a timestamp more than 300 seconds either side of its own clock.

In shell, which is what `report.sh` does:

```sh
ts="$(date +%s)"
sig="$( { printf '%s.' "$ts"; cat body.json; } \
  | openssl dgst -sha256 -hmac "$REPORT_KEY" -binary | od -An -v -tx1 | tr -d ' \n')"
curl --data-binary @body.json -H "X-Timestamp: $ts" -H "X-Signature: $sig" ...
```

Where this comes from, in `accuser/bynk` at
[`v0.303.4`](https://github.com/accuser/bynk/tree/455b46de297cef2ecb7e568e346b3d3b21143a0f):

- [`site/src/content/docs/book/guides/actors/verify-webhooks.md`](https://github.com/accuser/bynk/blob/455b46de297cef2ecb7e568e346b3d3b21143a0f/site/src/content/docs/book/guides/actors/verify-webhooks.md#L70):
  "Now the signed string is `<timestamp>.<body>`". Without a `timestamp` header
  the signature would be over the body alone; the compat board uses one.
- [`bynk-emit/src/emitter/runtime.ts`, `verifySignatureHmacSha256`](https://github.com/accuser/bynk/blob/455b46de297cef2ecb7e568e346b3d3b21143a0f/bynk-emit/src/emitter/runtime.ts#L1542-L1582),
  the code the compiler emits the check against:
  - the signing string is `` `${timestamp}.${body}` ``, with the timestamp header
    value verbatim ([L1560](https://github.com/accuser/bynk/blob/455b46de297cef2ecb7e568e346b3d3b21143a0f/bynk-emit/src/emitter/runtime.ts#L1560));
  - the timestamp must be `Number.isFinite` and within `tolerance` of
    `Math.floor(Date.now() / 1000)`, so seconds, not milliseconds
    ([L1554-L1559](https://github.com/accuser/bynk/blob/455b46de297cef2ecb7e568e346b3d3b21143a0f/bynk-emit/src/emitter/runtime.ts#L1554-L1559));
  - the key and the signing string are both `TextEncoder` (UTF-8) encoded;
  - the header is hex, either bare or with a `sha256=` prefix, in either case
    ([`__bynkHexToBytes`, L1532](https://github.com/accuser/bynk/blob/455b46de297cef2ecb7e568e346b3d3b21143a0f/bynk-emit/src/emitter/runtime.ts#L1532-L1540)).
- [`bynk-emit/src/emitter/workers_entry.rs`](https://github.com/accuser/bynk/blob/455b46de297cef2ecb7e568e346b3d3b21143a0f/bynk-emit/src/emitter/workers_entry.rs#L1931):
  the body is read once with `request.text()` and that string is both verified
  and parsed. So the body must be valid UTF-8, without a byte-order mark.
- [`examples/webhook-relay`](https://github.com/accuser/bynk/tree/455b46de297cef2ecb7e568e346b3d3b21143a0f/examples/webhook-relay)
  uses the same `Signature(secret, header = "X-Signature", timestamp = "X-Timestamp", tolerance = 300)` actor.

[`test/verify-signature.mjs`](test/verify-signature.mjs) re-implements that
verifier, and the unit tests run it against `report.sh`'s real output.

## Response

Any `2xx` is success; the response body is ignored. A transient failure (a
timeout after 30 seconds, a connection error, `408`, `429` or a `5xx`) is
retried twice with the same timestamp and body. Anything else, such as a `401`
for a bad signature or a `400` for a body outside the contract, is not retried.
Either way, a report that still fails is logged as a **warning** on the run. A
failed report never fails the canary.

Because of those retries the receiver can see one run more than once. Treat
`run_url` as the key and keep the first.

## Changing the contract

The payload is versioned by the ref of `canary.yml` that callers use (`@v1`).
Adding a field is compatible; removing or renaming one, or changing the
signature scheme, needs a new major version of `bynk-lang/.github`.
