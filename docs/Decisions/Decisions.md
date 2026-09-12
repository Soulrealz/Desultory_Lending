# Decisions

**These notes are kept current.** Architecture Decision Records, numbered in the
order they were accepted.

An accepted ADR is **never edited to reflect a changed mind.** It is superseded by
a new ADR that links back to it. The record of what was believed, and when, is the
point — a decision log that gets rewritten is just the current state of things,
which is what [[Protocol]] is for.

## Status values

- `proposed` — under discussion, not yet binding
- `accepted` — binding; the codebase should reflect this
- `superseded` — replaced; frontmatter carries `superseded-by` pointing at the replacement

## Records

- [[0001-nft-as-position]] — the Position NFT is the source of truth for position ownership
- [[0002-internal-consistency-invariants]] — fuzz for internal consistency, not economic solvency
