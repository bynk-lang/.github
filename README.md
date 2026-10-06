# bynk-lang/.github

Organisation-level defaults for the `bynk-lang` org, including **starter
workflows** offered to every repository under Actions → New workflow.

> Push this directory to a repository named exactly **`.github`** under the
> `bynk-lang` organisation. The `workflow-templates/` folder must sit at the
> repository root.

## Starter workflows

| Template | Uses | What it does |
| -------- | ---- | ------------ |
| **Bynk CI** ([`bynk-ci.yml`](workflow-templates/bynk-ci.yml)) | `bynk-lang/bynk-ci@v1` | Format check, type check, and tests on push/PR, with inline diagnostics. The format check on a directory `source` needs Bynk 0.307.0 or later. |
| **Deploy Bynk to Cloudflare** ([`bynk-deploy.yml`](workflow-templates/bynk-deploy.yml)) | `bynk-lang/bynk-deploy@v2` | Compile and deploy the generated Worker(s) with wrangler. |
| **Bynk canary** ([`bynk-canary.yml`](workflow-templates/bynk-canary.yml)) | `bynk-lang/.github/.github/workflows/canary.yml@v1` | Re-run the repository's checks against each new Bynk release, on dispatch from the org canary. |

Each template pairs a workflow `.yml` with a `.properties.json` (the name,
description, icon, and the file patterns that make GitHub recommend it for Bynk
repositories). The `$default-branch` placeholder is filled in by GitHub when a
user adds the workflow.

The deploy template requires two secrets in the consuming repository or org:
`CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`.

## Canary

The org-wide canary re-runs the checks of every enrolled example and action
repository against new Bynk releases, and opens an issue in any it breaks. How
it works, how to enrol a repository, and how to run it by hand:
[`canary/README.md`](canary/README.md).

## See also

- [`setup-bynk`](https://github.com/bynk-lang/setup-bynk) — install the toolchain
- [`bynk-ci`](https://github.com/bynk-lang/bynk-ci) — the CI quality gate
- [`bynk-deploy`](https://github.com/bynk-lang/bynk-deploy) — deploy to Cloudflare
