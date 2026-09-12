---
status: current
verified-against: 5db9f71
---

# Liquidations

> **This module is broken. Do not use it, do not build on it, and do not read the
> code as an example of anything.** It was mechanically re-pointed at the current
> storage layout when positions became NFT-keyed, and nothing more. It has no
> tests, deliberately — passing tests would imply a specification, and there
> isn't one.
>
> `status: current` on this note means *the description of the brokenness is
> accurate*, not that the module works.

Rewriting this is Project D, and it is blocked on the cross-chain design
(Project C): liquidating a position whose collateral and debt sit on different
chains is a different engine than the single-chain case, and specifying it before
that is settled means specifying it twice.

## What exists

Two entry points, neither correct:

- `liquidateAssetPosition(position, tokenToRepay, tokenToLiquidate)` — repay one
  debt asset, seize one collateral asset
- `liquidateProportionalPosition(position, tokenToRepay)` — repay one debt asset,
  seize a proportional slice of every collateral asset

Supporting private functions: `settleDebtSeizeCollateral`,
`processCollateralLiquidation`. Parameters `__liquidationPenalty = 10` and
`__liquidationPenaltyProtocol = 3`; accrued protocol take lands in `__profit`.

## The defects

**1. Pays the liquidator in the wrong token.** `settleDebtSeizeCollateral`
transfers `tokenToRepay` using an amount denominated in `tokenToLiquidate`. The
two are different assets with different prices and different decimals. The
liquidator receives an arbitrary quantity of the wrong thing.

**2. Seizure is unbounded by debt size.** It takes 90% of the position's *entire*
balance of that collateral token regardless of how much debt is being repaid.
There is no close factor. A 1-unit debt repayment seizes 90% of the collateral.

**3. The penalty points the wrong way.** It is applied as a haircut on the
liquidator rather than a bonus. Liquidation is a service the protocol needs
performed promptly by strangers; the incentive must be positive or nobody calls it.

**4. Proportional math always rounds to zero.** `processCollateralLiquidation`
computes `valueUSD / totalUSD` in integer arithmetic. That expression is `0`
unless a single asset is 100% of the collateral. `liquidateProportionalPosition`
therefore transfers nothing in every realistic case.

**5. Liquidator intent is inferred from `balanceOf(msg.sender)`.** Holding a token
is not the same as having approved the protocol to spend it. When the balance
check fails, the code falls back to "use protocol funds" — which zeroes the
borrower's debt without anybody having paid it. Depositors silently absorb the
loss. This is the worst of the six.

**6. Neither path accrues first.** Liquidation reads the stored `borrowIndex`
without calling `accrue(token)`, so it evaluates debt as of the last interaction
by anyone. Every other state-changing function accrues at the top. See
[[Accounting]].

**7. No liquidation threshold distinct from LTV.** `isPositionHealthy` compares
debt against the same LTV that caps borrowing, so a position becomes liquidatable
at the exact instant it hits maximum borrow. There is no buffer band. The
README's 0-4.9% / 5% threshold design is unimplemented.

Additionally: the collateral `transfer` is unchecked, and there is no reentrancy
guard on either entry point.

## What a rewrite has to settle

- **Close factor** — what fraction of debt one call may repay
- **Bonus, and who pays it** — collateral discount to the liquidator, and whether
  the protocol takes a cut
- **Health factor with a threshold above LTV** — the buffer band that item 7 lacks
- **Accrual ordering** — accrue before evaluating, like every other entry point
- **Approval-based transfers** — `safeTransferFrom` from the liquidator, never a
  balance sniff, and never a protocol-funded fallback
- **Bad debt** — what happens when collateral is worth less than debt, which the
  current code does not consider at all
- **Cross-chain** — whether the liquidator must be on the collateral's chain, and
  how message latency is handled

## Related

- [[Accounting]] — the debt figures a liquidation must read correctly
- [[Positions]] — the transfer gate that depends on `isPositionHealthy`
- [[2026-06-10-project-assessment]] — the audit that first catalogued these
