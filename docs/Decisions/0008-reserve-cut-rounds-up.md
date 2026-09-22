---
status: accepted
date: 2026-09-22
---

# 0008 — The accrual roundings both turn toward the pool

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
`liquidityIndex` within a handful of further accruals and stays ahead, and a 51-wei deposit
grows to 70 over 40 rounds, tracking the index rather than outrunning it. There is no unbounded
pump, so this is not a share-inflation attack, and `property_custodyReconciles` held
throughout at the failing state (`6 + 46 >= 52 + 0`). It is an ordering violation in
dust-scale pools, which is exactly what the invariant exists to catch.

## Decision

**Both roundings in the distribution step turn toward the pool.**

```solidity
uint256 toReserves   = (interest * RESERVE_FACTOR + MAX_BPS - 1) / MAX_BPS;      // was floor
uint256 totalDeposits = __fromScaledUp(pool.totalScaledDeposits, liquidityIndex); // was floor
```

The first was found by root-causing the reported failure. **The second was found in review,
after the first was already committed and Medusa was already green** — the reviewer
constructed a state the fix did not cover, and it reproduced exactly.

### Why the cut alone was not enough

Ceiling the cut only helps while `interest < 10`. The other rounding in the same three
lines is structural. Growth is

```
deposits grow by  distributed * trueDeposits / totalDeposits
```

so a `totalDeposits` **floored below** the true base credits lenders more than was charged —
the same leak family as above, entering through the denominator rather than the numerator.
At dust scale the understatement is large in relative terms: a base of 3 against a true
3.999 is 25% off, which no 10% cut can absorb.

The reproduction, now `test_dustDivisorDoesNotOvercreditLenders`, reaches
`deposits == debt == 3` scaled through plain public calls and lets a year accrue at ~264%:
`interest` 11 wei, `toReserves` 2, so 9 wei distributed over a floored base of 3 **tripled**
`liquidityIndex` while `borrowIndex` grew 3.64x. Ceiling the divisor makes it 9/4 = 3.25x
and the ordering holds. Note the deficit here is **zero** — deposits equalled debt — so this
was never reachable only in the `0.9B > D` region the older notes describe.

### Why these are the right lines to change rather than the invariant

1. **They restore the invariant's stated premise.** The property is justified by the
   reserve factor removing something on every accrual. Ceiling the cut makes that true for
   every `interest >= 1` instead of only for `interest >= 10`, and ceiling the divisor stops
   the denominator giving it back.
2. **It is the direction the protocol's own rounding rule already demands.** Every other
   conversion in `accrue()` rounds toward the pool. These two were the only exceptions, and
   both rounded toward lenders and away from the protocol.
3. **Neither can reintroduce the leak of [[Accounting]]'s accrual bug.** `toReserves <=
   interest` holds for every `interest >= 1`, so `interest - toReserves` cannot underflow
   and the pool still distributes no more than it charged; ceiling the divisor can only
   distribute *less*. `test_singleAccrualDistributesMoreThanItCharges` continues to report a
   total leak of 0.

The underflow bound, stated explicitly because this is interest accrual in a lending
protocol: `(i*1000 + 9999)/10000 = ceil(i/10)`, and `ceil(i/10) <= i` for all `i >= 1`
since `i + 9 <= 10i`. Equality holds only at `i in {0, 1}`, where `liquidityIndex` simply
does not move. `accrue()` cannot revert on that subtraction.

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

**Impose an arbitrary minimum on `totalDeposits`.** Rejected: an unexplained magic constant,
the same smell as the `-1` [[0004-liquidation-engine]] refused for the seizure seam.
Rounding the divisor up needs no constant and is the same discipline applied consistently.
(An earlier draft of this ADR dismissed touching the divisor at all as symptom-treatment.
That was wrong — the floored divisor was the other half of the cause, and review caught it.)

**Clamp `liquidityIndex` growth so it can never exceed `borrowIndex` growth.** Rejected as
the worst of the three: it makes the invariant true by construction while leaving the
accounting wrong, so the harness would stop being able to detect this class of defect at
all.

**Round `interest` down instead, so rounding cannot manufacture it.** Rejected: `interest`
is deliberately derived from the debt actually charged, and lowering it below what borrowers
were charged is exactly the leak [[Accounting]] documents, in reverse. The manufactured wei
is real debt the borrower owes; the defect was that none of it was withheld.

## Consequences

- Both known reproductions are closed and Medusa goes from 25 passed / 1 failed to
  **26 passed / 0 failed** at `--test-limit 50000`; Echidna stays at 27/27. That is not a
  proof. The first fix also produced a green Medusa run while a second reachable inversion
  still existed, which is exactly how the divisor defect was found — by construction in
  review, not by the fuzzer. Treat a green run as "not found at this limit".
- Lenders forgo up to one wei per accrual relative to the old behaviour, and reserves gain
  it. At any material scale the ceiling is indistinguishable from the floor.
- In a dust pool where `interest` is a single wei, `liquidityIndex` does not move at all:
  `distributed = interest - ceil(interest/10)` is zero only at `interest <= 1`, so lenders
  begin earning at 2 wei. Previously they earned a wei the rate had not produced.
- The harness is **three for three** on real defects in reviewed code. All three are
  closed, with the caveat above about what a green fuzz run does and does not establish.
- `Desultory` runtime grows 23 bytes, to 18 277 of 24 576.

## Related

- [[Accounting]] — the accrual model this changes one rounding direction in
- [[Invariants]] — the property this restores, and its justification
- [[0002-internal-consistency-invariants]] — the harness that found it, and the first
  defect it caught
- [[0004-liquidation-engine]] — the second defect, against the same property
