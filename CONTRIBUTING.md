# Contributing to Bynk

Thanks for helping. This is the default guide for repositories in the
`bynk-lang` organisation; a repository with its own `CONTRIBUTING.md` follows
that instead.

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). To report
a security issue, follow [SECURITY.md](SECURITY.md), not the issue tracker.

## Where changes go

| You want to change | Go to |
| ------------------ | ----- |
| The language, compiler, standard library, language server, formatter or VS Code extension | [`bynk-lang/bynk`](https://github.com/bynk-lang/bynk). Language changes start as an [increment proposal](https://github.com/bynk-lang/bynk/blob/main/design/proposals/README.md), not a PR. |
| A GitHub Action (`setup-bynk`, `bynk-ci`, `bynk-deploy`, `bynk-dev`) | That action's repository. |
| Example apps, the playground, the registry, the books | That repository. |

## Before you start

- **Small fixes** (typos, docs, clear bugs): open a pull request directly.
- **Anything larger:** open an issue first so we can agree on the shape before
  you spend time on it.
- Search existing issues and pull requests to avoid duplicates.

## Pull requests

1. Fork the repository and branch from the default branch.
2. Keep the change focused; one concern per pull request.
3. Make sure the repository's CI passes. Run its checks locally where the README
   says how.
4. Update docs and tests alongside the code.
5. Open the pull request as a **draft** while it is in progress and mark it
   ready for review when it is done. Fill in the pull request template.

Commit messages should say what changed and why, in the imperative mood.

## Changes to a GitHub Action

`setup-bynk`, `bynk-ci`, `bynk-deploy` and `bynk-dev` share a layout: `action.yml`
at the root, a `Test` workflow (`.github/workflows/test.yml`) that runs the
action against the fixtures under `test/`, and a `BYNK_VERSION` file naming the
Bynk release those tests run with.

- Push and pull request runs use `BYNK_VERSION`, so a red build means your change
  broke something, not that a new Bynk release came out. Do not edit that file by
  hand; the org canary proposes moving it once a newer release passes.
- To try another release, run the `Test` workflow manually (`workflow_dispatch`)
  and give it a `version`.
- Add or adjust a fixture under `test/` for the behaviour you change.
- Consumers pin a major tag (for example `@v1`), so renaming or removing an input
  or output is a breaking change. Say so in the pull request.

## Licence

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion is licensed under the same terms as the repository (typically
Apache-2.0 OR MIT, as stated in its `LICENSE-*` files), without additional
terms or conditions.
