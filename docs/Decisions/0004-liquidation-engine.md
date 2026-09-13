---
status: accepted
date: 2026-09-12
---

# 0004 — The liquidation engine: single entry point, clamp-and-count

## Status

Accepted.

## Context

The old engine (`liquidateAssetPosition`/`liquidateProportionalPosition`) had seven
documented defects, catalogued in [[Liquidations]]'s History section — most gravely,
liquidator intent was inferred from `balanceOf(msg.sender)`, with a fallback to
protocol funds that silently socialized losses onto depositors. ADR 0002 excluded
liquidation from the fuzzing target surface entirely rather than fuzz known-broken
code. This ADR is the replacement design and the record of what shipped.

## Decision

Seven decisions, each with its reasoning:

1. **Per-token `liquidationThreshold`, distinct from `ltvRatio`.** WETH 75/70, USDC
   90/85. Conflating them meant a position became liquidatable the instant it maxed
   out its borrow capacity, with no buffer band. A position between its LTV cap and
   its liquidation threshold is now deliberately transferable.

2. **50% close factor, rising to 100% below health factor 0.95e18.** A full liquidation
   is only forced once a position is deeply underwater; otherwise a partial fill limits
   how much a single liquidator can take in one call, spreading the opportunity and
   reducing the collateral dumped on-market in one transaction.

3. **Per-token `liquidationBonusBps` (WETH 1000, USDC 500), with the protocol keeping
   30% of the bonus.** The bonus is genuine — extra collateral seized beyond the
   repaid value — not the old engine's inverted penalty-on-liquidator. The protocol's
   cut is booked to `pool.reserves` in the seized token, giving the protocol a share
   of every liquidation without introducing a separate fee path.

4. **One entry point, `liquidate(positionId, debtAsset, collateralAsset,
   repayAmount)`, with `debtAsset` routing.** Passing the DUSD address routes
   repayment to `DUSD.burn`; any other whitelisted token routes to `safeTransferFrom`.
   A single function with one authorization check and one accrual point is easier to
   reason about — and to fuzz — than two entry points with independently maintained
   invariants, which is exactly how defect 1 (wrong-token payout) went unnoticed.

5. **Clamp-and-count for bad debt**, not socialization. Seizure is clamped to the
   minimum of collateral held and `getAvailableLiquidity(collateralAsset)`; if the
   position is left with zero collateral across every asset, whatever debt remains is
   added to `totalBadDebtUSD`, a monotone counter. There is no `liquidityIndex`
   writedown anywhere — haircutting lenders' index would break
   `property_indexesNeverDecrease`. A real loss-allocation policy is out of scope.

6. **Payout in underlying**, not a deposit claim. The liquidator receives
   `safeTransfer`ed collateral tokens directly from the contract's own balance, the
   same asset they could withdraw as a depositor. Simpler for a liquidator bot to
   consume — no secondary claim token to unwrap — at the cost of D2's gap (below).

7. **Pure math split into `src/libraries/LiquidationMath.sol`.** Five `pure`,
   unit-agnostic functions — `healthFactor`, `closeFactorBps`, `seizeFromRepay`,
   `repayFromSeize`, `splitBonus` — unit-testable in isolation. Most of the old
   engine's seven defects lived in exactly this arithmetic; separating it made it
   directly fuzzable (`LiquidationMath.t.sol`, 10 tests) without standing up the whole
   protocol.

## Consequences

- **Liquidation can still be blocked by a cash-poor pool.** No flash-loan funding and
  no protocol-funded fallback exist (D2's gap, deliberately out of scope). If a
  collateral pool is fully lent out, `liquidate()` can revert against a position that
  is genuinely liquidatable.
- **`isPositionHealthy` changed meaning.** It used to mean "has not exceeded LTV
  capacity"; it now means `healthFactor(positionId) >= 1e18`, threshold-weighted. A
  position between its LTV cap and its liquidation threshold is now transferable,
  which it previously was not. `PositionNFT._update`'s transfer gate is the only
  caller, so this is a real behavior change for position trading, not just semantics.
- **Bad debt accumulates without being allocated.** `totalBadDebtUSD` grows and is
  never distributed to reserves or lenders. It is a recognized-loss counter for
  observability, not a mechanism that makes anyone whole.
- **The availability bound was not part of the original design — the fuzzer forced
  it.** `_seizeCollateral` originally decremented `totalScaledDeposits` with no
  liquidity gate, unlike `withdraw`/`borrow`, which both already gate on
  `getAvailableLiquidity`. Medusa failed `property_borrowIndexOutpacesLiquidityIndex`
  after ~98k calls once `liquidate` entered the target surface: `accrue()` grows
  `liquidityIndex` faster than `borrowIndex` whenever `0.9 × totalDebt >
  totalDeposits`, a state only unbounded seizure could reach. The fix folds the same
  `getAvailableLiquidity` bound into the existing seizure clamp and back-solves
  `repayAmount` downward from the tighter cap, exactly as it already did for the
  collateral-held case. This is the **second** real bug this harness has caught, after
  the `accrue()` interest leak that motivated ADR 0002 in the first place — the
  harness is now two-for-two against hand-written, reviewed code.
- **A wei-scale rounding seam remains, deliberately unfixed.** The bound above is
  computed in token units, but `_seizeCollateral` converts with `__toScaledUp`
  (rounds up), so a seizure that exactly saturates the cap can leave a pool's deposits
  1–2 wei below its debt. It cannot trigger the invariant that caught the bug above —
  that needs roughly a 10% deficit — and was parked rather than papered over with an
  unexplained `-1`. See [[Liquidations]]'s Known limitations.

## What this supersedes, and what it does not

[[0002-internal-consistency-invariants]] deferred economic-solvency properties
because nothing could liquidate, and excluded liquidation from the target surface
entirely. That premise is now only half-true:

- **Now assertable**: bad debt is a real, monotone counter (invariant 9), and two new
  properties hold across the liquidation surface — a healthy position is never
  liquidatable (10), and the liquidator is never worse off than what they paid (11).
- **Still not assertable**: protocol-wide economic solvency (collateral USD ≥ debt
  USD). Liquidation can still be blocked by a cash-poor pool (consequence above), so
  the protocol still has no property that guarantees underwater positions get
  resolved — only that loss is recognized once collateral runs out.

0002's core argument — that this harness asserts internal consistency, not economics
— still stands and is not revisited here. ADR 0002's frontmatter now carries
`superseded-by: 0004-liquidation-engine` to point at this record for the solvency
question specifically; its body is unchanged, per the vault's rule that accepted ADRs
are never edited to reflect a changed mind.

## Alternatives considered

- **A global buffer constant instead of per-token thresholds.** Rejected: WETH and
  USDC warrant different buffers (a volatile asset needs more room between LTV and
  seize line than a stablecoin), and the constructor already validates per-token risk
  parameters — a global constant would be less precise for no simplicity gain.
- **A flat 50% close factor**, no escalation. Rejected: leaves a deeply underwater
  position only half-liquidatable per call, requiring multiple transactions to fully
  resolve exactly when speed matters most.
- **Socializing bad debt through a `liquidityIndex` writedown.** Rejected: breaks
  `property_indexesNeverDecrease`, and spreads a specific position's loss across all
  lenders in a token with no policy for how that should be governed. Counting
  without allocating keeps the number honest without inventing a redistribution
  mechanism nobody has designed yet.
- **Paying the liquidator in a deposit claim instead of underlying.** Rejected: adds a
  secondary token a liquidator bot must unwrap before it has spendable value, for no
  benefit over direct settlement — and does not actually solve the cash-poor-pool
  problem, since the claim's redemption would hit the same liquidity limit later.

## Related

- [[Liquidations]] — the engine this ADR documents the design of
- [[Accounting]] — the accrual model the availability bound protects
- [[0002-internal-consistency-invariants]] — the ADR this partially supersedes
