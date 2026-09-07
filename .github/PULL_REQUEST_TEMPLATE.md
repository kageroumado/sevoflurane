<!-- Thanks for contributing to Sevoflurane. Fill in what applies; delete the rest. -->

## Summary

<!-- One or two sentences: what this changes, and why. -->

## Related issue(s)

<!-- "Fixes #12" or "Relates to #12". Delete if none. -->

## Changes

-

## How it was tested

<!-- The app drives a real Steam client in a real bottle. Say what you exercised, not only that it builds. -->

- **macOS / Mac**:
- **Engine and renderer**: <!-- Dormison r3 + D3DMetal 4.0b2, CrossOver 26.3, ... -->
- **Checks run**:
  - [ ] `swift build` (the `sevo` CLI)
  - [ ] `xcodebuild -scheme Sevoflurane -destination 'platform=macOS' test`
- **Behavior observed**: <!-- e.g. Steam booted, the friends window adopted, the game launched and its window followed the setting -->

## Risk

<!-- What could this break? The bridge, the supervisor, window adoption and the engine's environment each deserve a sentence when touched. -->

## Checklist

- [ ] Builds and tests pass
- [ ] Comments say what the code does, in the present tense (see CONTRIBUTING)
- [ ] No unrelated changes bundled in

---

## Authorship

<!-- Many PRs here are written with an agent. Record who wrote this one and how; a maintainer reviews an unattended run differently from an attended one. -->

- **Author**: <!-- the human, or the agent's name (e.g. Sora) -->
- **Model**: <!-- the model the agent runs on, e.g. Opus 5 (1M context); leave blank if human-authored -->
- **Session**: <!-- "attended" (a human participated or reviewed live) or "automatic" (unattended agent run) -->
- **Verification**: <!-- what the agent actually ran and observed, or "none beyond the build" -->
