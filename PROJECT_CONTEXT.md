# Project Context

> Maintained per the rule in `CLAUDE.md`: update when core logic is added or rewritten.
> This is a rough map of what lives where — enough to orient, not full documentation.

## What this project is

A learning project: an over-collateralized, cross-chain borrow/lending protocol.
Target design: deposit collateral on one chain (e.g. Ethereum mainnet), borrow against
it on another (e.g. Base/Optimism) via LayerZero. Positions are represented as NFTs so
they can eventually be traded between users. Full spec in `README.md`; current
gaps/bugs catalogued in `docs/Audit/2026-06-10-project-assessment.md`.

## Modules

### `src/Desultory.sol` — core lending pool (the bulk of all logic)
- Single contract holding all collateral and debt accounting, keyed by
  **position id** (the Position NFT token id). Authorization for `withdraw`/
  `borrow` is `positionNFT.ownerOf(positionId) == msg.sender`; `deposit` and
  `repay` are permissionless. `deposit(0, …)` mints a fresh position.
- Per-token `Pool` struct: `liquidityIndex` (lender yield) + `borrowIndex`
  (debt growth), with **scaled balances** on both sides
  (`__scaledDeposits`/`__scaledBorrows`); real value = scaled × index / 1e18.
  `accrue(token)` runs at the top of every state-changing call: borrowers pay
  `getBorrowRate(utilization)`, 10% of interest goes to `pool.reserves`
  (RESERVE_FACTOR), 90% grows the liquidity index. Rounding always favors the
  pool (deposits round down, debts round up).
- Interest: 4-bracket kinked rate model (`getBorrowRate`) — unchanged in shape;
  a latent uint16 overflow in the low bracket was fixed (uint32 cast).
- `getValueUSD` returns 18-decimal USD, normalizing feed decimals and token
  decimals separately (`Collateral.feedDecimals` / `tokenDecimals`).
- View caveat: `getPositionBorrowForToken`/`getPositionCollateralForToken`
  read stored indexes — they don't simulate accrual since `lastUpdate`.
- Liquidations (`liquidateAssetPosition`, `liquidateProportionalPosition`):
  **still known-broken**, only mechanically re-pointed at the new storage;
  redesign is assessment point 4. Untested on purpose.
- No admin/treasury withdrawal yet; `pool.reserves` just accumulates.

### `src/PositionNFT.sol` — `Position` ERC721
- Token id = position id; minted by Desultory (`deposit(0, …)`). The NFT IS
  the position: transferring it moves collateral + debt control to the buyer.
- `_update` health gate: transfers (not mints) revert while the position is
  liquidatable (`Desultory.isPositionHealthy`). `setProtocol` wires the
  Desultory address once, before ownership transfer (see `Deploy.s.sol`).

### `src/DUSD.sol` — protocol stablecoin
- Currently a plain ERC20 stub; intended to become a LayerZero OFT minted/borrowed by
  the protocol (commented-out OFT constructor).

### `src/governance/VoteToken.sol` — governance token
- Bare LayerZero OFT. Staking/boosting/slashing from the spec not implemented.

### `src/crosschain/Adapter.sol` — cross-chain adapter
- Empty placeholder (pragma only). All cross-chain functionality is future work.

### `src/libraries/OracleLib.sol`
- Wraps Chainlink `latestRoundData` with a 3-hour staleness revert. All USD valuation
  in Desultory goes through this via `getValueUSD`.

### `script/` — deployment
- `Config.s.sol`: per-network addresses; deploys `MockV3Aggregator` + `MockERC20`
  (WETH 18 dec, USDC 8 dec) on Anvil chain id 31337.
- `Deploy.s.sol`: deploys Position, DUSD, Desultory with WETH (feed 18 dec, LTV 70,
  rate 400) and USDC (feed 8 dec, LTV 85, rate 200); both mock tokens are 18-dec
  ERC20s (`tokenDecimals = [18, 18]`). Calls `position.setProtocol(desultory)` then
  transfers Position ownership to Desultory. Reads `PRIVATE_KEY` env var.

### `test/`
- `Desultory.t.sol` — 21 tests: deposit/withdraw/borrow/repay on the positionId
  API, interest accrual & lender yield (incl. 10% reserve check), NFT-transfer
  control handoff, unhealthy-transfer gating, and fuzz invariants for the
  rounding/solvency policy. Liquidation paths remain untested on purpose.
- `Position.t.sol` — 7 unit tests for mint auth, `setProtocol` wiring, and the
  health-gated `_update` hook (via a stub protocol).
