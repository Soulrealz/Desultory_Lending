---
status: current
verified-against: 620ff7d
---

# Invariants

The properties the Chimera harness asserts, in prose. An invariant nobody can state
in a sentence is an invariant nobody can review.

Implementation lives in `onchain/ethereum/test/recon/Properties.sol`. The reasoning
behind this particular set is [[0002-internal-consistency-invariants]].

All six are **internal-consistency** properties: they constrain the bookkeeping, not
the economics. Each holds even when the protocol is underwater, which is what allows
the fuzzer to move oracle prices between 0.01× and 100× of their starting value
without generating false alarms.

## The six

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

## Deliberately not asserted

**Economic solvency** (collateral USD ≥ debt USD). Not a property this protocol has
while [[Liquidations]] is broken. Revisit in Project D, where a ghost bad-debt counter
makes it meaningful.

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

## Running them

```
medusa fuzz
echidna . --contract CryticTester --config echidna.yaml
```

Counterexamples replay as Foundry tests via `test/recon/CryticToFoundry.sol`.

## Related

- [[Accounting]] — the accrual math these constrain
- [[0002-internal-consistency-invariants]] — why this set and not another
- [[Liquidations]] — the excluded surface
