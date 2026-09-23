---
status: current
verified-against: edaa61a
---

# Interest Rate Model

`getBorrowRate(token, utilization)` returns an annual rate in BPS. It is a
four-segment piecewise-linear curve — a "kinked" model — that gets steep as the
pool runs dry, so that the last of the liquidity is expensive and lenders are
pulled in before it is exhausted.

## Utilization

`getUtilization(token)` is `totalDebt / totalDeposits` in BPS, capped at
`MAX_BPS` (10 000 = 100%), and `0` for an empty pool.

`totalDeposits` is `pool.totalScaledDeposits` read back through `__fromScaledDown`, which since
[[0006-internal-liquidation-backstop]] includes `pool.backstopScaledDeposits` — the
protocol's own deposit line, funded out of reserves to let a seizure proceed against a
cash-poor pool. So a backstop commit **lowers measured utilization**, and it does so
exactly when the pool is most stressed: a saturated pool sitting at the 10 000 cap reads
just under it after a commit, and borrowers pay a marginally lower rate in the extreme
band.

That is arguably correct rather than a leak — the protocol really did contribute capital,
and the denominator should reflect it, the same way it would for any other lender's
deposit. The magnitude is proportional to the committed amount over total debt, which is
small, since the commit is bounded by the seizure it is unlocking. It is recorded here
because the effect is easy to miss: it falls out of the `Pool` struct's composition rather
than from anything in this module, which is otherwise untouched by the backstop.

## The curve

Defaults set in the `Desultory` constructor:

| Breakpoint | Utilization | Segment rate | Rate at that point |
|---|---|---|---|
| base | 0% | 1% | 1% |
| low | 15% | 2% | 3% |
| normal | 80% | 7% | 8% |
| high | 95% | 35% | 36% |
| extreme | 100% | 65% | 66% |

The stored parameter is the segment rate; `baseBorrowRate` is added on top of it in every
branch, which is where the last column comes from.

Between breakpoints the rate is linear. The formula in each segment is
`base + previousSegmentRate + (excessUtilization * rateGap / utilizationGap)`.

Note the shape: nearly flat up to 80%, then it turns almost vertical. Going from
95% to 100% utilization costs a borrower 30 percentage points of APR.

## Per-token multiplier

The curve is global. Each token then scales it by `Collateral.borrowRate`, where
`100` means 1x:

```solidity
return (baseRate * __tokenInfos[token].borrowRate) / 100;
```

The deploy script uses `400` for WETH (4x) and `200` for USDC (2x). So a token's
riskiness is expressed as a multiplier on one shared curve rather than as its own
curve — simple, and it means the kink points can never drift apart between assets.

## The uint32 fix

The lowest segment computes `utilization * lowBorrowRate / lowUtilization`. With
both operands `uint16` and `lowBorrowRate` at 200, the product overflows `uint16`
for any utilization at or above 328 BPS — i.e. 3.28% utilization, which is an
entirely ordinary state. The multiplication is cast to `uint32` and the return
type widened to `uint32`. Fixed in `e985572`; the note exists so nobody narrows
it back.

## Not implemented

Rate parameters are set once in the constructor and there is no way to change
them afterward — the contract is `Ownable`, but no setter for `__interest` exists at
all. Retuning the curve currently means
redeploying. See [[Audit]].

## Related

- [[Accounting]] — how this rate is turned into index growth
