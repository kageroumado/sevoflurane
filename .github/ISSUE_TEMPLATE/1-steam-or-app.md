---
name: Steam or the app misbehaves
about: Steam will not start, hangs, or a window, notification, setting or the menu bar does the wrong thing.
title: ""
labels: bug
assignees: kageroumado
---

## What happened

<!-- One or two sentences. What you did, what you saw, what you expected. -->

## Steps to reproduce

1.
2.
3.

## Environment

- **Sevoflurane**: <!-- Settings › About, e.g. 0.3.1 -->
- **macOS**: <!-- e.g. 26.1 -->
- **Mac**: <!-- e.g. MacBook Pro M3 Max, 36 GB -->
- **Engine**: <!-- Settings › Engine, e.g. Dormison r3 or CrossOver 26.3 -->

## Diagnostics

Attach the report zip: **Settings › About › Save Diagnostics…**, or in a
terminal, `sevo diag`. It holds the app's logs, a `sevo doctor` report, the
engine's identity and the last two days of crash reports from the engine's
processes. It names no account; crash reports carry paths under your home
folder, so your short user name is in them.

If Steam itself is stuck, use `sevo diag --steam-logs`, which adds Steam's
bootstrap, connection and webhelper logs from the bottle.

## Anything else

<!-- A screenshot or a short recording helps for window and layout problems. -->
