# Next Steps

Cold-start handoff. Read this first, then `PROJECT_CONTEXT.md` for the module map and
`docs/` for the vault. Written 2026-09-19, last updated against commit `7f90054` on `d2-internal-backstop`.

## START HERE

**Brainstorm D2's external liquidation backstop** — flash-loaning the shortfall from an
outside venue (Uniswap, Aave) to cover a liquidation. That is the next piece of work, and
it has not been started — no spec, no plan, no code.

The **internal** half is done and merged (ADR 0006). The protocol can now fund a seizure
from its own reserves when the pool reports no available liquidity but is in fact holding
cash. What it still cannot do is fund one when the pool holds nothing — that needs
outside capital, and that is this piece.

Invoke `superpowers:brainstorming` with it. Classify it **architectural**, not bounded: it
adds the protocol's first real external integration, with an untrusted venue in the middle
of a liquidation, so it gets the full path — questions, approaches, a sectioned design, a
written spec, then `superpowers:writing-plans`.

Read `## Do this next` below before asking the first question. Skim
`docs/Protocol/Liquidations.md` (the "Internal backstop" section and Known limitations) and
`docs/Decisions/0006-internal-liquidation-backstop.md` first — the external half sits on
top of the internal one, and arriving without that context wastes the first few questions.

Spec and plan paths follow the user's global convention:

```
docs/superpowers/specs/liquidations/<Month_YYYY>/YYYY-MM-DD-external-backstop-design.md
docs/superpowers/plans/liquidations/<Month_YYYY>/YYYY-MM-DD-external-backstop.md
```

Note `docs/superpowers/` is gitignored, so those two files live on disk but are never
committed. Everything else in `docs/` is tracked and must be.

Do not start implementing before the user approves the design. Do not touch `accrue()`, do
not weaken a fuzzing invariant, and do not write down `liquidityIndex` — see
`## How to work in this repo`.

## Where the project is

**Desultory Lending** is an over-collateralized lending protocol. Four decomposed
projects were planned; all four are now merged:

| Project | What it was | State |
|---|---|---|
| A | Obsidian vault (`docs/`) | done |
| B | Chimera stateful fuzzing harness (`test/recon/`) | done |
| C | Cross-chain DUSD borrowing over LayerZero V2 | done |
| D1 | Liquidation engine rewrite | done — merged 2026-09-13 |
| D2.1 | Treasury slice: owner-gated reserve withdrawal | done — merged 2026-09-19 |
| D2.2 | Internal liquidation backstop (reserves fund the seizure) | done — merged 2026-09-19 |
| D2.3 | External liquidation backstop (flash loan) | **next — not started** |

The June 2026 assessment's "suggested order of attack" (`docs/Audit/2026-06-10-project-assessment.md`)
is fully worked through. What remains are the D follow-ons, the DUSD peg, governance,
and the admin gap described below.

Baseline: **103 tests passing** across 8 suites. `Desultory` runtime 17,080 bytes
(limit 24,576). Medusa 24/24 and Echidna 25/25 green.

## Do this next: D2's external backstop

### Why this and not something else

D1 shipped a documented hole: a liquidation can fail against a genuinely liquidatable
position because the collateral pool has no liquidity to give up. The internal backstop
(ADR 0006) closed the half of that hole the protocol could close on its own — reserves
are now converted into a protocol-owned deposit so a seizure can proceed against cash the
availability view does not report. That still leaves the case where the pool genuinely
holds nothing, and no amount of internal bookkeeping fixes it. That case needs outside
capital.

It is also the last piece of D2, and it is the largest one: the protocol's first real
external integration. Every other open item (below) is either blocked on a design that
does not exist yet or is cosmetic next to a liquidation that cannot execute.

### What the external backstop has to settle

- **Which venue, and how it is trusted.** Uniswap V3 flash swaps and Aave V3
  `flashLoanSimple` have different callback shapes, different fees and different failure
  modes. The callback re-enters this contract mid-liquidation, which is the whole design
  problem — note that `nonReentrant` currently sits on the two `liquidate` wrappers and
  never on `_liquidate`.
- **Where the borrowed cash lands in the accounting.** The internal backstop moves no
  tokens, so custody holds by construction. A flash loan really does move tokens in and
  out inside one call, so `property_custodyReconciles` and `property_tokenConservation`
  both have something to say about it, and the ghost counters in the harness will need to
  see the round trip.
- **What the liquidator is paid.** The internal path inverts the split to
  `LIQ_BACKSTOP_SHARE` (70% to the protocol) because the protocol carries the liquidity
  risk. A flash loan carries a fee instead of a risk, so the split is a different
  question — "a partial reward" in the README is not a number.
- **Whether it is a third entry point.** The internal one is deliberately opt-in so nobody
  is silently paid a worse split (ADR 0006, decision 4). The same argument probably
  applies, but it has to be made rather than assumed.
- **What happens when the venue reverts or the swap is unprofitable.** The internal path
  degrades to ordinary `liquidate()` behavior. State the degradation rather than
  inheriting it by accident.

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
- **Token add/remove admin.** `grep -c "function addToken" src/Desultory.sol` → 0, so the
  supported-asset set is fixed at deployment. Named alongside reserve withdrawal as a
  single gap in the June assessment; only the reserve half is closed. Has its own design
  question — what happens to open positions in a removed asset.

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
  `0004` liquidation engine, `0005` treasury withdrawal, `0006` internal liquidation
  backstop.
- `docs/Audit/` — `Invariants.md` (the twelve fuzzing properties in prose) and the June
  project assessment.
- `docs/Notes/` — scratch. Makes no accuracy claim.
