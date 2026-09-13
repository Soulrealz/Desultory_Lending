---
status: current
verified-against: 3b244ca
---

# Invariants

The properties the Chimera harness asserts, in prose. An invariant nobody can state
in a sentence is an invariant nobody can review.

Implementation lives in `onchain/ethereum/test/recon/Properties.sol`. The reasoning
behind this particular set is [[0002-internal-consistency-invariants]].

All eleven are **internal-consistency** properties: they constrain the bookkeeping, not
the economics. Each holds even when the protocol is underwater, which is what allows
the fuzzer to move oracle prices between 0.01× and 100× of their starting value
without generating false alarms.

## The eleven

**1. Scaled balances reconcile.**
For each token, the per-position scaled deposits sum to `pool.totalScaledDeposits`,
and the scaled borrows sum to `pool.totalScaledBorrows`. Exact equality — these are
raw stored integers and nothing rounds during the summation, so any drift at all is a
real bookkeeping bug. This is the one that catches a botched storage migration, which
is the most likely way the cross-chain work breaks accounting silently.

**2. Indexes never decrease.**
`liquidityIndex` and `borrowIndex` are monotonically non-decreasing across every call.
A decrease would mean someone's deposit or debt shrank without a transaction, which
nothing in the design permits.

**3. `borrowIndex` outpaces `liquidityIndex`.**
Both start at `WAD`. Debt can never exceed deposits, and the reserve factor removes
10% from the lender side before the liquidity index grows, so borrow growth strictly
dominates. This is a consequence of the model rather than a restatement of the code,
which is what makes it worth asserting — and it is the property used as the negative
control, because inverting it must fail the moment any interest accrues.

**4. Custody reconciles.**
`balanceOf(desultory) + totalBorrows >= totalDeposits + reserves`. The
solvency-of-custody property, and the one that found the accrual bug. It restates the
identity already written in `getAvailableLiquidity`'s own natspec — *cash on hand is
deposits + reserves − debt* — which is a good sign it is the right property: the
original author knew it should hold.

Note it concerns token custody, not market value, which is why it survives bad debt.

**5. Utilization never exceeds 100%.**
`getUtilization(token) <= 10_000` BPS.

**6. Token conservation.**
`ghostPaidIn == ghostPaidOut + balanceOf(desultory)`, per token, exactly. The ghost
counters are incremented from the amounts actually transferred by the target
functions, so this compares physical custody against the harness's own independent
record. Invariant 4 asks whether the books match the balance; this asks whether the
balance matches what really moved. A function transferring the wrong amount breaks
this and nothing else.

Stated additively rather than as `paidIn - paidOut` because the subtraction would
panic on underflow in exactly the case it exists to catch.

**7. DUSD supply matches authorization.**
`ghostDusdMinted == ghostDusdBurned + dusd.totalSupply()`, exactly. The cross-chain
analogue of invariant 6: the ghost counters record what the harness asked the protocol
to mint and burn, and the token's own supply must agree. The harness is single-chain, so
this constrains the debt accounting rather than the messaging — but it is the same
question a multi-chain deployment has to answer, which is why it is stated this way.

**8. Scaled DUSD debt reconciles.**
Per-position `getScaledDusdDebt` sums to `totalScaledDusdDebt`. Exact equality, for the
same reason as invariant 1: raw stored integers, no rounding in the summation. DUSD debt
lives in its own storage outside `__pools`, so invariant 1 does not cover it.

**9. Bad debt never decreases.**
`totalBadDebtUSD` is a monotone record of recognized loss; nothing in the protocol
decrements it, so the harness's ghost copy must never see it fall.

**10. A healthy position is never liquidatable.**
For every position with `healthFactor >= WAD`, `isPositionHealthy` must be `true`.
Stated this way round rather than as "an unhealthy position must be liquidatable" —
the latter would be a stronger, different claim this harness does not need.

**11. The liquidator is never worse off.**
Checked directly against `LiquidationMath.seizeFromRepay` / `splitBonus` rather than
through a full `liquidate()` call: for a fixed repay amount, the liquidator's share of
the seized collateral (after the protocol's cut) must be worth at least what they paid.
This is deliberately *not* "liquidation improves the health factor" — that claim is
false by design, since seizing collateral plus a bonus removes more value than the debt
it retires, so a deeply underwater position gets worse, not better, with every
liquidation. Asserting it would be asserting a bug that isn't one.

## Deliberately not asserted

**Economic solvency** (collateral USD ≥ debt USD). [[Liquidations]] is now specified and
in the target surface, but a large enough price move can still leave the protocol
genuinely underwater — bad debt is recognized (invariant 9) rather than prevented, so
this remains a property the system does not claim to have.

**Liquidation improves health factor.** Deliberately excluded, not merely deferred: it is
false. See invariant 11.

**Liveness** (a debt-free position can always withdraw in full). Valuable, but needs
try/catch machinery around actor calls. Deferred.

## What this found

`property_custodyReconciles` failed on clean code at ~20k Medusa calls, with a
shortfall of 17,676 wei against pool totals near 5.2e23. Root cause was in `accrue()`;
see [[Accounting]]. Fixed, with `test/recon/AccrualLeak.t.sol` as the regression test.

Two details worth remembering:

- **Echidna at 5k calls did not find it. Medusa at 20k did.** The argument for running
  both engines stopped being theoretical on day one.
- **The first accrual from a pristine `borrowIndex == WAD` cannot leak.** Short or
  simple sequences are structurally incapable of surfacing it, which is why two
  hand-written probes over 3 and 27 simulated years both passed.

**`property_borrowIndexOutpacesLiquidityIndex` failed again once liquidation entered
the target surface** (Medusa, ~98k calls, two independent shrunk counterexamples).
Root cause: `_seizeCollateral` moved `pool.totalScaledDeposits` for the seized
collateral token with no `getAvailableLiquidity`-style bound, unlike `withdraw()` and
`borrow()` — so seizing collateral in a token pool that is also heavily borrowed
elsewhere could push that pool's debt above its deposits, which is the precondition
invariant 3's proof leans on. Echidna's shallower run (reused corpus, ~30k calls) did
not find it, echoing the note above about engine depth.

**Fixed**: `liquidate()`'s existing collateral-held clamp now also bounds
`seizeAmount` by `getAvailableLiquidity(collateralAsset)`, restoring the same
debt-never-exceeds-deposits bound `withdraw()`/`borrow()` already enforce, and
back-solves `repayAmount` from the tighter cap exactly as it already did for the
collateral-held case. Regression test:
`test/Desultory.t.sol:testSeizureIsBoundedByAvailableLiquidity`. See
`.superpowers/sdd/2026-09-12-liquidation-engine/task-7-report.md` for the
investigation, fix, and both engines' re-run results. This is the second real bug
this harness has found in reviewed code, after the accrual leak above — the argument
for running it before the cross-chain work extends the accounting, made in
[[0002-internal-consistency-invariants]], has now paid off twice.

A wei-scale rounding seam was found and deliberately left in place rather than
patched: the availability bound is computed in token units, but `_seizeCollateral`
converts with `__toScaledUp` (rounds up), so a seizure that exactly saturates the cap
can leave a pool's deposits 1–2 wei below its debt. It cannot trigger invariant 3
(which needs roughly a 10% deficit) and is recorded as a known limitation in
[[Liquidations]] rather than fixed with an unexplained `-1`.

## Running them

```
medusa fuzz
echidna . --contract CryticTester --config echidna.yaml
```

Counterexamples replay as Foundry tests via `test/recon/CryticToFoundry.sol`.

## Related

- [[Accounting]] — the accrual math these constrain
- [[Cross-Chain]] — the DUSD debt accounting invariants 7 and 8 constrain
- [[0002-internal-consistency-invariants]] — why this set and not another
- [[Liquidations]] — the surface invariants 9-11 constrain
