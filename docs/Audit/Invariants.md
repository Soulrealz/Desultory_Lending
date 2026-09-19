---
status: current
verified-against: 2502b9a
---

# Invariants

The properties the Chimera harness asserts, in prose. An invariant nobody can state
in a sentence is an invariant nobody can review.

Implementation lives in `onchain/ethereum/test/recon/Properties.sol`. The reasoning
behind this particular set is [[0002-internal-consistency-invariants]].

All twelve are **internal-consistency** properties: they constrain the bookkeeping, not
the economics. Each holds even when the protocol is underwater, which is what allows
the fuzzer to move oracle prices between 0.01× and 100× of their starting value
without generating false alarms.

## The twelve

**1. Scaled balances reconcile.**
For each token, the per-position scaled deposits **plus `pool.backstopScaledDeposits`**
sum to `pool.totalScaledDeposits`, and the scaled borrows sum to
`pool.totalScaledBorrows`. Exact equality — these are raw stored integers and nothing
rounds during the summation, so any drift at all is a real bookkeeping bug. This is the
one that catches a botched storage migration, which is the most likely way the
cross-chain work breaks accounting silently.

The backstop term arrived with [[0006-internal-liquidation-backstop]], which gave the
protocol its own deposit line funded out of reserves. Adding it **weakens** invariant 1
as a constraint, and it is worth being precise about that: a free variable on the left of
an equality lets the remaining variables move and still balance, so the equality alone no
longer pins the per-position sums the way it did. It stays exact — there is no tolerance
on the right — but exactness is not the same as strength.

What keeps it honest is that the new term is separately anchored, twice. Upward, by
invariant 12: `backstopScaledDeposits <= totalScaledDeposits`. More importantly **in
value**, by `property_custodyReconciles` (invariant 4): crediting both deposit lines
without debiting `pool.reserves` by the matching amount breaks custody immediately, so
the backstop term cannot be inflated to absorb a discrepancy elsewhere. Invariant 1 then
catches the remaining shape of the slip — a commit or release that credits
`totalScaledDeposits` without crediting `backstopScaledDeposits`, or vice versa.

Note also that invariant 12 is strictly implied by invariant 1 (a sum of non-negative
per-position terms plus the backstop term equals the total, so the backstop term cannot
exceed it). It is cheap redundancy that survives when position enumeration does not, not
independent coverage.

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
Asserted at **both** bonus shares — 3000 (`liquidate`) and 7000
(`liquidateWithBackstop`).

Be clear about what that second share pins, because it is less than it looks. `splitBonus`
caps `protocolCut` at `bonus`, so `toLiquidator >= baseAmount` holds **structurally for
every share from 0 to 10000**; the assertion cannot fail unless that cap is removed or
broken. So this property pins the cap — worth pinning, since removing it would make
liquidations a guaranteed loss and the path would go unused — and it does **not**
demonstrate that the 7000 share is economically viable. It asserts break-even at zero gas,
not profit. Whether 30% of the bonus actually pays a liquidator is an economic argument
made in [[0006-internal-liquidation-backstop]], not something this harness checks.

This is deliberately *not* "liquidation improves the health factor" — that claim is
false by design, since seizing collateral plus a bonus removes more value than the debt
it retires, so a deeply underwater position gets worse, not better, with every
liquidation. Asserting it would be asserting a bug that isn't one.

**12. The backstop never exceeds the pool's deposits.**
Per token, `pool.backstopScaledDeposits <= pool.totalScaledDeposits`. The protocol's own
deposit line is a *subset* of the pool's deposit base, never a parallel figure, and this
states that relation on its own rather than leaving it implied by invariant 1. It catches
the class of slip where a commit or a release moves one line and not the other — which
invariant 1 would also catch, but only while every position in the harness is enumerable;
this one holds regardless.

## The one assertion that is not a property

Redemption is asserted **inside its target functions**, not as a `property_`:

> `dusdBurned >= getValueUSD(collateralAsset, collateralReceivedByRedeemer)`

The redeemer never walks away with more USD of collateral than the DUSD they burned. That
difference **is** the redemption fee, and its sign is the whole economic guarantee: if it
ever inverted, redemption would be a subsidy rather than a floor. It catches a mis-signed
fee, a flipped inverse in `RedemptionMath`, or a back-solve rounding the wrong way.

**It replaced a property that was unsound, and the replacement is the interesting part.**
The design spec asked for "redemption never lowers the target's health factor" — the
obvious statement of decision 2 in [[0007-dusd-redemption]]. Medusa failed it, and the
failure was genuine: `healthFactor` is a function of the indices, and `redeem` calls
`_accrueAll()` internally, so a before/after comparison straddles an accrual boundary and
charges realized stability-fee interest to the redemption that happened to be standing
there. Observed: `hfBefore = 3.0e18`, `hfAfter = 2.99923…e18`. **The property was wrong,
not the code.** The replacement compares two figures produced by the same call, so no
amount of elapsed simulated time can perturb it.

State the residual gap plainly: the new assertion catches the redeemer being **over-paid**.
It does not catch debt being **under-cleared** relative to the collateral removed — a
redemption that took the right collateral and retired too little debt would satisfy it.
That class is covered by `testRedeemImprovesTheTargetHealthFactor` in
`test/Desultory.t.sol` as a unit test, where no time passes between the snapshot and the
call, and by nothing in the fuzzer.

### Two coverage limitations on the redemption surface

Do **not** read the headline fuzzer counts as coverage of redemption.

1. **`desultory_redeemWithBackstop`'s real call fired zero times across 300,000 Medusa
   calls.** Four preconditions must align — the position healthy, holding DUSD debt,
   holding the chosen collateral, and the pool short enough to need the backstop — and the
   last two pull against each other, since a pool that cannot spare collateral is usually
   one where the position is not comfortably healthy in it. The backstopped redemption path
   is covered by its four unit tests in `test/Desultory.t.sol` and **effectively not by the
   fuzzer at all**. The precondition is not relaxable: `healthFactor >= WAD` *is* the
   feature.
2. **`desultory_redeem` fired 14 times at `--test-limit 50000`** (25 at 300,000). Non-zero,
   and thin. A campaign that reports the target as "passing" is reporting mostly that its
   preconditions were not met.

Also worth carrying forward: **lcov line coverage on this harness is unreliable.** It
reported non-zero hits on lines *after* a zero-hit call site, which cannot be true. Counter
instrumentation was used instead. Whoever next reaches for coverage numbers here should not
trust lcov.

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

**`property_borrowIndexOutpacesLiquidityIndex` is failing again, and this time nothing
was fixed.** This is the **third** real defect this harness has caught in reviewed,
merged code, after the accrual leak and the unbounded seizure above — and it is the only
one still open.

It is **confirmed on `master`**, with none of the redemption work present: `master` at
`542f710`, `medusa fuzz --test-limit 120000` → 23 passed, **1 failed**, the same property.
On the redemption branch it reproduces faster (`--test-limit 50000` → 25 passed, 1 failed)
because that branch supplied a richer corpus, not because it introduced anything. Two
independent minimal reproductions contain **zero redemption calls** — only
`desultory_deposit`, `oracle_setPrice`, `desultory_borrow`, `desultory_repay`.

Mechanism, from `accrue()`:

```
liquidityIndex growth = (interest - toReserves) / totalDeposits  = 0.9*i / D
borrowIndex   growth  = factor                                   ~ i / B
```

so `liquidityIndex` outpaces `borrowIndex` exactly when `0.9*B > D` — the same condition
[[0004-liquidation-engine]] names as the reason the seizure availability bound exists.

The **economic** path cannot reach it. From `D0 = B0`, deposits track
`Dn = 0.9*Bn + 0.1*P`, which stays above `0.9*Bn` forever, and `borrow`/`withdraw` both
gate on `D >= B`. What reaches it is **dust**:
`totalDeposits = __fromScaledDown(51, liquidityIndex)` floors to a single-digit integer,
and `liquidityIndex * (interest - toReserves) / totalDeposits` against that denominator
blows the index up in one step. The reported failing pool state — `totalScaledDeposits:
51`, `reserves: 0` — matches exactly.

Not fixed here: it is a defect in core accrual, and folding a fix for it into a redemption
branch would have buried it. Evidence, logs and both call sequences:
`.superpowers/sdd/2026-09-19-dusd-redemption/evidence/`. It is the START HERE item in
`next_steps.md`.

A wei-scale rounding seam was found and deliberately left in place rather than
patched: the availability bound is computed in token units, but `_seizeCollateral`
converts with `__toScaledUp` (rounds up), so a seizure that exactly saturates the cap
can leave a pool's deposits 1–2 wei below its debt. It cannot trigger invariant 3
(which needs roughly a 10% deficit) and is recorded as a known limitation in
[[Liquidations]] rather than fixed with an unexplained `-1`.

**The backstop widened that seam, and the docs were corrected rather than the code.**
`liquidateWithBackstop` sets the seizure cap to precisely the availability the commit
just unlocked, so the "exactly saturates the cap" precondition holds on *every* call on
that path rather than occasionally — and `_commitBackstop`'s own down-rounding adds a
second floor in the same direction. A deterministic 2-wei shortfall was observed against
a ~449,740-token pool. None of the properties here can see it: invariant 3 needs a ~10%
deficit, invariant 5 holds because `getUtilization` clamps at `MAX_BPS`, and invariant 4
is a `gte` whose right-hand side the shortfall moves *down*, so the rounding runs in the
property's favour. The unit test
`testBackstopLeavesDepositsCoveringDebtWithinRoundingDust` therefore asserts the
shortfall is dust (≤ 10 wei) rather than zero, and says why. See
[[0006-internal-liquidation-backstop]].

## Running them

```
medusa fuzz --test-limit 50000
echidna . --contract CryticTester --config echidna.yaml --test-limit 30000
```

Echidna is **27/27** at `--test-limit 30000`, up from 25/25 — the two redemption target
functions (`desultory_redeem`, `desultory_redeemWithBackstop`) are what the count rose by;
no new `property_` was added, because the redemption assertion lives in-target (above).

**Medusa is not green.** It reports 25 passed, 1 failed at `--test-limit 50000`, and the
failure is `property_borrowIndexOutpacesLiquidityIndex` — a pre-existing defect in shipped
code, not a redemption bug. See the section below.

Counterexamples replay as Foundry tests via `test/recon/CryticToFoundry.sol`.

## Related

- [[Accounting]] — the accrual math these constrain
- [[Cross-Chain]] — the DUSD debt accounting invariants 7 and 8 constrain
- [[0002-internal-consistency-invariants]] — why this set and not another
- [[Liquidations]] — the surface invariants 9-12 constrain
- [[0006-internal-liquidation-backstop]] — the backstop that added invariant 12 and a
  second term to invariant 1
- [[DUSD]] — the redemption path the in-target assertion guards
- [[0007-dusd-redemption]] — the health-factor claim that turned out to be unassertable
