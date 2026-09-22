---
status: accepted
date: 2026-09-22
---

# 0008 — The reserve cut rounds up

## Status

Accepted.

## Context

`property_borrowIndexOutpacesLiquidityIndex` failed under Medusa on `master`, in shipped,
reviewed, merged code. It was the **third** real defect the Chimera harness has caught,
after the accrual leak ([[0002-internal-consistency-invariants]]) and the unbounded
seizure ([[0004-liquidation-engine]]).

The invariant's own justification, written in `Properties.sol`, is:

> debt can never exceed deposits, and the reserve factor removes 10% from the lender side
> before liquidityIndex grows, so borrow growth strictly dominates.

That argument silently stopped holding at dust scale. `accrue()` computed the cut as

```solidity
uint256 toReserves = (interest * RESERVE_FACTOR) / MAX_BPS;   // floors
```

and `RESERVE_FACTOR` is 1 000 of 10 000, so **any `interest` below 10 wei floored to
zero**. The reserve factor removed nothing, and the whole of the accrual went to lenders —
in precisely the case the invariant's proof assumed it could not.

A second rounding compounded it. `interest` is the difference of two *ceilings* of
`totalScaledBorrows * borrowIndex / WAD`, so a minuscule `borrowIndex` movement still ticks
it by a full wei. That wei was manufactured by rounding rather than earned at the rate, and
the whole of it then landed on the lender side.

Against a small deposit base the effect is large in relative terms. The reproduction, now
`test_dustPoolDoesNotLetLiquidityIndexOvertakeBorrowIndex` in
`test/recon/AccrualLeak.t.sol`, uses the figures the failing pool state actually carried —
51 scaled deposits, 45 scaled borrows — and **one** accrual is enough:

| | growth in one 3-day accrual |
|---|---|
| `borrowIndex` | +0.768% — the genuine rate |
| `liquidityIndex` | +1.9608%, which is exactly `1/51` |
| `reserves` | 0 |

One wei of interest, none of it withheld, moved `liquidityIndex` by `1/51` while the rate
moved `borrowIndex` by a third as much. The indexes inverted immediately.

**What it was not.** The inversion is transient: `borrowIndex` compounds back past
`liquidityIndex` within ~16 further accruals and stays ahead, and a 51-wei deposit grows to
70 over 40 rounds, tracking the index rather than outrunning it. There is no unbounded
pump, so this is not a share-inflation attack, and `property_custodyReconciles` held
throughout at the failing state (`6 + 46 >= 52 + 0`). It is an ordering violation in
dust-scale pools, which is exactly what the invariant exists to catch.

## Decision

**The reserve cut rounds up.**

```solidity
uint256 toReserves = (interest * RESERVE_FACTOR + MAX_BPS - 1) / MAX_BPS;
```

Three reasons this is the right line to change rather than the invariant:

1. **It restores the invariant's stated premise.** The property is justified by the reserve
   factor removing something on every accrual. Ceiling makes that true for every
   `interest >= 1` instead of only for `interest >= 10`.
2. **It is the direction the protocol's own rounding rule already demands.** Every other
   conversion in `accrue()` rounds toward the pool. `toReserves` flooring was the sole
   exception, and it rounded toward lenders and away from the protocol.
3. **It cannot reintroduce the leak of [[Accounting]]'s accrual bug.** `toReserves <=
   interest` still holds for every `interest >= 1`, so `interest - toReserves` cannot
   underflow and the pool still distributes no more than it charged. The existing
   `test_singleAccrualDistributesMoreThanItCharges` continues to report a total leak of 0.

The cost is at most one wei of extra reserve per accrual, taken from the lender side, in a
direction that favours the protocol's solvency.

`accrue()` is otherwise untouched. Its charge-first-then-distribute ordering — the property
that the earlier leak violated and that [[Accounting]] documents — is unchanged.

## Alternatives considered

**Narrow the invariant to pools above a dust threshold.** Rejected. The reserve factor
genuinely cannot dominate at dust scale under the old arithmetic, so the invariant as
written did assert something the protocol did not provide — but weakening a fuzzing
invariant to match the code is the direction this project has consistently refused to take,
and it would leave the underlying rounding asymmetry in place for every pool, not just the
dust ones.

**Floor `totalDeposits` in the `liquidityIndex` divisor.** Rejected: it needs an arbitrary
magic minimum, which is the same unexplained-constant smell as the `-1` that
[[0004-liquidation-engine]] refused for the seizure rounding seam. It also treats the
symptom — the large relative jump — rather than the cause, which is that nothing was
withheld.

**Clamp `liquidityIndex` growth so it can never exceed `borrowIndex` growth.** Rejected as
the worst of the three: it makes the invariant true by construction while leaving the
accounting wrong, so the harness would stop being able to detect this class of defect at
all.

**Round `interest` down instead, so rounding cannot manufacture it.** Rejected: `interest`
is deliberately derived from the debt actually charged, and lowering it below what borrowers
were charged is exactly the leak [[Accounting]] documents, in reverse. The manufactured wei
is real debt the borrower owes; the defect was that none of it was withheld.

## Consequences

- `property_borrowIndexOutpacesLiquidityIndex` passes. Medusa goes from 25 passed / 1
  failed to **26 passed / 0 failed** at `--test-limit 50000`; Echidna stays at 27/27.
- Lenders forgo up to one wei per accrual relative to the old behaviour, and reserves gain
  it. At any material scale the ceiling is indistinguishable from the floor.
- In a dust pool where `interest` is a single wei, `liquidityIndex` now does not move at
  all until interest reaches 10 wei. Lenders in such a pool earn nothing until it is worth
  earning, which is the honest outcome — previously they earned a wei the rate had not
  produced.
- The harness is now **three for three** on real defects in reviewed code, and for the
  first time all three are closed.
- `Desultory` runtime grows 23 bytes, to 18 277 of 24 576.

## Related

- [[Accounting]] — the accrual model this changes one rounding direction in
- [[Invariants]] — the property this restores, and its justification
- [[0002-internal-consistency-invariants]] — the harness that found it, and the first
  defect it caught
- [[0004-liquidation-engine]] — the second defect, against the same property
