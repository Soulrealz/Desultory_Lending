# Protocol

**These notes are kept current.** Each describes what the protocol actually does
today. If a note's `verified-against` commit is far behind `HEAD`, treat it as
suspect and verify before relying on it.

Every note here carries frontmatter:

```yaml
status: current | stale | draft
verified-against: <commit sha>
```

## Notes

- [[Accounting]] — dual-index model, scaled balances, reserve factor, rounding policy
- [[Interest-Rate-Model]] — the 4-bracket kinked borrow curve
- [[Positions]] — the NFT *is* the position; ownership and transfer gating
- [[Oracles]] — Chainlink wrapper, staleness, decimal normalization
- [[Liquidations]] — **currently broken**; documents the defects, not a working design
- [[Cross-Chain]] — DUSD-only remote borrowing over LayerZero V2, and DUSD debt accounting

Not yet written, pending its design session: governance.
