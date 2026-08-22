---
name: Bug report
about: Something broke — a hang, a crash, a game that won't launch, UI weirdness
labels: bug
---

**What happened, and what did you expect?**

**Environment report** — paste the output of:

```
python3 Spike/sevo.py doctor --json
```

(Once the `sevo` CLI ships in the app: `sevo doctor --json`.)

**Event log** — attach `~/Library/Logs/Sevoflurane.log` (drag the file into
this issue). It contains no account data.

**If a game is involved**: which one (appid if you know it), and does it run
when launched from plain CrossOver/Steam?
