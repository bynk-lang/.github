# Security Policy

This is the default security policy for repositories in the `bynk-lang`
organisation. A repository with its own `SECURITY.md` (for example
[`bynk`](https://github.com/bynk-lang/bynk/blob/main/SECURITY.md)) follows that
instead.

## Supported versions

Bynk is pre-1.0 and ships from a single moving release line: only the **latest
released version** of each project receives security fixes. If you are affected
by a security issue, upgrade to the most recent release first.

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues,
pull requests, or discussions.**

1. Go to the **Security** tab of the affected repository and click **Report a
   vulnerability**. This opens a private channel visible only to the
   maintainers.
2. If that option is not available, email <hello@bynk-lang.dev> with the
   repository name and as much detail as you can. Please do not include
   exploit details in a public issue asking for contact.

Please include, where possible:

- The affected repository and version.
- A description of the issue and its impact.
- Steps to reproduce, or a proof-of-concept.
- Any known mitigations or workarounds.

## Our commitment

- We will acknowledge your report within a reasonable timeframe.
- We will keep you informed as we investigate and work on a fix.
- We will credit you in the advisory once a fix is released, unless you ask to
  remain anonymous.

Vulnerabilities in the compiler, the emitted Workers artifacts, the language
server, and the editor extension belong to
[`bynk-lang/bynk`](https://github.com/bynk-lang/bynk); report those there.
