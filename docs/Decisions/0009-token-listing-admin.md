---
status: accepted
date: 2026-09-22
---

# 0009 — Tokens are added, and retired, but never removed

## Status

Accepted.

## Context

The supported-asset set was fixed at deployment. `__tokenInfos` had exactly one writer,
the constructor, and there was no `addToken` at all. The June assessment
([[2026-06-10-project-assessment]]) named this alongside reserve withdrawal as a single
admin gap; [[0005-treasury-withdrawal]] closed the reserve half and said explicitly that
the listing half was still open. This record closes it.

Adding an asset is uninteresting. **Removing one is the whole decision**, because the
obvious implementation of "remove" is silently catastrophic.

## The constraint that decides it

Four functions walk the token list on every health computation:

```solidity
for (uint256 i = 0; i < __supportedTokensCount; i++) {
    address token = __tokenList[i];
    ...
}
```

`weightedCollateralUSD`, `userCollateralValueUSD`, `userBorrowedAmountUSD` and
`userMaxBorrowValueUSD` all have this shape, and `_accrueAll` has it too. A position's
collateral and debt in an asset exist, for the purposes of the health factor, **only
because that asset is still in the list**.

So a removal that shrinks `__tokenList` — or that clears `__tokenInfos[token]`, since
`getValueUSD` reads the feed out of it — does not remove the *exposure*. It removes the
protocol's ability to see the exposure. Both directions are unacceptable and they are
unacceptable at the same time:

- a borrower's debt in the removed asset stops being counted, so an insolvent position
  reads as healthy and can borrow more against collateral it has already spent;
- a lender's collateral in the removed asset stops being counted, so a well-collateralized
  position reads as underwater and is liquidatable at once, by anyone, for a bonus.

There is no ordering of a removal that avoids both. The exposure is only extinguished when
every position holding the asset has unwound, and no admin transaction can know that or
force it.

## Decision

**`addToken` appends. `setTokenRetired` flags. Nothing ever shrinks the list.**

`addToken(TokenConfig)` is owner-gated and appends at `__supportedTokensCount++`, with a
fresh pool at `liquidityIndex == borrowIndex == WAD` and `lastUpdate == block.timestamp`.
Two details are load-bearing rather than incidental:

- It routes through the same private `_listToken` the constructor now uses, so the risk
  parameter validation is shared by construction rather than by two copies agreeing. This
  matters beyond tidiness: `liquidationThreshold <= 100` is quantified over *every listed
  token* by [[0007-dusd-redemption]]'s argument that a redemption cannot push a position
  underwater, and by [[0008-reserve-cut-rounds-up]]'s safety argument. An `addToken` with
  its own validation would be a way to add a token that breaks a proof written about a set
  it was never a member of. This is the same failure mode as [[0008-reserve-cut-rounds-up]]:
  a justification that quietly stops covering the thing it quantifies over.
- The fresh pool must be stamped with the current timestamp. A zero `lastUpdate` would make
  the first `accrue()` charge interest for every second since the Unix epoch.

`setTokenRetired(token, bool)` closes an asset to **new exposure only**, via a `notRetired`
modifier applied to exactly two entry points: `deposit` and `borrow`.

Every unwind and loss-absorption path is deliberately left open — `withdraw`, `repay`,
`repayDUSD`, `liquidate`, `liquidateWithBackstop`, `redeem`, `redeemWithBackstop`,
`releaseBackstop`, `withdrawReserves`, and accrual. That is not an oversight to be tidied
up later. An admin who can block repayment can strand a borrower in a position they are
trying to close; an admin who can block liquidation can protect a position that should be
seized. Retirement is a switch that can only ever make the protocol's exposure smaller.

Retirement is **reversible**. The likeliest reason to retire an asset is a feed that has
gone untrustworthy, which is usually temporary; a one-way switch would convert every such
precaution into a permanent de-listing and buy nothing.

`MAX_SUPPORTED_TOKENS` is 32, enforced in `_listToken` so the constructor and `addToken`
are bounded by the same number. Every health check is O(listed tokens) and liquidation
performs several, so an unbounded list is a griefing vector: an owner could list assets
until liquidating anyone costs more gas than the bonus pays, or exceeds the block limit,
which disables the engine that keeps the protocol solvent.

## Consequences

A retired asset keeps accruing interest, keeps being seizable, and keeps counting in the
health factor, which is exactly right — the debt is real until it is repaid. Utilization on
a retired pool drifts up as borrowers repay and lenders withdraw; nothing rebalances it,
and nothing should.

The list is append-only and capped, so a deployment gets 32 listings over its whole
lifetime, including ones later retired. Retiring an asset does not free its slot. At the
shipped two-asset configuration that is not a practical bound, but it is a real one and a
protocol that churns assets would reach it. Raising the cap is a redeployment.

Nothing here lets an owner change the risk parameters of an already-listed token. That is a
separate decision and is deliberately not taken in this record: repricing `ltvRatio` or
`liquidationThreshold` under live positions makes them liquidatable by administrative
action, which needs its own argument about notice and timelocks.

Two gaps this does not close. The owner is still a plain EOA behind `Ownable` — every
argument above about what an admin *cannot* do is enforced by the modifier placement, not
by governance, which is unimplemented. And `addToken` trusts the feed address it is given;
there is no check that the oracle answers, has the claimed decimals, or is live.

## Alternatives rejected

**A full wind-down path** — force-close positions in the retired asset, then remove it from
the list. Rejected: force-closing is seizure without a health-factor justification, it
needs a price for the asset at exactly the moment its feed is the reason for retiring, and
it hands the owner a power the liquidation engine deliberately gates behind `hf < WAD`. The
cure is worse than the 32-slot cap.

**Swap-and-pop removal from `__tokenList`.** Rejected for the reason in "The constraint
that decides it", and worth naming because it is the natural implementation: it is O(1),
it keeps the list dense, and it silently changes the health factor of every position
holding the asset.

**Retirement blocking repayment as well**, on the theory that retirement should freeze an
asset entirely. Rejected: freezing repayment freezes the debt, not the risk, and the
position keeps accruing interest it is not allowed to pay off.

## Related

- [[0005-treasury-withdrawal]] — the other half of the admin gap this closes
- [[0007-dusd-redemption]] — its safety argument quantifies over every listed token's threshold
- [[0008-reserve-cut-rounds-up]] — the precedent: a justification that stopped covering its own subject
- [[Positions]] — the health computations that walk the list
- [[Accounting]] — `_accrueAll` and the per-pool indexes a new listing starts at WAD
