---
status: current
verified-against: 5db9f71
---

# Interest Rate Model

`getBorrowRate(token, utilization)` returns an annual rate in BPS. It is a
four-segment piecewise-linear curve — a "kinked" model — that gets steep as the
pool runs dry, so that the last of the liquidity is expensive and lenders are
pulled in before it is exhausted.

## Utilization

`getUtilization(token)` is `totalDebt / totalDeposits` in BPS, capped at
`MAX_BPS` (10 000 = 100%), and `0` for an empty pool.

## The curve

Defaults set in the `Desultory` constructor:

| Breakpoint | Utilization | Rate at that point |
|---|---|---|
| base | 0% | 1% |
| low | 15% | 2% |
| normal | 80% | 7% |
| high | 95% | 35% |
| extreme | 100% | 65% |

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
them afterward — no owner, no setter. Retuning the curve currently means
redeploying. See [[Audit]].

## Related

- [[Accounting]] — how this rate is turned into index growth
