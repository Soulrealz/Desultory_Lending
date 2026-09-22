# Next Steps

Cold-start handoff. Read this first, then `PROJECT_CONTEXT.md` for the module map and
`docs/` for the vault. Written 2026-09-19, last updated against commit `2502b9a` on branch `c2-dusd-redemption`.

## START HERE

**Brainstorm D2's external liquidation backstop** — flash-loaning the shortfall from an
outside venue (Uniswap, Aave) to cover a liquidation when the pool genuinely holds nothing.
It has not been started: no spec, no plan, no code. See `## Do this next` below.

The accrual failure that stood here is **fixed** — see the next section. Nothing is
currently red.

### The accrual bug that was here, and what closed it

`property_borrowIndexOutpacesLiquidityIndex` was failing on `master`, in shipped code. It
is fixed by [[0008-reserve-cut-rounds-up]] and Medusa is green again.

Root cause worth remembering, because it is the most instructive defect this project has
produced: **the invariant's own justification was load-bearing code.** `Properties.sol`
justifies the property by saying the reserve factor removes 10% from the lender side on
every accrual, so borrow growth dominates. But `toReserves = interest * 1_000 / 10_000`
*floored*, so for any `interest` below 10 wei it removed **nothing** — and in a dust-scale
pool one wei of ceiling-manufactured interest then moved `liquidityIndex` by `1/51` while
the genuine rate moved `borrowIndex` by a third of that. The indexes inverted on a single
accrual.

The fix is two lines, both in the same three-line distribution step: the reserve cut now
ceilings, and so does the `totalDeposits` divisor. The second was found **in review, after
the first was committed and Medusa was already green** — a reviewer constructed a state at
`deposits == debt == 3` scaled where the floored divisor sat 25% below its true base and
tripled `liquidityIndex` in one accrual. Both have regression tests beside the original
accrual-leak test. Medusa went from 25 passed / 1 failed to **26 passed / 0 failed** — which
is worth reading as "not found at this limit" rather than "proved", given how the second
defect surfaced.

That makes the Chimera harness **three for three** on real defects in reviewed, merged
code, and for the first time all three are closed. Evidence for the original finding:
`.superpowers/sdd/2026-09-19-dusd-redemption/evidence/`.

## Where the project is

**Desultory Lending** is an over-collateralized lending protocol. Four decomposed projects
were planned and all four are merged; their follow-on slices are tracked here too:

| Project | What it was | State |
|---|---|---|
| A | Obsidian vault (`docs/`) | done |
| B | Chimera stateful fuzzing harness (`test/recon/`) | done |
| C | Cross-chain DUSD borrowing over LayerZero V2 | done |
| D1 | Liquidation engine rewrite | done — merged 2026-09-13 |
| D2.1 | Treasury slice: owner-gated reserve withdrawal | done — merged 2026-09-19 |
| D2.2 | Internal liquidation backstop (reserves fund the seizure) | done — merged 2026-09-19 |
| D2.3 | External liquidation backstop (flash loan) | not started |
| C2.1 | DUSD redemption (the peg floor) | done — this branch |
| C2.2 | DUSD supply caps | not started |
| C2.3 | The `dusdReserves` outlet | not started — unblocked in principle by C2.1 |
| — | Dust-scale accrual rounding in `accrue()` | fixed — ADR 0008 (two roundings) |

The June 2026 assessment's "suggested order of attack" (`docs/Audit/2026-06-10-project-assessment.md`)
is fully worked through. What remains are the D follow-ons, the rest of the DUSD peg,
governance and the admin gap described below.

Baseline: **123 tests passing** across 9 suites. `Desultory` runtime 18,277 bytes
(limit 24,576). Medusa **26 passed, 0 failed** at `--test-limit 50000`; Echidna **27/27**
at `--test-limit 30000`. Nothing is red.

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
external integration. Every other item below is either blocked on a design that does not
exist yet or is cosmetic next to a liquidation that cannot execute.

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

- **C2 — DUSD peg: supply caps (C2.2) and the reserves outlet (C2.3).** The previous
  edition of this file called C2 "real, but blocks nothing". **That was wrong**, and the
  correction is worth stating rather than quietly deleting: C2 blocks `dusdReserves`
  withdrawal outright (ADR 0005 deferred that outlet to this project by name) and it
  underpins the liquidation trigger for **every DUSD borrower**, since `healthFactor`
  divides by a `userBorrowedAmountUSD` that values DUSD at par. A drift mis-prices the
  seizure line in both directions: below $1 positions are seized early, above $1
  under-collateralized positions read as healthy and the protocol accrues bad debt it never
  recognizes.

  **C2.1 is now done** — redemption (ADR 0007) puts a floor under DUSD so arbitrage
  enforces par rather than the contract assuming it. What remains:
  **C2.2 supply caps**, since nothing bounds how much DUSD can be minted and redemption is
  one-sided (a floor, not a ceiling); and **C2.3, the `dusdReserves` outlet**, now
  unblocked *in principle* because a DUSD-to-collateral route exists, though paying it out
  still means minting against no new collateral — which now dilutes redemption backing
  rather than nothing at all, a sharper objection than 0005's rather than a weaker one.
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

All three are recorded in `docs/Protocol/Liquidations.md` and ADR 0004; item 1 is also
recorded in ADR 0006, which corrects its scope:

1. **Wei-scale rounding seam — now routine on the backstop path.** `getAvailableLiquidity`
   is computed in token units while `_seizeCollateral` converts with `__toScaledUp`
   (rounds up), so a seizure that exactly saturates the availability cap can leave a
   pool's deposits 1–2 wei below its debt. D1 met that precondition only occasionally.
   `liquidateWithBackstop` sets the seizure cap to exactly the availability it just
   unlocked, so it meets it on **every** call, and the commit's own down-rounding adds a
   second floor in the same direction. Observed: a deterministic 2-wei shortfall against
   a ~449,740-token pool. Still harmless, though the "needs a ~10% deficit" framing that
   used to justify that is now known to be wrong — ADR 0008's second reproduction inverts
   the indexes at a **zero** deficit. `getUtilization` clamps at `MAX_BPS`, and
   `property_custodyReconciles` is a `gte` the shortfall moves in the safe direction —
   and still not worth the unexplained `-1` that would fix it. See ADR 0006's
   Consequences and `testBackstopLeavesDepositsCoveringDebtWithinRoundingDust`.
2. **`totalBadDebtUSD` double-count.** `deposit()` is permissionless, so a stranded
   position can be re-collateralized and re-strand, crediting the same debt twice.
   Documented only; a recognition-flag mapping was deliberately not added because it
   changes accounting semantics with no test designed for it.
3. **A history bullet** in Liquidations.md's Known limitations reads better in ADR 0004,
   which already records it.

## Parked from C2.1 — recorded, not fixed

1. **The backstopped redemption path is effectively unfuzzed.**
   `desultory_redeemWithBackstop`'s real call fired **zero** times across 300,000 Medusa
   calls — four preconditions must align and the last two pull against each other. It rests
   on four unit tests. `desultory_redeem` fired 14 times at 50k. Do not read the headline
   fuzzer counts as coverage of redemption. The preconditions are not relaxable: the
   `healthFactor >= WAD` gate *is* the feature.
2. **The in-target redemption assertion has a known blind spot.**
   `dusdBurned >= getValueUSD(collateralAsset, received)` catches the redeemer being
   over-paid, not debt being under-cleared relative to the collateral removed. The latter is
   covered only by `testRedeemImprovesTheTargetHealthFactor` as a unit test. The obvious
   property — "redemption never lowers the target's health factor" — is **unassertable in
   this harness**, because `redeem` accrues internally so a before/after comparison charges
   realized interest to the redemption. Do not re-add it; see `docs/Audit/Invariants.md`.
3. **`lcov` line coverage on the recon harness is unreliable.** It reported non-zero hits on
   lines after a zero-hit call site. Use counter instrumentation instead.


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
  `Accounting`, `Interest-Rate-Model`, `Positions`, `Oracles`, `Liquidations`, `Cross-Chain`,
  `DUSD` (the stablecoin's whole lifecycle, including redemption).
- `docs/Decisions/` — numbered ADRs. `0001` NFT-as-position, `0002` internal-consistency
  invariants (superseded in part by `0004`), `0003` DUSD-only cross-chain borrowing,
  `0004` liquidation engine, `0005` treasury withdrawal, `0006` internal liquidation
  backstop, `0007` DUSD redemption.
- `docs/Audit/` — `Invariants.md` (the twelve fuzzing properties in prose, the in-target
  redemption assertion, the redemption coverage limitations, and the failing property
  above) and the June project assessment.
- `docs/Notes/` — scratch. Makes no accuracy claim.
