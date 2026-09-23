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
  (RESERVE_FACTOR), the rest grows the liquidity index. Both roundings in that
  split turn toward the pool — the cut ceilings and the deposit-base divisor
  ceilings — and that is load-bearing, not cosmetic (ADR 0008). Rounding always
  favors the pool (deposits round down, debts round up). `accrue` charges borrowers **first**
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
  is gone, replaced by a private `_liquidate(positionId, debtAsset, collateralAsset,
  repayAmount, bool useBackstop)` behind two `nonReentrant` wrappers, `liquidate(...)` and
  `liquidateWithBackstop(...)` (identical argument lists). Flow: accrue everything, require `healthFactor < WAD`, resolve `debt`
  in the requested `debtAsset` (`_debtInAsset`), clamp `repayAmount` down to the close
  factor (`LiquidationMath.closeFactorBps(hf)` — a partial-fill clamp, not a revert, so
  a bot that loses a race isn't burning a transaction), convert to a seize amount via
  `LiquidationMath.seizeFromRepay` + `_usdToTokenAmount`. If the position doesn't hold
  that much collateral, seizure is capped at what's there and the repayment is
  **recomputed downward** from the capped seizure (`LiquidationMath.repayFromSeize` +
  `_debtAmountFromUSD`, then re-clamped to `debt` for rounding) — charging the original
  `repayAmount` for a short delivery would be the same class of bug as paying out the
  wrong token. `LiquidationMath.splitBonus` divides the bonus between the liquidator and
  `pool.reserves` (`LIQ_PROTOCOL_SHARE`, 30%, or `LIQ_BACKSTOP_SHARE`, 70%, on the
  backstop path). `_seizeCollateral`/`_retireDebt` do the
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
- **Internal backstop** (`useBackstop = true`): `getAvailableLiquidity` is
  `max(0, deposits - debt)`, i.e. `max(0, cash - reserves)` under the custody identity, so
  it under-reports spendable cash by `min(reserves, cash)` — and a pool sits with deposits
  below debt after every accrual. `_commitBackstop(token, want)`, called from `_liquidate`
  after `seizeCap` is clamped to held collateral and the requested amount, and before
  `getAvailableLiquidity` is re-read fresh, converts up to `pool.reserves` into
  `pool.backstopScaledDeposits` (a SUBSET of `totalScaledDeposits`, not a position, so
  `withdraw()` cannot reach it). Sized off the **raw** deposits/debt figures as
  `deficit + want`, credit rounds down, reserves fall by the exact round-trip; no token
  moves, so custody holds by construction. The deficit term is forced, not slack:
  availability *is* `deposits - debt`, so a commit that does not clear the shortfall first
  unlocks nothing. Nothing above the deficit is spent except `want`, and a commit that
  would still land at or below the deficit is refused outright (defence in depth — the
  callers' zero-fill revert already unwound it). See ADR 0006 and the "Commit sizing"
  section of `docs/Protocol/Liquidations.md`. **`_commitBackstop` has two callers**: `_liquidate` and `_redeem` — the
  redemption path funds a cash-poor pool through exactly the same machinery, sized to the
  collateral the redemption may remove. `releaseBackstop(token, amount)` (owner-only) is the mirror: accrues,
  mirrors `withdraw()`'s shape, gates on `getAvailableLiquidity` (unlike `withdrawReserves`
  — it lowers deposits against fixed reserve backing), and returns the deposit plus its
  earned interest to `pool.reserves`, keeping `withdrawReserves` the single exit. Events
  `BackstopCommitted`/`BackstopReleased`. A wei-scale rounding seam is routine on this path
  rather than rare — documented, not fixed; see `docs/Protocol/Liquidations.md` and ADR 0006.
- **DUSD debt** is tracked entirely separately from `__pools` and is never an entry in
  `__tokenList`: `dusdBorrowIndex`, `totalScaledDusdDebt`, `dusdReserves`, and a
  per-position `__scaledDusdDebt`. `borrowDUSD` mints locally, `borrowDUSDTo` sends a
  LayerZero mint authorization instead (both go through `_borrowDusd`, which checks
  ownership, accrues, records the debt and then checks health). `repayDUSD` is
  permissionless and burns the payer's DUSD. `accrueDusd()` applies a flat annual
  `dusdStabilityFeeBps` (default 2%) with the **entire** fee to `dusdReserves` — there
  are no DUSD depositors — and follows the same charge-first discipline as `accrue`.
  Not the kinked curve: nobody deposits DUSD, so utilization would be permanently zero.
- **DUSD redemption** (`redeem` / `redeemWithBackstop`, thin `nonReentrant` wrappers over
  private `_redeem(..., bool useBackstop)` — the same arrangement `liquidate` uses). A
  redeemer burns DUSD and receives collateral worth the same USD less a flat
  `REDEMPTION_FEE_BPS` (50 = 0.5%), taken from a caller-chosen position whose DUSD debt is
  cancelled **at par**. The gate is the exact **inverse** of `liquidate`'s:
  `healthFactor >= WAD`, else `Desultory__NotRedeemable` — healthy positions are
  redeemable and always improved by a redemption, unhealthy ones are liquidatable, and the
  two engines partition the book with no overlap. The collateral leg reuses
  `_seizeCollateral` and the debt leg `_retireDusdDebt` (extracted from `repayDUSD` so both
  retire DUSD debt through identical arithmetic, which is what makes
  `property_dusdDebtReconciles` hold by construction). The fee is never a separate
  transfer: it is the difference between the DUSD burned and the collateral paid out. On
  the ordinary path only the net figure leaves the position, so the fee stays there as
  collateral it no longer owes debt against; on the backstopped path the gross figure
  leaves and the remainder is booked to `pool.reserves`, because the protocol supplied the
  liquidity via `_commitBackstop` (redemption is that function's **second** caller). The
  redeemer's take is the net figure either way, so the arbitrage threshold stays a single
  number. A redemption whose collateral figure floors to zero reverts
  `Desultory__ZeroAmount` before `_commitBackstop` is reached, so a dust call cannot
  convert reserves into `backstopScaledDeposits` for a delivery of nothing. Event
  `Redemption`. See ADR 0007 and `docs/Protocol/DUSD.md`.
- `userBorrowedAmountUSD` adds DUSD debt **at par ($1)** after its per-token loop, so
  every LTV check, `healthFactor` and the NFT transfer gate see it. That par convention is
  deliberately **unchanged** by the redemption work: redemption is what now *enforces* it,
  since below $0.995 buying DUSD and redeeming it is profitable and burns supply until the
  discount closes. Only its comment changed. It is a floor, not a band — nothing caps DUSD
  above $1, and supply caps (C2.2) are not built. See `docs/Protocol/DUSD.md`.
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
- `withdrawReserves(token, to, amount)` (owner-only) pays out a pool's accumulated revenue —
  the RESERVE_FACTOR interest cut plus LIQ_PROTOCOL_SHARE of liquidation bonuses. It accrues
  first and needs no liquidity gate: the balance and `pool.reserves` fall by the same amount,
  so the custody identity holds by construction. `dusdReserves` is deliberately NOT
  withdrawable — it is a claim, not a balance (DUSD is minted to borrowers and burned from
  payers, never held here), so paying it out would mint unbacked supply. See ADR 0005.
- `releaseBackstop(token, amount)` (owner-only) returns committed backstop capital to
  `pool.reserves` — see the liquidation backstop above. It moves no tokens; cash still
  leaves only through `withdrawReserves`.
- `addToken(TokenConfig)` / `setTokenRetired(token, bool)` (owner-only) are the listing
  admin. Both the constructor and `addToken` go through one private `_listToken`, so the
  risk-parameter validation and the `MAX_SUPPORTED_TOKENS = 32` cap are shared rather than
  duplicated — `liquidationThreshold <= 100` is quantified over every listed token by ADR
  0007's and ADR 0008's safety arguments. `addToken` also rejects a duplicate, the zero
  address, a zero feed, and DUSD (which is debt-only and would otherwise get a second
  accounting path through `__pools`).
  Retirement is **not** removal: `__tokenList` never shrinks and `__tokenInfos` is never
  cleared, because every health computation iterates that list and dropping an entry would
  make an open position's collateral *and* debt in that asset vanish from the sum at once.
  A `notRetired` modifier gates exactly two entry points — `deposit` and `borrow` — so new
  exposure stops while every unwind path (withdraw, repay, liquidate, redeem, release,
  withdrawReserves) stays open. Reversible both ways. Backed by `__retiredTokens` as a side
  mapping, so `getTokenInfo`'s ABI is unchanged. See ADR 0009.

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

### `src/libraries/RedemptionMath.sol` — redemption fee arithmetic, storage-free
- Two pure, unit-agnostic functions forming an inverse **pair**, kept adjacent for the
  reason ADR 0004 gives about `LiquidationMath`: a disagreeing inverse pair is the defect
  class the old liquidation engine was full of. `collateralFromDusd` (USD of collateral for
  a DUSD burn, net of the fee) rounds **down**; `dusdFromCollateral` (the inverse) rounds
  **up**, because the inverse is only ever used to recompute a *capped* figure downward and
  rounding it down there would hand out free collateral on every partial fill. Both
  directions favour the pool, per the protocol's rounding policy.

### `src/libraries/LiquidationMath.sol` — liquidation arithmetic, storage-free
- Pure functions only, unit-agnostic (caller passes both operands in the same unit):
  `healthFactor` (threshold-weighted collateral over debt, WAD-scaled, max at zero
  debt), `closeFactorBps`, `seizeFromRepay`/`repayFromSeize`, `splitBonus`. Exists
  apart from `Desultory.sol` so this arithmetic — where most of the old engine's
  defects lived — is unit-testable without standing up the whole protocol. Every
  function is now wired into `Desultory.liquidate` (see `src/Desultory.sol` above).

### `test/`
- `Desultory.t.sol` — 84 tests: deposit/withdraw/borrow/repay on the positionId
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
- `TokenAdmin.t.sol` — 16 tests for `addToken`/`setTokenRetired`: the validation surface,
  the 32-token cap on both the constructor and `addToken`, that a freshly listed pool
  charges no interest for time before it was listed, and the load-bearing one — a retired
  asset's position reports a bit-identical health factor and still repays, withdraws and
  liquidates.
- `LiquidationMath.t.sol` — 10 unit and fuzz tests for the library above.
- `RedemptionMath.t.sol` — 5 unit and fuzz tests for the fee pair, including
  `testFuzzRoundTripNeverFavorsTheRedeemer`.
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
  Clamped targets over deposit/withdraw/borrow/repay/liquidate/redeem plus time warps and
  wide oracle price movement. Also drives `borrowDUSD`/`repayDUSD`. Asserts twelve
  internal-consistency invariants: the original eight, three liquidation properties and
  the backstop subset property
  (bad debt is monotone, a healthy position is never liquidatable, and the liquidator is
  never worse off than what they paid, checked against `LiquidationMath` directly rather
  than through a full liquidation). Economic solvency is deliberately not asserted, and a
  property that liquidation improves health factor is deliberately NOT asserted (paying a
  bonus can make HF worse by design). Prose statement of the invariants is in
  `docs/Audit/Invariants.md`; the reasoning is ADR 0002. Redemption is asserted
  **in-target** rather than as a property (`dusdBurned >= USD value of collateral the
  redeemer received`): the spec's "redemption never lowers the target's health factor"
  turned out to be unassertable, because `redeem` accrues internally so a before/after
  comparison charges realized interest to the redemption. `warp` was found to be leaving BOTH price feeds stale
  (`OracleLib.TIMEOUT` is 3 hours, `MAX_WARP` is 30 days), so almost every price-reading
  target — borrow, repay, withdraw, redeem, liquidate — reverted for the rest of each
  sequence: the campaigns were green largely because nothing was executing. `warp` now
  re-posts each feed's current answer, price untouched. With that fixed, redemption target
  selection was tightened, the redemption amount bound raised to the redeemer's balance so
  `_redeem`'s two clamp branches are reachable, `desultory_saturatePool` was added to drive
  a pool short on purpose, and `desultory_releaseBackstop`'s bound was re-derived to survive
  the accrual the call itself performs. Measurements and the before/after counters are in
  `docs/Audit/Invariants.md`; read that before trusting any campaign count.
  `property_borrowIndexOutpacesLiquidityIndex` failed under Medusa on `master` and is
  **fixed** by ADR 0008 (both accrual roundings now turn toward the pool). `AccrualLeak.t.sol` is the
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
