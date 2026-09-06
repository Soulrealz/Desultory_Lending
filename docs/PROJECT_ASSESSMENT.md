# Desultory Lending — Project State Assessment (2026-06-10)

## Verdict: Salvageable — keep the scaffold and core flows, rewrite liquidations, design the missing layers

The project compiles cleanly on solc 0.8.28 / Foundry 1.5.1 and all 10 tests pass
(`PRIVATE_KEY` env var must be set — any key works for local tests, e.g. the default
Anvil key). The single-chain core (deposit / withdraw / borrow / repay with an
index-based interest accrual) is a genuinely reusable foundation. Starting from
scratch would throw away working, tested code without buying anything — the parts
that are missing (cross-chain, lender yield, governance) are greenfield either way.

## What exists and works

| Area | State |
|---|---|
| Foundry scaffold, deploy script, mock config | Working |
| Deposit / Withdraw with LTV check | Working, tested |
| Borrow / Repay | Working, tested |
| 4-bracket kinked borrow-rate model (`getBorrowRate`) | Working, matches README formulas |
| Global borrow index + per-borrower debt sync | Working, tested incl. time-warp tests |
| Chainlink oracle wrapper with staleness check (`OracleLib`) | Working |
| Position NFT minting on first deposit | Working (but see below) |

## What is broken (needs rewrite, not patching)

1. **`liquidateAssetPosition` pays the liquidator in the wrong token**
   (`Desultory.sol:352`, `:358`) — transfers `tokenToRepay` using an amount
   denominated in `tokenToLiquidate`.
2. **Liquidation seizes collateral regardless of debt size**
   (`settleDebtSeizeCollateral`) — takes 90% of the *entire* collateral balance for
   that token even for a tiny debt, and the penalty is applied as a haircut on the
   liquidator instead of a bonus.
3. **`processCollateralLiquidation` proportion math always rounds to zero**
   (`Desultory.sol:704`) — `valueUSD / totalUSD` in integer math is 0 unless a single
   asset is 100% of collateral. Proportional liquidation transfers nothing.
4. **Liquidator intent inferred from `balanceOf(msg.sender)`** — balance is not
   approval; the "use protocol funds" fallback zeroes the debt without anyone paying
   it (depositors silently eat the loss).
5. **Liquidation paths never call `updateGlobalBorrowIndex`/`updateBorrowerDebt`**,
   so they evaluate stale debt.
6. **No liquidation threshold separate from LTV** — positions become liquidatable the
   instant they hit max borrow; README's 0–4.9% / 5% threshold bands are not implemented.

## What is missing entirely (the actual project goals)

1. **Cross-chain (the headline feature): 0%.** `src/crosschain/Adapter.sol` is a
   single `pragma` line. DUSD's OFT constructor is commented out (plain ERC20 now).
   `MockLZ.sol` exists but nothing uses it.
2. **NFT-as-position is minted but not honored.** All accounting keys off
   `__userPositions[msg.sender]`. Transferring the Position NFT does *not* transfer
   the position — buyer gets a picture, seller keeps withdraw/borrow rights. The core
   "tradeable position" idea requires deriving ownership from `positionNFT.ownerOf()`
   everywhere instead of the address mapping.
3. **Depositors earn nothing.** Borrower interest accrues into debt, but there is no
   share/exchange-rate model distributing it to lenders; repaid interest becomes
   orphaned contract balance. The desired interest design (borrow-fee interest scales
   with borrow rate; lender yield inversely related to lending rate) has no
   implementation surface yet — and note the inverse lender curve needs a funding
   design (paying lenders most when fee income is lowest is insolvent without a
   reserve buffer).
4. **DUSD minting/borrowing, flash-loan liquidation backstop, ElizaOS auto-liquidation,
   governance/staking/slashing** — all `@todo` or absent. `VoteToken` is a bare OFT.
5. **No access control on `Desultory`** — no owner, no way to add/remove tokens or
   tune parameters post-deploy.

## Housekeeping issues

- **Line endings:** every tracked file shows as modified (CRLF→LF churn from the
  Windows→WSL move). Fix once with a `.gitattributes` (`* text=auto eol=lf`) and
  `git add --renormalize .` before any real work, or every future diff is noise.
- **`.gitmodules` has Windows backslash paths** (`lib\openzeppelin-contracts`) —
  submodules are broken on Linux. `lib/` is gitignored anyway; either re-add
  submodules with forward slashes or drop `.gitmodules` and treat deps as
  install-on-clone (current README approach). Note: `forge install --no-commit` flag
  in the README no longer exists in Foundry 1.x.
- `console` import left in `Desultory.sol`; missing SPDX headers; `Collateral.decimals`
  conflates token decimals with price-feed assumptions (real USDC is 6 decimals, the
  deploy script uses 8); unchecked `transfer` at `Desultory.sol:710`.

## Suggested order of attack

1. Fix line endings + `.gitmodules` (one commit, no logic changes).
2. ~~Make the Position NFT the source of truth for ownership~~ — DONE 2026-06-10
   (positionId-keyed API, `ownerOf` auth, health-gated transfers).
3. ~~Add lender-side accounting (share or index model)~~ — DONE 2026-06-10
   (Aave-style liquidity index, scaled balances both sides, 10% reserve factor).
4. Rewrite the liquidation engine against a spec (close factor, bonus direction,
   health factor with a threshold above LTV).
5. Only then start cross-chain: DUSD as OFT + a hub-and-spoke or message-passing
   design via LayerZero. This is a design problem first (where does collateral truth
   live, how do you handle cross-chain liquidation latency), worth a brainstorming
   session before code.
