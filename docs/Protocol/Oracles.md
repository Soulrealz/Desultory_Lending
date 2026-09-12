---
status: current
verified-against: 5db9f71
---

# Oracles

All USD valuation goes through Chainlink feeds, wrapped by
`src/libraries/OracleLib.sol`.

## Staleness

`staleCheckLatestRoundData` reverts with `OracleLib__StalePrice` when any of:

- `updatedAt == 0` — the round never completed
- `answeredInRound < roundId` — the answer is carried over from an earlier round
- `block.timestamp - updatedAt > TIMEOUT` where `TIMEOUT` is **3 hours**

Reverting is the right failure mode: a lending protocol that keeps operating on a
stale price will mis-price every health check in the same direction, and an
attacker who can predict which direction can drain it. Freezing is a denial of
service; continuing is a loss of funds.

The flip side, unhandled today: if a feed goes down for longer than 3 hours,
**every** state-changing function reverts, because they all reach `getValueUSD`.
Deposits, repayments, and liquidations all stop — including the liquidations that
would protect the protocol. `TIMEOUT` is a compile-time constant with no override.

## Decimal normalization

`getValueUSD` returns an 18-decimal USD value, and handles two independent decimal
sources:

```solidity
uint256 price18 = uint256(price) * (10 ** (18 - collat.feedDecimals));
return (amount * price18) / (10 ** collat.tokenDecimals);
```

`Collateral` stores them separately:

- `feedDecimals` — decimals of the Chainlink feed (typically 8)
- `tokenDecimals` — decimals of the ERC-20 (18 for WETH, 6 for real USDC)

These were previously conflated in a single `decimals` field, which was wrong for
any token whose feed and ERC-20 disagree — which is most of them. Verified by
`testGetValueUSDIsNormalizedTo18Decimals`.

Note `10 ** (18 - collat.feedDecimals)` underflows for a feed with more than 18
decimals. No such Chainlink feed exists in practice, and there is no guard.

## Deploy-time mismatch

`script/Deploy.s.sol` configures USDC with `feedDecimals = 8` and
`tokenDecimals = 18`, because the mock is an 18-decimal ERC-20. Real USDC is a
**6-decimal** token. The mock config is internally consistent and the tests are
correct, but the values must change before any deployment against real USDC.

## No fallback

One feed per token, no secondary source, no circuit breaker, no TWAP. If Chainlink
is wrong, the protocol is wrong. Acceptable for a learning project on major assets;
worth naming as an assumption rather than leaving implied.

## Related

- [[Accounting]] — the balances being valued
- [[Positions]] — the health check these prices feed
