# mac-win-bridge Agent Collaboration Rules

## User Role

- The user is the relay between the Mac-side AI and the Windows-side AI.
- Do not make the user approve routine diagnostic designs, implementation details, or test steps.
- Give the user complete, copy-ready handoff messages for the other AI, and continue autonomous work on the local side.
- Ask the user to intervene only when work needs new authority, materially expands scope, risks irreversible data loss, exposes credentials, or requires a product choice that cannot be inferred safely.
- If the user identifies an obvious problem, stop and reassess it before continuing.

## Cross-Platform Coordination

- Mac-side AI owns `mac-controller`; Windows-side AI owns `windows-agent`.
- Coordinate through evidence with matching wall-clock windows, branch/SHA, exact commands, raw logs, and explicit expected report fields.
- When another platform must act, provide a single copy-ready instruction block. Do not send vague requests or make the user translate technical intent.
- During root-cause investigation, keep controlled variables: collect baseline evidence before changing transport, protocol, buffering, dropping, or playback behavior.
- State clearly which files and behaviors must remain unchanged while the other side gathers evidence.
- Do not declare a cross-platform root cause until both sides' time-aligned evidence is available, unless one side has conclusive failure evidence.

## Git Standard

- Use the canonical branch `m1-audio-bridge`.
- Do not create additional branches or worktrees.
- Pull with `git pull --ff-only origin m1-audio-bridge` before new work when the worktree is clean.
- Never reset, discard, overwrite, or stash unknown user changes without first preserving them and reporting the action.
- Commit each completed, independently reversible logical change immediately on the canonical branch.
- Do not accumulate unrelated completed changes in the working tree. Keep each commit focused and give it a descriptive message.
- Pending end-to-end or live validation is not a reason to delay a local commit unless the user explicitly says not to commit locally.
- Treat commit, validation, and push as separate checkpoints. If later validation finds a problem, fix it in a follow-up commit or explicitly revert it; do not silently rewrite published history.
- Do not push diagnostic-only instrumentation unless the task explicitly requires it or both sides need the same committed code.

## Current Audio Implementation Boundary

- Keep the TCP latest-frame input buffer at capacity one and the playback queue limiter at capacity two unless new evidence explicitly requires a change.
- Reblock Windows 480-frame PCM input into 512-frame CoreAudio playback buffers without changing the protocol, TCP `NoDelay`, or Windows write behavior.
- Preserve five-second wall-clock diagnostics and sample-frame accounting for cross-platform validation.
