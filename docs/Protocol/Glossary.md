---
status: current
verified-against: 10d4d92
---

# Glossary

Terms used across the vault and the code, in alphabetical order. Each entry says what the
term means here, which is not always what it means in other protocols. Follow the link for
the full treatment.

**Accrual.** Bringing a pool's indexes up to the current block. `accrue(token)` for a pool
asset and `accrueDusd()` for DUSD. It runs lazily at the top of every state-changing call,
so stored balances are only current right after a call touches that pool. Borrowers are
charged first, then exactly that amount is split between reserves and depositors.
[[Accounting]]

**Available liquidity.** `getAvailableLiquidity(token)`: `max(0, deposits − debt)`. What a
withdrawal, a borrow or a seizure may take out of a pool. It under-reports spendable cash by
the reserves, on purpose. [[Liquidations]]

**Backstop (internal).** On the `...WithBackstop` paths, the protocol converts some of
`pool.reserves` into its own deposit line (`backstopScaledDeposits`) so that a liquidation
or redemption can go ahead against a pool short of cash. No tokens move; only bookkeeping
changes. The owner reverses it with `releaseBackstop`. The *external* backstop (flash loan
from another protocol) is not built. [[0006-internal-liquidation-backstop]]

**Bad debt.** Debt left on a position that has no collateral left. It is added to
`totalBadDebtUSD` and never written off against depositors: the liquidity index never goes
down. [[Liquidations]]

**BPS.** Basis points: 10 000 = 100%. Rates, fees, bonuses and the close factor are all in
BPS (`MAX_BPS = 10_000`). LTV and liquidation threshold are the exception: they are whole
percentages.

**Borrow index / liquidity index.** Per-pool multipliers, starting at 1e18. The borrow
index grows by the borrow rate and turns scaled debt into real debt. The liquidity index
grows by depositors' share of the interest and turns scaled deposits into real deposits.
Neither ever decreases. [[Accounting]]

**Close factor.** The largest share of a position's debt one liquidation may repay: 50%, or
100% once the health factor is below 0.95. An oversized `repayAmount` is clamped down to it,
not rejected. [[0004-liquidation-engine]]

**Custody identity.** `token balance held + total debt = total deposits + reserves`, per
pool: every deposited token is either in the contract or lent out, and the only other claim
is the protocol's reserves. Fuzzing invariant 4 asserts the `>=` form. [[Invariants]]

**Debt ceiling.** `dusdDebtCeiling`: a cap on this home chain's total DUSD debt, fee
included. It is checked only when DUSD is borrowed. It starts at zero, which blocks every
DUSD borrow until the owner sets it. [[0010-dusd-debt-ceiling]]

**DUSD.** The protocol's stablecoin, valued at exactly $1 inside the protocol. Minted
against collateral, burned on repayment or redemption. The only asset that crosses chains.
[[DUSD]]

**Destination chain.** The chain where cross-chain DUSD is minted. The owner must allow it
first (`setAllowedDestination`). [[Cross-Chain]]

**EID.** LayerZero endpoint id: LayerZero's numeric identifier for a chain.

**Health factor.** `liquidation-threshold-weighted collateral USD / debt USD`, in WAD.
Below 1e18 a position is liquidatable and cannot be transferred; at or above it, it can be
redeemed against. `type(uint256).max` when there is no debt. [[Liquidations]]

**Home chain.** The chain where a position was opened. All its collateral and all its debt
(DUSD debt included) live there, wherever the DUSD was minted. [[0003-dusd-only-cross-chain-borrowing]]

**Kinked rate model.** The borrow-rate curve: four straight-line segments that get steeper
as utilization rises, sharply above 80% and 95%. [[Interest-Rate-Model]]

**Liquidation bonus.** The discount a liquidator receives, per collateral token, in BPS
(10% for WETH and 5% for USDC in the deploy script; capped at 20%). 30% of the bonus goes to
reserves, or 70% on the backstop path. [[Liquidations]]

**Liquidation threshold.** Per token, percent. The weight a token's value gets in the health
factor. Always strictly above its LTV, and the gap between the two is the buffer a position
can drift through before it is liquidatable. [[Positions]]

**LTV (loan-to-value).** Per token, percent. The weight a token's value gets when deciding
whether a position may borrow more or withdraw. It governs new borrowing only; it never
triggers a liquidation.

**OApp / OFT.** LayerZero V2 base contracts. An OApp sends and receives arbitrary messages
(`Adapter`); an OFT is a token that moves between chains by burning on one and minting on
the other (`DUSD`, `VoteToken`).

**Par convention.** Inside the protocol one DUSD is always worth exactly $1: no price feed is
read. Redemption is what makes that hold in the market from below. [[DUSD]]

**Peer.** On LayerZero, the address an OApp trusts as its counterpart on another chain. Set
by the owner. Whoever controls a peer can mint DUSD. [[Threat-Model]]

**Position.** An ERC721 token whose id keys all collateral and debt accounting. Owning the
token is owning the position. [[Positions]]

**Redemption.** Burning DUSD to receive collateral worth the same USD minus 0.5%, taken from
a healthy position that owes DUSD, whose debt falls by the full amount burned. [[0007-dusd-redemption]]

**Reserves.** `pool.reserves` per token: protocol revenue, from the 10% reserve factor plus
its share of liquidation bonuses. The owner withdraws them with `withdrawReserves`.
`dusdReserves` is the DUSD stability fee. It is a claim with no tokens behind it, and it
cannot be withdrawn. [[0005-treasury-withdrawal]]

**Retired token.** A listed token that accepts no new deposits or borrows. It is never
removed from the list, and every way out (withdraw, repay, liquidate, redeem) still works.
[[0009-token-listing-admin]]

**Rounding direction.** The house rule: every conversion rounds in the pool's favour.
Deposits round down, debts round up. [[Accounting]]

**Scaled balance.** A balance stored divided by its index at the time it was written. Real
amount = scaled × current index / 1e18. This is how interest reaches every position without
looping over them. [[Accounting]]

**Stability fee.** The flat annual rate charged on DUSD debt (default 2%), all of it booked
to `dusdReserves`. DUSD does not use the kinked curve, because nobody deposits DUSD.
[[DUSD]]

**Utilization.** `total debt / total deposits` for a pool, in BPS, capped at 100%. The input
to the kinked rate model.

**WAD.** Fixed-point 1e18 = 1.0. Health factors and indexes are WAD-scaled; USD values are
18-decimal.
