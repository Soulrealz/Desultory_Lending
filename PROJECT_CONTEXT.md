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
- View caveat: `getPositionBorrowForToken`/`getPositionCollateralForToken`
  read stored indexes — they don't simulate accrual since `lastUpdate`.
- Liquidations (`liquidateAssetPosition`, `liquidateProportionalPosition`):
  **still known-broken**, only mechanically re-pointed at the new storage;
  redesign is assessment point 4. Untested on purpose.
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
  every LTV check, `isPositionHealthy` and the NFT transfer gate see it. The par
  assumption is a known hole until the peg is designed — see `docs/Protocol/Cross-Chain.md`.
- `Ownable` (added with the cross-chain work; previously there was no access control at
  all). Owner-only: `setAdapter`, `setAllowedDestination(eid, bool)`,
  `setDusdStabilityFee(bps)` (accrues at the old rate first, capped at MAX_BPS).
- No admin/treasury withdrawal yet; `pool.reserves` and `dusdReserves` just accumulate.
  Token add/remove is still ungoverned.

### `src/PositionNFT.sol` — `Position` ERC721
- Token id = position id; minted by Desultory (`deposit(0, …)`). The NFT IS
  the position: transferring it moves collateral + debt control to the buyer.
- `_update` health gate: transfers (not mints) revert while the position is
  liquidatable (`Desultory.isPositionHealthy`). `setProtocol` wires the
  Desultory address once, before ownership transfer (see `Deploy.s.sol`).

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
- `Deploy.s.sol`: deploys Position, DUSD, Desultory with WETH (feed 18 dec, LTV 70,
  rate 400) and USDC (feed 8 dec, LTV 85, rate 200); both mock tokens are 18-dec
  ERC20s (`tokenDecimals = [18, 18]`). Calls `position.setProtocol(desultory)` then
  transfers Position ownership to Desultory, then deploys the `Adapter` and wires it:
  `adapter.setDesultory`, `dusd.setMinter(desultory|adapter)`, `desultory.setAdapter`.
  Peers and allowed destinations are deliberately **not** set — a single-chain local
  deploy has no peer. Reads `PRIVATE_KEY` env var; every `Ownable` is owned by
  `vm.addr(deployerKey)`.

### `test/`
- `Desultory.t.sol` — 33 tests: deposit/withdraw/borrow/repay on the positionId
  API, interest accrual & lender yield (incl. 10% reserve check), NFT-transfer
  control handoff, unhealthy-transfer gating, scaled-getter reconstruction, and
  stateless fuzz invariants for the rounding/solvency policy, plus the ownership
  surface and DUSD debt accounting. Liquidation paths
  remain untested on purpose.
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
  `CryticTester`/`CryticToFoundry`). Three actors, clamped targets over
  deposit/withdraw/borrow/repay plus time warps and wide oracle price movement.
  Also drives `borrowDUSD`/`repayDUSD`. Asserts eight internal-consistency invariants
  (the last two covering DUSD supply-vs-authorization and scaled DUSD debt reconciliation); economic solvency is deliberately not
  asserted, and liquidation entry points are absent from the target surface. Prose
  statement of the invariants is in `docs/Audit/Invariants.md`; the reasoning is ADR
  0002. `AccrualLeak.t.sol` is the regression test for the accrual bug this harness
  found.
