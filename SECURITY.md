# Security

Report a vulnerability privately through GitHub's
[private vulnerability reporting](https://github.com/kageroumado/sevoflurane/security/advisories/new)
rather than in a public issue. Expect an acknowledgement within a week.

In scope: anything that lets a web page, a game, or the bottled Steam client
run code as the macOS user outside the bottle, read another app's data, or
tamper with an engine download. The engine and its manifest are Ed25519-signed
and the app refuses unsigned ones; a way around that check counts.
