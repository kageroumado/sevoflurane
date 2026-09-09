---
name: A game does not run, or runs badly
about: A game fails to launch, crashes, draws wrong, stutters, or its window, mouse or controller misbehave.
title: "<game name>: "
labels: game
assignees: kageroumado
---

## The game

- **Name and Steam app id**: <!-- the number in the store URL, e.g. 620980 -->
- **What happens**: <!-- does not launch / crashes at ... / black screen / wrong colors / slow / mouse or controller -->
- **How far it gets**: <!-- launcher, menu, loading, in game -->

## Settings

- **Engine**: <!-- Settings › Engine, e.g. Dormison r3 or CrossOver 26.3 -->
- **Renderer**: <!-- Settings › Graphics, e.g. D3DMetal 4.0 beta 2, DXMT 0.80, DXVK -->
- **Per-game settings**: <!-- Settings › Games: window mode, upscaler, mouse; or "defaults" -->
- **Does it run under CrossOver's own Steam, or on Windows?** <!-- if you know -->

## Environment

- **Sevoflurane**: <!-- Settings › About -->
- **macOS**: <!-- e.g. 26.1 -->
- **Mac**: <!-- e.g. Mac Studio M2 Ultra, 64 GB -->

## Diagnostics

Attach the report zip: **Settings › About › Save Diagnostics…**, or in a
terminal, `sevo diag`. The Wine log already carries the errors and exceptions
from the game's process, and the report carries Steam's own record of the
launch, including the exit code, so reproducing once is enough. If the game
never starts at all, turn on **Settings › Engine › Log every library a game
loads**, reproduce, then save the report — it then names the library it could
not resolve. [PLAYTESTING.md](../../PLAYTESTING.md) has the full list,
including where Unity and Unreal games keep their logs.

## Access to the game

A game problem is fixed by running the game. If I do not own it, I will ask in
this issue for access: a gift copy through Steam, or a donation that covers
it. Without that, the issue stays open with whatever the logs show, and anyone
who owns the game can pick it up.
