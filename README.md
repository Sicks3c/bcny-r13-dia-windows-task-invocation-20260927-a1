# Dia Windows task-invocation probe

This repository is a narrow, non-destructive runtime probe for the official
Dia Windows Open Beta package `0.28.0.380`.

The workflow verifies the package hashes, installs the exact signed package on
an ephemeral GitHub-hosted Windows runner, and calibrates Windows UI Automation
against a small local positive-control window. It invokes Dia only when UI
Automation exposes exactly one enabled, on-screen button whose accessible name
is exactly `New Task`. It never guesses click coordinates and never sends an
agent prompt, RUN, tool action, or approval decision.

Two optional repository secrets can provide an already-owned disposable
mail.tm fixture for the exact work-email onboarding control. Values cross into
UIA through runner-temp private files and are redacted, including base64 forms,
before artifact upload. The evidence run used a fully disposable Dia identity
and mailbox; both were deleted afterward with independent invalidation
readback, and the repository secrets were removed. A run without those secrets
remains an anonymous-only probe.

The probe also records normal package activation, Win32 menu state, an OS shell
attempt for the packaged internal task URL, and direct Dia command-line handling
of that same URL. Cleanup is limited to the exact package and package/profile
state installed by the workflow. External identity deletion is intentionally
performed out of band after the final evidence run so the runner cannot delete
an account before process/pipe observations are collected.
