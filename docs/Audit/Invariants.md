---
status: current
verified-against: 2df55c5
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
Both start at `WAD` and both move out of the same charge: borrowers are charged
`interest`, and lenders receive only `interest - toReserves`. What holds the ordering is
the pair of ceilings ADR 0008 put in the distribution step. Lenders are credited only
when `interest > 0`, which requires `borrowIndex` to have moved first; the ceiling cut
then withholds at least 1 wei of every charge, and the `totalDeposits` divisor ceilings
so the credit is never spread over an understated base.

Two things this statement used to say and no longer does. *Debt can never exceed
deposits* is not a standing invariant — borrowing is bounded by `getAvailableLiquidity`,
but seizure and the backstop can leave a pool saturated past its deposit base. And no
deficit threshold is required to break it: ADR 0008 inverted the indexes at
`deposits == debt == 3` scaled. This is a consequence of the model rather than a restatement of the code,
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

### The stale-feed hole: most of the harness was dead

The redemption surface was known to be thinly covered, and was recorded here as two
limitations local to redemption. Investigating them found a cause that was **not** local to
redemption and was much worse than the symptom.

`warp` advanced `block.timestamp` by up to `MAX_WARP` = 30 days and did nothing else. Every
price read goes through `OracleLib.staleCheckLatestRoundData`, whose `TIMEOUT` is **3
hours**. So a single `warp` left *both* feeds stale, and every target that reads a price —
`borrow`, `repay`, `withdraw`, `redeem`, liquidation, and every `healthFactor` precondition
— reverted for the remainder of the sequence, unless the fuzzer happened to draw
`oracle_setPrice` for each of the two tokens before warping again.

Measured on a uniform driver over 8,000 calls against the harness as it stood:

| target | succeeded | reverted |
|---|---|---|
| `desultory_borrow` | **0** | 739 |
| `desultory_borrowDUSD` | **0** | 754 |
| `desultory_repay` | **0** | 755 |
| `desultory_withdraw` | **0** | 722 |
| `desultory_redeem` | **0** | 749 |

`deposit` and `warp` were the only things reliably working. The campaigns were green
because nothing was happening, and the properties were being evaluated against a state
almost nothing had moved.

The fix is the one `test/Desultory.t.sol`'s `_saturatedUsdcPool` already used for the same
reason: `warp` re-posts each feed's **current** answer, refreshing the timestamp without
touching the price. `oracle_setPrice` remains the only thing that moves a price.

### What was done about the redemption paths

With feeds live, four further changes made the dead paths reachable. None of them relaxes a
gate: **`healthFactor >= WAD` is untouched on both redemption targets** — that gate is the
feature, not an obstacle.

- **Target selection.** The four preconditions were each drawn from an independent seed, so
  their conjunction essentially never held. The redeemer is now drawn from actors that hold
  DUSD, the position from those that carry DUSD debt, and the collateral from what the
  position actually holds. Same class of clamp as the existing `_borrowCapacityInToken`.
- **The amount bound.** Both targets bounded input with `between(amount, 1, min(debt,
  balance))`, which can never exceed the debt, so `_redeem`'s clamp-to-debt branch and its
  re-clamp were unexecutable by construction. The bound is now the redeemer's balance: the
  final burn is at most `min(amount, debt) <= balance`, so over-asking is legal (the engine
  fills partially) and always payable.
- **`desultory_saturatePool`**, the harness form of `_saturatedUsdcPool`: draw the pool down
  to its last thousandth of available liquidity, then let time run. The thousandth is the
  point — drawing to exactly zero makes reserves and the deposit deficit grow together, so
  `_commitBackstop`'s guard fires and the commit buys nothing.
- **`desultory_releaseBackstop`'s bound** was computed from a snapshot taken *before* the
  call, but `releaseBackstop` accrues on its way in, and accrual grows debt faster than
  deposits every time. The bound now subtracts a conservative upper bound on that growth,
  `debt * rate * dt / (SECONDS_PER_YEAR * MAX_BPS) + 2`, all from public getters. It was
  succeeding 1 attempt in 5; it now succeeds on every attempt it makes.

Counter evidence, same 8,000-call driver both sides (lcov was not used — see below):

| counter | before | after |
|---|---|---|
| `redeem` succeeded | 17 | 60 |
| `redeem` clamp-to-debt fired | **0** | 41 |
| `redeemWithBackstop` succeeded | 39 | 298 |
| `redeemWithBackstop` clamp-to-debt fired | **0** | 209 |
| `_redeem` re-clamp (`removed > cap`) | 28 | 268 |
| backstop commit reached in a redemption | 27 | 253 |
| `releaseBackstop` succeeded / attempted | **1 / 5** | 41 / 41 |
| `borrowDUSD` succeeded | 153 | 413 |

Under Medusa at a 4,000,000 test limit with the same instrumentation, all eight paths fire
after the change; before it, the five marked **0** above never fired at all. At the routine
50,000 budget the old harness fired none of the eight.

The lesson is [[0008-reserve-cut-rounds-up]]'s, restated from the other direction: a green
fuzz run is not a proof. There it was green while a reachable defect remained; here it was
green because the campaign was barely executing the protocol. **Both times the green came
from the harness, not from the code.** Before trusting a campaign, check that its targets
are landing.

Also worth carrying forward: **lcov line coverage on this harness is unreliable.** It
reported non-zero hits on lines *after* a zero-hit call site, which cannot be true. Counter
instrumentation was used instead, added temporarily and removed before committing. Whoever
next reaches for coverage numbers here should not trust lcov.

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

**`property_borrowIndexOutpacesLiquidityIndex` failed a third time, and the cause was
this document's own justification for it.** That makes three real defects this harness has
caught in reviewed, merged code, after the accrual leak and the unbounded seizure above.
All three are now closed.

It was **confirmed on `master`**: `master` at `542f710`, `medusa fuzz --test-limit 120000`
-> 23 passed, **1 failed**. Two independent minimal reproductions contained only
`desultory_deposit`, `oracle_setPrice`, `desultory_borrow`, `desultory_repay`.

Root cause: the premise stated at the top of invariant 3 — *the reserve factor removes 10%
from the lender side, so borrow growth strictly dominates* — stopped holding at dust scale.
`toReserves = interest * RESERVE_FACTOR / MAX_BPS` **floored to zero for any `interest`
below 10 wei**, so the reserve factor removed nothing and lenders took the whole accrual.

It compounded with a second rounding: `interest` is the difference of two *ceilings* of
`totalScaledBorrows * borrowIndex / WAD`, so a minuscule `borrowIndex` move still ticks it
a full wei — interest manufactured by rounding rather than earned at the rate, all of it
then landing on the lender side.

One accrual against the failing state's own figures (51 scaled deposits, 45 scaled
borrows) was enough to invert the indexes:

| | growth in one 3-day accrual |
|---|---|
| `borrowIndex` | +0.768%, the genuine rate |
| `liquidityIndex` | +1.9608%, exactly `1/51` |
| `reserves` | 0 |

The inversion was **transient** — `borrowIndex` compounds back ahead within ~16 further
accruals and stays there, a 51-wei deposit grows to 70 over 40 rounds rather than
outrunning the index, and invariant 4 held throughout (`6 + 46 >= 52 + 0`). So it was an
ordering violation in dust-scale pools, not a share-inflation attack.

**Fixed**, in two steps. The reserve cut now rounds **up**
(`(interest * RESERVE_FACTOR + MAX_BPS - 1) / MAX_BPS`), so it withholds something on every
accrual with any interest at all. That alone was **not** enough: review then constructed a
second inversion the fix did not cover, reaching `deposits == debt == 3` scaled — a **zero**
deficit — where the `totalDeposits` divisor floored 25% below its true base and tripled
`liquidityIndex` in one accrual. So the divisor rounds up too. Both roundings in the
distribution step now turn toward the pool.
`toReserves <= interest` still holds for every `interest >= 1`, so the accrual leak above cannot return; `test_singleAccrualDistributesMoreThanItCharges` still
reports a total leak of 0. Regression tests: `test_dustPoolDoesNotLetLiquidityIndexOvertakeBorrowIndex` and
`test_dustDivisorDoesNotOvercreditLenders`, both in the same file as the leak test. Reasoning and rejected alternatives: [[0008-reserve-cut-rounds-up]].

Two lessons worth keeping. First, this invariant's justification was load-bearing *code*,
not commentary. The reserve factor was doing the work the proof claimed, right up until integer
division stopped it, and nothing else in the system noticed. Second, **a green fuzz run is
not a proof**: Medusa reported 26 passed / 0 failed after the first fix, while a second
reachable inversion was still there. It was found by a reviewer constructing the state by
hand, not by the fuzzer.

A wei-scale rounding seam was found and deliberately left in place rather than
patched: the availability bound is computed in token units, but `_seizeCollateral`
converts with `__toScaledUp` (rounds up), so a seizure that exactly saturates the cap
can leave a pool's deposits 1–2 wei below its debt. It cannot trigger invariant 3 — not because a couple of wei is under some deficit
threshold, which is the framing ADR 0008 falsified, but because the ceiling cut withholds
at least a wei of every charge and a 2-wei gap on a pool that size is ~4e-12 relative. It
is recorded as a known limitation in [[Liquidations]] rather than fixed with an
unexplained `-1`.

**The backstop widened that seam, and the docs were corrected rather than the code.**
`liquidateWithBackstop` sets the seizure cap to precisely the availability the commit
just unlocked, so the "exactly saturates the cap" precondition holds on *every* call on
that path rather than occasionally — and `_commitBackstop`'s own down-rounding adds a
second floor in the same direction. A deterministic 2-wei shortfall was observed against
a ~449,740-token pool. None of the properties here can see it: invariant 3 is held by the roundings
with twelve orders of magnitude of headroom at this pool size (the restated argument is
in [[Liquidations]]), invariant 5 holds because `getUtilization` clamps at `MAX_BPS`, and invariant 4
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

Medusa is **26 passed, 0 failed** at `--test-limit 50000`, up from 24 — the two redemption
target functions are what the count rose by. It was 25 passed / 1 failed until
[[0008-reserve-cut-rounds-up]] closed the dust-pool inversion described above.

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
