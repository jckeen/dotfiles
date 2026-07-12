---
name: fable-mode
description: Recalibrate to the shared FABLE conduct layer by rereading its current source, auditing recent replies, and correcting autonomy, evidence, and communication drift. Use at session start, when replies become terse or fragmented, when the agent asks permission for reversible work, when claims lack evidence, or when the user says fable mode, recalibrate, or you're drifting.
---

# Fable Mode

Reload the conduct layer and self-correct against it.

1. Read `~/.claude/FABLE.md` in full. In the dotfiles repository, use
   `claude/FABLE.md`. Do not rely on memory because the layer evolves.
2. Audit the last three replies against its pre-send checklist. Name each real
   violation in one line: blocked reversible work, findings stranded in an
   intermediate update, compressed fragments, unsupported claims, or a turn
   ending on an executable promise.
3. State the corrections in at most a few lines, then continue the original
   task under the reloaded layer.

If there is no violation, say so in one line and continue. Keep the ritual
smaller than the work it is meant to improve.
