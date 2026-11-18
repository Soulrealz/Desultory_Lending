# Audit

**These notes are kept current.** Security posture: threat model, invariants,
assessments, and findings.

This zone is where the invariants that the fuzzing harness asserts should be
written down in prose first. An invariant nobody can state in a sentence is an
invariant nobody can review.

## Notes

- [[Threat-Model]] — trust assumptions, what the owner can do, and the attack surface
- [[Known-Issues]] — weaknesses that are known and not fixed, and why
- [[Invariants]] — the twelve properties the fuzzing harness asserts, and why
- [[2026-06-10-project-assessment]] — historical: the June 2026 state-of-the-project audit that the rewrite started from
