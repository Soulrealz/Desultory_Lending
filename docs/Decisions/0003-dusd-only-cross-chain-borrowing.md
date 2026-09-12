---
status: accepted
date: 2026-09-12
---

# 0003 — Cross-chain borrowing is DUSD-only, with one home chain per position

## Status

Accepted.

## Context

The protocol should let someone deposit collateral on one chain and receive borrowed
value on another. Every design for this has to answer two questions: *what* can be
borrowed remotely, and *where does the position live*.

The naive answer — let a position borrow any deposited asset onto any chain — requires
the destination chain to already hold that asset. Someone has to have supplied WETH on
Arbitrum before a Base depositor can borrow WETH there. That makes the feature's
usefulness a function of liquidity the protocol does not control, and on a new chain it
is simply unavailable.

The second question is harder. If a single position's collateral can sit on several
chains at once, then no chain can answer "is this position healthy?" without a
round-trip. Health is read on the hot path of `withdraw`, `borrow`, and every NFT
transfer. A liquidator would have to act on a health figure that was true one message
ago, against collateral it cannot see, let alone seize.

## Decision

**Only DUSD is borrowable across chains**, and **every position has exactly one home
chain** — its NFT, its collateral and its debt all live there.

DUSD is protocol-minted, so no destination liquidity has to pre-exist: the mint creates
the tokens where they are wanted. That is what makes the pitch literally true rather
than aspirational — you are not bridging an asset and paying a bridge for it, you are
being issued a fresh liability on the chain you asked for.

Because the position never leaves its home chain, `isPositionHealthy` stays a local
storage read. Nothing about health, LTV, or liquidation becomes asynchronous. This is
the property that unblocks the liquidation rewrite (see [[Liquidations]]): that engine
can be designed as if cross-chain did not exist, because from its point of view it does
not.

**Borrowing sends exactly one message, and its receive path is unconditional.**
`Desultory.borrowDUSDTo` records the debt at home, checks health locally, and asks the
Adapter to authorize a mint on the destination. `Adapter._lzReceive` decodes a
`(recipient, amount)` pair and mints. It contains no pause flag, no allowlist, no supply
cap and no `require` of any kind, and it must never acquire one. The debt is already
recorded on the source chain by the time it runs. LayerZero persists undelivered
messages and retry is permissionless, so a *transient* failure self-heals — but a
*permanent* revert strands the message and leaves a borrower owing DUSD they never
received. Every safety check therefore belongs on the send side, where reverting is free.

**Repaying sends no protocol message at all.** DUSD is an OFT, so a borrower bridges
their own tokens home with the token's own `send()` and calls `repayDUSD` locally. The
protocol does not need to know that a bridge happened; it only sees a local repayment.

**DUSD debt accrues a flat stability fee, not the kinked curve.** `getUtilization` is
`debt / deposits`, and nobody deposits DUSD — utilization would be pinned at zero and
the curve would return the base rate no matter how much DUSD is outstanding. The whole
fee goes to reserves, because there are no DUSD depositors to share it with.

## Alternatives considered

**Borrow any deposited asset remotely.** Rejected: needs destination-side liquidity for
every asset on every chain, which the protocol cannot guarantee and cannot bootstrap.

**Hub-aggregated collateral** — one chain holds the canonical view of every position's
collateral, spokes report into it. Rejected: health checks become asynchronous, the hub
is a liveness single point of failure, and liquidation has to seize collateral it cannot
reach.

**Two-phase commit** — reserve capacity at home, confirm on the destination, release on
failure. Rejected: it buys nothing here. The failure it protects against is a mint that
cannot land, and an unconditional mint has no such failure mode. It costs a second
message and adds a stuck-pending state that needs its own timeout policy.

**Pull-based claim** — message records an entitlement on the destination, the user claims
it in a second transaction. Rejected: strictly worse UX for the same result, and the
claim function is another place that can revert with debt already recorded.

## Consequences

- **The adapter set is the entire trust boundary.** A compromised Adapter on *any*
  configured chain can mint unlimited DUSD, and that DUSD is spendable on *every* chain.
  Peer configuration is security-critical; there is no second line of defence, by design.
- **DUSD is fungible globally but backed per-chain.** A unit minted against collateral on
  chain A is indistinguishable from one minted against collateral on chain B. Backing
  quality is a property of the system as a whole, not of the chain you are holding it on.
- **Health checks assume DUSD trades at $1.** `userBorrowedAmountUSD` adds DUSD debt at
  par. This is an assumption, not a fact, and it holds only while the peg does — and the
  peg mechanism is not designed yet. If DUSD trades above par, debt is understated and
  positions are under-collateralized in real terms. Tracked as project C2; documented in
  [[Cross-Chain]].
- **`Desultory` gained an owner.** Cross-chain needs privileged setters, so the contract
  that previously had no access control at all now has `Ownable` plus three knobs. Token
  add/remove and reserve withdrawal are still ungoverned.
- **Two accrual paths now exist.** `accrue(token)` and `accrueDusd()` share the
  charge-first discipline described in [[Accounting]] but not the code. Both must keep it.

## Related

- [[Cross-Chain]] — what the implementation actually does
- [[Accounting]] — the index model both accrual paths follow
- [[Liquidations]] — the rewrite this decision unblocks
