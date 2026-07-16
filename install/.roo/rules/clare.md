# CLARE — Roo/Zoo Code Instructions

This project uses CLARE. Roo Code and its maintained successor Zoo Code load
the root `AGENTS.md` automatically; treat that file as the complete CLARE agent
configuration and follow it in every mode.

Before changing files, read `clare/autonomy.yml` and `clare/principles.md`.
After any turn that changes files, run `./clare/verify-ci.sh` using the exact
terminating procedure in `AGENTS.md`.

## CLARE2 lifecycle capture

Roo/Zoo Code does not currently expose repository-level lifecycle hooks
equivalent to `.github/hooks/*.json`. Until that upstream capability exists,
emit the equivalent fail-open capture events from the agent workflow:

- At the first actionable turn, pipe a minimal JSON object containing the task
  identifier to `./clare/scripts/clare2-capture-event.sh zoo session_start`.
- Before acting on a user request, pipe a minimal JSON object containing the
  user-visible prompt to the same script with `zoo user_prompt`.
- After a tool finishes, emit `zoo tool_result` with only the tool name and
  success/failure status; never include arguments or raw output.
- Before the final response, emit `zoo assistant_stop` with the user-visible
  response only.

Capture is fail-open: if the script or corpus is unavailable, continue normal
agent work. Never capture secrets, hidden reasoning, environment dumps, raw
tool arguments/output, or complete source files.
