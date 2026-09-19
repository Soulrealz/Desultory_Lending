---
status: accepted
date: 2026-09-19
---

# 0005 — Token reserves are withdrawable; DUSD reserves are not

## Status

Accepted.

## Context

Protocol revenue accrues to `pool.reserves` from three sources: `RESERVE_FACTOR` (10%) of
borrow interest, `LIQ_PROTOCOL_SHARE` (30%) of every liquidation bonus, and — separately,
into `dusdReserves` — the entire DUSD stability fee, since there are no DUSD depositors to
share it with.

Until now none of it could leave the contract. `Desultory` had exactly three owner-gated
functions, all cross-chain configuration. [[0004-liquidation-engine]] added the third
revenue stream without adding a way out, so the stuck pile was growing faster than before.

This also blocks work. The internal half of the flash-loan backstop — the protocol
covering a liquidation from its own funds when a pool is cash-poor — cannot be specified
while reserves are unaddressable.

## Decision

**`withdrawReserves(token, to, amount)`**, owner-gated, accrues the pool first and then
transfers from `pool.reserves` to a recipient of the owner's choosing.

It carries no liquidity gate. `withdraw()` and `borrow()` need one because they move
deposits while the reserve backing stays fixed, so they must stop at
`getAvailableLiquidity`. A reserve withdrawal lowers the contract's balance and
`pool.reserves` by the same amount, so both sides of the identity
*cash = deposits + reserves − debt* fall together. `property_custodyReconciles` is
therefore preserved by construction rather than by a check — which is the reason this was
safe to add without touching the existing flow limits.

**`dusdReserves` is deliberately excluded.** It is a claim, not a balance. `borrowDUSD`
mints DUSD to the borrower and `repayDUSD` burns it from the payer; the protocol never
custodies any. The stability fee raises what borrowers owe, and they settle it by acquiring
DUSD from circulation and burning it — no tokens ever arrive here. "Withdrawing" that
revenue would mean **minting new DUSD against no new collateral**.

That is a monetary decision, not treasury plumbing. It belongs with the peg, redemption and
supply-cap design (project C2), which does not exist yet. Adding unbacked supply before the
peg mechanism is designed would prejudge it.

## Alternatives considered

**Withdraw to the owner address only, with no `to` parameter.** Rejected: revenue usually
belongs to a treasury contract or multisig that is not the admin key, and forcing a second
hop through the owner's own account is worse for custody, not better.

**Mint DUSD for `dusdReserves` withdrawals.** Rejected as above — it decides part of C2 by
accident.

**A cash guard that reverts with a dedicated error when the balance cannot cover the
withdrawal.** Rejected as redundant: reserves are real cash whenever the pool is solvent,
and where they are not, `safeTransfer` reverts on its own. A second check would imply the
two figures can diverge routinely, which would be its own bug.

**Token add/remove admin in the same change.** Rejected: a real gap, but unrelated to
revenue and with its own design questions (what happens to open positions in a removed
asset). It stays open.

## Consequences

- The owner can now remove real value from the protocol. That is the point, and it makes
  the owner key materially more valuable to an attacker than it was when its only powers
  were cross-chain configuration.
- Depositors are unaffected by construction, as argued above.
- The internal liquidation backstop is unblocked.
- DUSD revenue keeps accumulating with no way out until C2 settles the peg. `dusdReserves`
  remains an honest record of what was charged.
- Token add/remove and reserve withdrawal were named together as one gap in the June
  assessment. Only the second half is closed.

## Related

- [[Accounting]] — the reserve cut and the custody identity
- [[Liquidations]] — the third revenue stream
- [[Cross-Chain]] — the DUSD stability fee and the $1 valuation gap
- [[0004-liquidation-engine]] — the ADR that added the stream without an outlet
