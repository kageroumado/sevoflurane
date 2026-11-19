# Security

Report a vulnerability privately through GitHub's
[private vulnerability reporting](https://github.com/kageroumado/sevoflurane/security/advisories/new)
rather than in a public issue. Expect an acknowledgement within a week.

In scope: anything that lets a web page, a file the app downloads, or another
account on the Mac run code as you, drive the Steam client, or read its data;
and any way around the engine's signature check. The engine and its manifest
are Ed25519-signed and the app refuses unsigned ones.

Out of scope: what a game does once you run it. Wine is a compatibility layer
with no sandbox. A Windows program in the bottle runs as you and can reach
your files, as a Mac app you launch can. The Steam client's own debugging port
is Chromium's and takes no credential, so on a Mac shared with accounts you do
not trust, they can reach Steam while it runs.
