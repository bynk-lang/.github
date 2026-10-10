# Canary result reporting

The contract between the canary ([`canary.yml`](../.github/workflows/canary.yml),
via [`scripts/report.sh`](scripts/report.sh)) and the compat board that collects
its results. It is the specification for the compat board's `POST /v2/runs`.

A canary run sends one whenever `canary.yml`'s `report` input is on (the
default) and the caller grants `id-token: write`; otherwise it skips reporting
silently.

## Request

One request per canary run, sent from the result job after the issue step.

```http
POST https://compat-board.accuser.workers.dev/v2/runs
Content-Type: application/json
Authorization: Bearer <the run's GitHub Actions OIDC token>

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

### Authentication

`POST <board-url>/v2/runs`, with the run's GitHub Actions OIDC token:

```http
POST https://compat-board.accuser.workers.dev/v2/runs
Content-Type: application/json
Authorization: Bearer <GitHub Actions OIDC token>
```

- **Minting:** the run mints the token with the board's URL as the
  **audience**. That needs `permissions: id-token: write`, and `report.sh`
  requests it from `ACTIONS_ID_TOKEN_REQUEST_URL`, as `@actions/core`'s
  `getIDToken` does.
- **Verifying:** the board, a Bynk `Oidc` actor, checks the token against
  GitHub's public keys (`https://token.actions.githubusercontent.com/.well-known/jwks`,
  RS256), and checks that `iss` is `https://token.actions.githubusercontent.com`,
  `aud` is its URL, and `exp`/`nbf` are current. No secret is involved.
- **The `sub` claim** must be a **branch run of a bynk-lang repository**:
  `repo:bynk-lang/NAME:ref:refs/heads/BRANCH`, or, for repositories created
  after 15 July 2026, `repo:bynk-lang@295025398/NAME@ID:ref:refs/heads/BRANCH`.
  Any other token, such as another org's or a pull request's (`…:pull_request`),
  gets `401`.
- **The body's `repo`** must be the run's own repository (the `owner/name` in
  `sub`, without the `@ID`s), or the board answers **`403`**. A run can only
  report for itself.


## Response

Any `2xx` is success; the response body is ignored. A transient failure (a
timeout after 30 seconds, a connection error, `408`, `429` or a `5xx`) is
retried twice with the same token and body. Anything else, such as a `401` for
a missing or foreign token, a `403` for another repository's report or a `400`
for a body outside the contract, is not retried.
Either way, a report that still fails is logged as a **warning** on the run. A
failed report never fails the canary.

Because of those retries the receiver can see one run more than once. Treat
`run_url` as the key and keep the first.

## Changing the contract

The payload is versioned by the ref of `canary.yml` that callers use (`@v1`).
Adding a field is compatible; removing or renaming one, or changing the
authentication scheme, needs a new major version of `bynk-lang/.github`.
