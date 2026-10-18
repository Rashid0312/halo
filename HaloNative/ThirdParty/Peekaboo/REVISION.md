# Peekaboo source revision

- Repository: https://github.com/openclaw/Peekaboo
- Release tag: `v4.0.0`
- Commit: `ed3aaa4738b2b588c226154955609cc439f7613e`
- Selected: 2026-10-18
- License: MIT; see `LICENSE` in this directory.

## Integration notes

The selected revision's `Core/PeekabooCore/Package.swift` exposes `PeekabooAutomation`, but it relies on repository-relative packages and the AXorcist, Tachikoma, Commander, TauTUI, and Swiftdansi submodules. Swift Package Manager cannot consume that nested package directly from the repository URL without preserving the repository layout.

Halo must therefore choose one of these reviewable approaches during the compatibility spike:

1. Vendor a pinned source checkout with all required submodule revisions.
2. Extract the smallest buildable automation package and preserve its licenses and upstream history.
3. Use a separately packaged upstream automation product if OpenClaw publishes one at a later immutable revision.

Do not add an unpinned branch dependency.
