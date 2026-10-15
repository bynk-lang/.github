# Bynk

**Bynk** is a programming language for building services, compiled to
Cloudflare Workers. This organisation holds the tooling around it, the
projects written in it, and the infrastructure that keeps them honest across
releases.

- **Website:** [bynk-lang.org](https://bynk-lang.org)
- **The Bynk Book:** [bynk-lang.org/book](https://bynk-lang.org/book/)
- **Compiler and toolchain:** [`accuser/bynk`](https://github.com/accuser/bynk)

## Use Bynk in GitHub Actions

| Repository | What it does |
| ---------- | ------------ |
| [`setup-bynk`](https://github.com/bynk-lang/setup-bynk) | Install the toolchain (`bynkc`, `bynk`, `bynkc-lsp`) on a runner. |
| [`bynk-ci`](https://github.com/bynk-lang/bynk-ci) | The standard quality gate (format, type check, tests) in one step. |
| [`bynk-deploy`](https://github.com/bynk-lang/bynk-deploy) | Compile a project and deploy the generated Worker(s) to Cloudflare. |

Starter workflows for all three are offered under **Actions → New workflow**
in every repository in the org; they live in
[`.github`](https://github.com/bynk-lang/.github).

## Bynk in practice

| Repository | What it is |
| ---------- | ---------- |
| [`examples`](https://github.com/bynk-lang/examples) | The org's Bynk projects, and which Bynk releases each passes with. |
| [`status`](https://github.com/bynk-lang/status) | Status of the org's live Bynk services, checked every five minutes. |
| [`architecture-that-compiles`](https://github.com/bynk-lang/architecture-that-compiles) | Source of a narrative book on the problems Bynk addresses and the choices it makes. |

## Compatibility

An [org-wide canary](https://github.com/bynk-lang/.github/blob/main/canary/README.md)
re-runs the checks of every enrolled repository against each new Bynk release
and opens an issue in any it breaks. Results are on the
[compat board](https://github.com/bynk-lang/compat-board).
