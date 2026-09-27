# Dia Windows task-invocation probe

This repository is a narrow, non-destructive runtime probe for the official
Dia Windows Open Beta package `0.28.0.380`.

The workflow verifies the package hashes, installs the exact signed package on
an ephemeral GitHub-hosted Windows runner, launches it without signing in, and
calibrates Windows UI Automation against a small local positive-control window.
It invokes Dia only when UI Automation exposes exactly one enabled, on-screen
button whose accessible name is exactly `New Task`. It does not guess click
coordinates, provision an account, enter credentials, or send a prompt.

The probe also records normal package activation, Win32 menu state, an OS shell
attempt for the packaged internal task URL, and direct Dia command-line handling
of that same URL. Cleanup is limited to the exact package and package/profile
state installed by the workflow.

