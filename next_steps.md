# Next Steps

Cold-start handoff. Read this first, then `PROJECT_CONTEXT.md` for the module map and
`docs/` for the vault. Written 2026-09-19, against commit `9652fd5` on `master`.

## Where the project is

**Desultory Lending** is an over-collateralized lending protocol. Four decomposed
projects were planned; all four are now merged:

| Project | What it was | State |
|---|---|---|
| A | Obsidian vault (`docs/`) | done |
| B | Chimera stateful fuzzing harness (`test/recon/`) | done |
| C | Cross-chain DUSD borrowing over LayerZero V2 | done |
| D1 | Liquidation engine rewrite | done — merged 2026-09-13 |

The June 2026 assessment's "suggested order of attack" (`docs/Audit/2026-06-10-project-assessment.md`)
is fully worked through. What remains are the D follow-ons, the DUSD peg, governance,
and the admin gap described below.

Baseline: **82 tests passing** across 8 suites. `Desultory` runtime 15,549 bytes
(limit 24,576). Medusa and Echidna campaigns green.

## Do this next: D2, starting with the treasury slice

### Why this and not something else

D1 shipped a documented hole. Liquidation pays the liquidator in underlying tokens, so
`safeTransfer` reverts when the pool is cash-poor — and seizure is additionally bounded by
`getAvailableLiquidity`, so it can partially fill or become unavailable outright. That is
the one scenario where liquidation matters most, and right now it degrades there. Every
other open limitation is cosmetic next to it. See **Known limitations** in
`docs/Protocol/Liquidations.md`.

D2 as the README decomposes it has two halves:

- **Internal backstop** — the protocol covers the liquidation from its own funds when it
  has them, taking a larger share of the reward.
- **External backstop** — the protocol flash-loans from an outside venue (Uniswap, Aave)
  to cover, taking a partial reward.

**The internal half is blocked on plumbing that does not exist**, which is why the
treasury slice comes first.

### The treasury gap, and why D1 made it worse

There is **no way to withdraw `reserves` or `dusdReserves`**, and no owner function for it.
The only three owner-gated functions on `Desultory` are `setAdapter`,
`setAllowedDestination` and `setDusdStabilityFee` — all cross-chain config.

Value now accrues to reserves from three places:

| Source | Line | Rate |
|---|---|---|
| Borrow interest | `Desultory.sol:1074` | `RESERVE_FACTOR` = 10% of interest |
| DUSD stability fee | `Desultory.sol:628` | 100% of the fee (no DUSD depositors to share with) |
| Liquidation bonus | `Desultory.sol:587` | `LIQ_PROTOCOL_SHARE` = 30% of every bonus |

Before D1 there were two streams. D1 added the third. The protocol accumulates from all
three and can release none of it — the value is permanently stuck, and an internal
backstop cannot be specified until reserves are addressable.

There is also still no token add/remove admin (`grep -c "function addToken" src/Desultory.sol`
→ 0), so the supported-asset set is fixed at deployment. That is a separate gap; do not
fold it in unless the design turns out to need it.

### Suggested shape

1. **Treasury slice** (small, unblocks the rest): owner-gated withdrawal of `reserves`
   per token and of `dusdReserves`, with the accounting care the rest of this contract
   uses — withdrawing reserves must not let the pool's cash drop below what depositors
   and borrowers are owed. `property_custodyReconciles` in `test/recon/Properties.sol`
   is the invariant that pins this; it must still hold.
2. **Internal backstop**: liquidation draws on reserves when the pool lacks cash, with a
   larger protocol share of the bonus as the README specifies.
3. **External backstop**: flash-loan adapters. Largest piece, real external integrations,
   worth its own spec.

Brainstorm before coding — this is architectural, not bounded.

## Alternatives, if the above is wrong for you

- **C2 — DUSD peg, redemption, supply caps.** `userBorrowedAmountUSD` values DUSD debt at
  $1 on an assumption with no mechanism behind it, and D1's liquidation trigger now
  inherits it: an unpegged DUSD means positions are seized at the wrong threshold.
  Real, but blocks nothing.
- **D3 — ElizaOS automation.** README Path B and the 0–4.9% / 5% band split. Mostly an
  off-chain agent plus a permissioned entry point; the band structure is the documented
  extension point.
- **Governance.** `src/governance/VoteToken.sol` is a bare OFT. Staking, boosting,
  slashing all unimplemented. Greenfield; nothing depends on it.

## Parked from D1 — small, none urgent

All three are recorded in `docs/Protocol/Liquidations.md` and ADR 0004:

1. **Wei-scale rounding seam.** `getAvailableLiquidity` is computed in token units while
   `_seizeCollateral` converts with `__toScaledUp` (rounds up), so a seizure that exactly
   saturates the availability cap can leave a pool's deposits 1–2 wei below its debt.
   Cannot trigger `property_borrowIndexOutpacesLiquidityIndex` (that needs a ~10% deficit).
   The obvious patch is an unexplained `-1`, which is why it was left.
2. **`totalBadDebtUSD` double-count.** `deposit()` is permissionless, so a stranded
   position can be re-collateralized and re-strand, crediting the same debt twice.
   Documented only; a recognition-flag mapping was deliberately not added because it
   changes accounting semantics with no test designed for it.
3. **A history bullet** in Liquidations.md's Known limitations reads better in ADR 0004,
   which already records it.

## How to work in this repo

**Build and test.** Foundry project is at `onchain/ethereum/`. Dependencies are NOT
vendored — see `onchain/ethereum/README.md` and install into the gitignored `lib/` with
`forge install ... --no-git` (note: `--no-commit` no longer exists in Foundry 1.x).

```
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 forge test
```

That key is the public Anvil account-0 key, not a secret. Every `forge` command needs it.

**Fuzzing**, from `onchain/ethereum/`:

```
medusa fuzz --test-limit 50000
echidna . --contract CryticTester --config echidna.yaml --test-limit 30000
```

`forge build --sizes` exits non-zero with an EIP-3860 initcode error for `CryticTester`.
That is pre-existing and benign — the fuzz harness is only ever deployed by Medusa and
Echidna in their own EVM, which does not enforce the limit. Do not chase it.

**Conventions that bite if ignored:**

- Line endings are LF, enforced by `.gitattributes`. Never commit CRLF.
- **Rounding always favors the pool.** Deposits round down, debts round up. Four private
  helpers enforce it: `__toScaledDown`, `__toScaledUp`, `__fromScaledDown`, `__fromScaledUp`.
  Any new scaled conversion must state its direction and why.
- **Accrual discipline.** `accrue()` and `accrueDusd()` charge borrowers FIRST and
  distribute exactly what was charged. Do not derive a notional interest figure separately
  from the index update — that bug leaked interest and was found by the fuzzer. See
  `docs/Protocol/Accounting.md` and `test/recon/AccrualLeak.t.sol`.
- **`Adapter._lzReceive` must never be able to revert.** No pause flag, no allowlist, no
  supply cap, no `require`. Debt is already recorded on the source chain when it runs.
- **No `liquidityIndex` writedown.** Bad debt is counted, never socialized. A decreasing
  index breaks `property_indexesNeverDecrease`.
- `docs/superpowers/` is gitignored — specs and plans live there but are not tracked.

**Documentation upkeep is mandatory** (see `CLAUDE.md`): `PROJECT_STRUCTURE.md` when files
move, `PROJECT_CONTEXT.md` when core logic changes, and the `docs/` vault when *behavior*
changes. Protocol notes carry `verified-against:` frontmatter naming the commit they were
checked against — bump it after committing. Accepted ADRs are never edited; supersede them
with a new record that links back.

**Commits.** Short one-liners. No attribution trailers, no co-authored-by, no model names.
Examples from the log: `rewrite the liquidation engine`, `update docs`,
`cross chain DUSD borrowing over LZ V2`.

## Map of the vault

- `docs/Protocol/` — what the protocol actually does, per module. Maintained.
  `Accounting`, `Interest-Rate-Model`, `Positions`, `Oracles`, `Liquidations`, `Cross-Chain`.
- `docs/Decisions/` — numbered ADRs. `0001` NFT-as-position, `0002` internal-consistency
  invariants (superseded in part by `0004`), `0003` DUSD-only cross-chain borrowing,
  `0004` liquidation engine.
- `docs/Audit/` — `Invariants.md` (the eleven fuzzing properties in prose) and the June
  project assessment.
- `docs/Notes/` — scratch. Makes no accuracy claim.
