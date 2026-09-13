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
  pool (deposits round down, debts round up). `accrue` charges borrowers **first**
  and then distributes exactly what was charged — deriving the interest from a
  pre-computed notional instead let the pool pay out more than it took in (found by
  the fuzzer; see `docs/Protocol/Accounting.md`).
- `getScaledDeposit`/`getScaledBorrow` expose raw scaled balances so invariant tests
  can assert they sum to the pool totals.
- Interest: 4-bracket kinked rate model (`getBorrowRate`) — unchanged in shape;
  a latent uint16 overflow in the low bracket was fixed (uint32 cast).
- `getValueUSD` returns 18-decimal USD, normalizing feed decimals and token
  decimals separately (`Collateral.feedDecimals` / `tokenDecimals`).
- Constructor takes a single `TokenConfig[] memory configs` (one struct per token)
  instead of six parallel arrays — a mismatched-length constructor error is no
  longer representable. Each `Collateral` now also carries `liquidationThreshold`
  (seize line, percent — must be strictly greater than `ltvRatio`) and
  `liquidationBonusBps` (liquidator discount, capped at `MAX_BONUS_BPS = 2_000`,
  i.e. 20%); the constructor reverts with `Desultory__InvalidRiskParams(token)` if
  either is out of range. `liquidationThreshold` is now consumed by
  `weightedCollateralUSD`/`healthFactor` (below); `liquidationBonusBps` is still
  unread — the liquidation redesign proper is a later task. `getTokenInfo(token)`
  exposes the full `Collateral` struct for a token.
- View caveat: `getPositionBorrowForToken`/`getPositionCollateralForToken`
  read stored indexes — they don't simulate accrual since `lastUpdate`.
- Liquidations: the old `liquidateAssetPosition`/`liquidateProportionalPosition` engine
  is gone, replaced by a single `liquidate(positionId, debtAsset, collateralAsset,
  repayAmount)`. Flow: accrue everything, require `healthFactor < WAD`, resolve `debt`
  in the requested `debtAsset` (`_debtInAsset`), clamp `repayAmount` down to the close
  factor (`LiquidationMath.closeFactorBps(hf)` — a partial-fill clamp, not a revert, so
  a bot that loses a race isn't burning a transaction), convert to a seize amount via
  `LiquidationMath.seizeFromRepay` + `_usdToTokenAmount`. If the position doesn't hold
  that much collateral, seizure is capped at what's there and the repayment is
  **recomputed downward** from the capped seizure (`LiquidationMath.repayFromSeize` +
  `_debtAmountFromUSD`, then re-clamped to `debt` for rounding) — charging the original
  `repayAmount` for a short delivery would be the same class of bug as paying out the
  wrong token. `LiquidationMath.splitBonus` divides the bonus between the liquidator and
  `pool.reserves` (`LIQ_PROTOCOL_SHARE`, 30%). `_seizeCollateral`/`_retireDebt` do the
  effects; the collateral leaves via `safeTransfer` to `msg.sender`, never protocol funds.
  `_debtValueUSD`/`_debtAmountFromUSD` are the forward/inverse pair that value a debt-asset
  amount in USD — DUSD has no `__tokenInfos` entry (no price feed) and is valued at par in
  both directions, matching `userBorrowedAmountUSD`; using the oracle in one direction and
  par in the other would make the back-solve disagree with the health factor.
  After the transfer, `_recordBadDebtIfStranded` checks `userCollateralValueUSD(positionId)
  == 0` (across *all* collateral, not just the asset seized) and, if so, adds whatever debt
  remains to `totalBadDebtUSD` (`BadDebtRecorded` event) — a monotone, never-decremented
  recognition of loss. There is deliberately no `liquidityIndex` writedown anywhere: bad
  debt is counted, never socialized, so `property_indexesNeverDecrease` still holds.
- **DUSD debt** is tracked entirely separately from `__pools` and is never an entry in
  `__tokenList`: `dusdBorrowIndex`, `totalScaledDusdDebt`, `dusdReserves`, and a
  per-position `__scaledDusdDebt`. `borrowDUSD` mints locally, `borrowDUSDTo` sends a
  LayerZero mint authorization instead (both go through `_borrowDusd`, which checks
  ownership, accrues, records the debt and then checks health). `repayDUSD` is
  permissionless and burns the payer's DUSD. `accrueDusd()` applies a flat annual
  `dusdStabilityFeeBps` (default 2%) with the **entire** fee to `dusdReserves` — there
  are no DUSD depositors — and follows the same charge-first discipline as `accrue`.
  Not the kinked curve: nobody deposits DUSD, so utilization would be permanently zero.
- `userBorrowedAmountUSD` adds DUSD debt **at par ($1)** after its per-token loop, so
  every LTV check, `healthFactor` and the NFT transfer gate see it. The par
  assumption is a known hole until the peg is designed — see `docs/Protocol/Cross-Chain.md`.
- Two distinct collateral-weighted views, deliberately separate: `userMaxBorrowValueUSD`
  (LTV-weighted — "may this borrow more?", checked directly by `borrow`/`withdraw`) and
  `weightedCollateralUSD` (liquidation-threshold-weighted — "may this be seized?", feeds
  `healthFactor`). They used to be conflated: `isPositionHealthy` compared debt against
  the LTV-weighted cap, so a position became liquidatable the instant it maxed out its
  borrow capacity, with no buffer. `healthFactor(positionId)` (WAD-scaled, via
  `LiquidationMath.healthFactor`, `type(uint256).max` at zero debt) is now the seize
  signal; `isPositionHealthy` means `healthFactor >= WAD` and is unrelated to remaining
  borrow capacity. Its only caller is `PositionNFT._update`'s transfer gate — a position
  between its LTV cap and its liquidation threshold is deliberately still transferable.
- `Ownable` (added with the cross-chain work; previously there was no access control at
  all). Owner-only: `setAdapter`, `setAllowedDestination(eid, bool)`,
  `setDusdStabilityFee(bps)` (accrues at the old rate first, capped at MAX_BPS).
- No admin/treasury withdrawal yet; `pool.reserves` and `dusdReserves` just accumulate.
  Token add/remove is still ungoverned.

### `src/PositionNFT.sol` — `Position` ERC721
- Token id = position id; minted by Desultory (`deposit(0, …)`). The NFT IS
  the position: transferring it moves collateral + debt control to the buyer.
- `_update` health gate: transfers (not mints) revert while the position is
  liquidatable, i.e. below its liquidation threshold (`Desultory.isPositionHealthy`,
  which now means `healthFactor >= WAD` — see `Desultory.sol` above). `setProtocol`
  wires the Desultory address once, before ownership transfer (see `Deploy.s.sol`).

### `src/DUSD.sol` — protocol stablecoin
- LayerZero V2 **OFT**, constructor `(name, symbol, lzEndpoint, delegate)`. Being an OFT
  is load-bearing: it is what lets a borrower bridge their own DUSD back to the home
  chain and repay there, with no protocol message involved.
- `mint`/`burn` are gated by `isMinter`, an owner-managed allowlist. In a normal
  deployment the minters are `Desultory` (local borrows) and `Adapter` (mints
  authorized from another chain).

### `src/governance/VoteToken.sol` — governance token
- Bare LayerZero OFT. Staking/boosting/slashing from the spec not implemented.

### `src/crosschain/Adapter.sol` — cross-chain adapter
- LayerZero V2 `OApp` carrying DUSD mint authorizations. Symmetric — the same contract
  is deployed on every chain and both sends and receives. `quoteMint` prices a message;
  `sendMint` is restricted to the configured `desultory`; `_lzReceive` decodes
  `(recipient, amount)` and mints.
- **`_lzReceive` must never be able to revert** — no pause flag, allowlist, supply cap or
  `require`. The debt is already recorded on the source chain when it runs, and a
  permanent revert would strand the message with a borrower owing DUSD they never
  received. Every check lives on the send side.
- Peer configuration is the entire trust boundary: a compromised Adapter on any chain can
  mint unlimited DUSD, spendable everywhere. See `docs/Decisions/0003-dusd-only-cross-chain-borrowing.md`.

### `src/libraries/OracleLib.sol`
- Wraps Chainlink `latestRoundData` with a 3-hour staleness revert. All USD valuation
  in Desultory goes through this via `getValueUSD`.

### `script/` — deployment
- `Config.s.sol`: per-network addresses; deploys `MockV3Aggregator` + `MockERC20`
  (WETH 18 dec, USDC 8 dec) and a real `EndpointV2Mock` on Anvil, exposing `lz` and
  `eid`. The endpoint's owner must be the address actually performing the CREATE (the
  broadcaster, read back via `vm.readCallers`), because its constructor registers its
  blocked message library through an `onlyOwner` path.
- `Deploy.s.sol`: deploys Position, DUSD, Desultory from a `Desultory.TokenConfig[]`
  built via `configs.push(...)`: WETH (feed 18 dec, LTV 70, threshold 75, bonus
  1_000 bps, rate 400) and USDC (feed 8 dec, LTV 85, threshold 90, bonus 500 bps,
  rate 200); both mock tokens are 18-dec ERC20s. `tokenAddresses`/`priceFeedAddresses`
  are still populated (from the same values) purely so `getAddrI`/`getFeedI` keep
  working for tests. Calls `position.setProtocol(desultory)` then
  transfers Position ownership to Desultory, then deploys the `Adapter` and wires it:
  `adapter.setDesultory`, `dusd.setMinter(desultory|adapter)`, `desultory.setAdapter`.
  Peers and allowed destinations are deliberately **not** set — a single-chain local
  deploy has no peer. Reads `PRIVATE_KEY` env var; every `Ownable` is owned by
  `vm.addr(deployerKey)`.

### `src/libraries/LiquidationMath.sol` — liquidation arithmetic, storage-free
- Pure functions only, unit-agnostic (caller passes both operands in the same unit):
  `healthFactor` (threshold-weighted collateral over debt, WAD-scaled, max at zero
  debt), `closeFactorBps`, `seizeFromRepay`/`repayFromSeize`, `splitBonus`. Exists
  apart from `Desultory.sol` so this arithmetic — where most of the old engine's
  defects lived — is unit-testable without standing up the whole protocol. Every
  function is now wired into `Desultory.liquidate` (see `src/Desultory.sol` above).

### `test/`
- `Desultory.t.sol` — 51 tests: deposit/withdraw/borrow/repay on the positionId
  API, interest accrual & lender yield (incl. 10% reserve check), NFT-transfer
  control handoff, unhealthy-transfer gating, health-factor semantics (threshold-
  vs LTV-weighted, the buffer band between them), scaled-getter reconstruction,
  stateless fuzz invariants for the rounding/solvency policy, the ownership
  surface and DUSD debt accounting, risk-parameter storage and constructor
  validation (`liquidationThreshold`/`liquidationBonusBps`), and the `liquidate()`
  engine — bonus payout, close-factor clamping, event emission, allowance/authorization
  reverts, accrue-before-evaluate ordering, seizure clamped to held collateral with the
  repayment back-solved down to match, and `totalBadDebtUSD` recognition (and
  non-recognition when collateral remains).
- `LiquidationMath.t.sol` — 10 unit and fuzz tests for the library above.
- `Position.t.sol` — 7 unit tests for mint auth, `setProtocol` wiring, and the
  health-gated `_update` hook (via a stub protocol).
- `DUSD.t.sol` — minter gating on `mint`/`burn`, owner gating on `setMinter`, and that
  the OFT base is wired.
- `crosschain/` — two-chain tests built on LayerZero's `TestHelperOz5`.
  `Adapter.t.sol` covers messaging in isolation, including that the receive path mints
  for a recipient with no position and no history. `CrossChainBorrow.t.sol` is the full
  flow: deposit on A → DUSD minted on B, over-LTV and disallowed-destination borrows
  reverting *before* any message is sent, and bridging DUSD home with the OFT's own
  `send()` to repay locally.
- `recon/` — **Chimera stateful fuzzing harness**, driven by both Medusa and Echidna
  from one scaffold (`Setup` → `BeforeAfter` → `Properties` → `TargetFunctions` →
  `CryticTester`/`CryticToFoundry`). Three borrower actors plus a fourth, `liquidator`,
  that never opens a position (funded and approved, only ever calls `liquidate`).
  Clamped targets over deposit/withdraw/borrow/repay/liquidate plus time warps and wide
  oracle price movement. Also drives `borrowDUSD`/`repayDUSD`. Asserts eleven
  internal-consistency invariants: the original eight plus three liquidation properties
  (bad debt is monotone, a healthy position is never liquidatable, and the liquidator is
  never worse off than what they paid, checked against `LiquidationMath` directly rather
  than through a full liquidation). Economic solvency is deliberately not asserted, and a
  property that liquidation improves health factor is deliberately NOT asserted (paying a
  bonus can make HF worse by design). Prose statement of the invariants is in
  `docs/Audit/Invariants.md`; the reasoning is ADR 0002. `AccrualLeak.t.sol` is the
  regression test for the accrual bug this harness found. A Medusa run after adding
  `liquidate` to the target surface found `property_borrowIndexOutpacesLiquidityIndex`
  (pre-existing, not one of the three new properties) failing: `_seizeCollateral` moved a
  pool's `totalScaledDeposits` with no `getAvailableLiquidity`-style bound, unlike
  `withdraw`/`borrow`, so a liquidation could seize collateral in a token pool that is
  also heavily borrowed elsewhere and push that pool's debt above its deposits. Fixed by
  folding the same `getAvailableLiquidity` bound into `liquidate()`'s existing seizure
  clamp (`src/Desultory.sol`); regression test
  `testSeizureIsBoundedByAvailableLiquidity` in `test/Desultory.t.sol`. See
  `.superpowers/sdd/2026-09-12-liquidation-engine/task-7-report.md`.
