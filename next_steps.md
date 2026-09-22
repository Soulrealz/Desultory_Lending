# Next Steps

Cold-start handoff. Read this first, then `PROJECT_CONTEXT.md` for the module map and
`docs/` for the vault. Written 2026-09-22 against commit `8b72802` on `master`; updated the
same day against `810fbeb` on branch `backlog-tasks-1-8`, which is **unmerged** — tasks 1–8
below are done and sitting on that branch awaiting the user's PR.

## How to work this list

You are picking up a clean session with a backlog. The operating contract:

- **Work one task at a time, in order.** Finish a task — code, tests, docs, commit — before
  starting the next. Do not batch several tasks into one commit.
- **At most 5 subagents.** Use them where they genuinely help (an implementer plus a
  reviewer per task is a good shape); do not fan out wider than that.
- **`git add` and `git commit` only. Never push, never merge, never open a PR.** Integration
  is the user's, and they do it by PR from a branch.
- **Work on one branch for the batch.** Create it off `master` before task 1 —
  `git checkout -b <something-descriptive>` — and commit each task onto it. The user merges
  when they are ready.
- **Commit messages are short one-liners** with only relevant info. No attribution trailers,
  no `Co-Authored-By`, no model names, no emoji. Examples from the log:
  `add owner-gated reserve withdrawal`, `put the backstop on the fuzzing surface`,
  `round the reserve cut up so dust pools cannot invert the indexes`.
- **Pick your own approach.** Subagent-driven development, plain TDD, whatever fits the
  task's size. Small doc fixes do not need a spec and a plan; a new subsystem does.

**Tasks 1–8 were self-contained and are now done.** Tasks 9 onward are
architectural and need design decisions that are not yours to make alone: brainstorm them
with the user rather than implementing on assumption. Start by asking, not guessing.

## Where the project is

**Desultory Lending** is an over-collateralized, cross-chain lending protocol. Positions are
NFTs; collateral and debt live on one home chain; only DUSD crosses chains.

| Project | What it was | State |
|---|---|---|
| A | Obsidian vault (`docs/`) | done |
| B | Chimera stateful fuzzing harness (`test/recon/`) | done |
| C | Cross-chain DUSD borrowing over LayerZero V2 | done |
| D1 | Liquidation engine rewrite | done |
| D2.1 | Treasury slice: owner-gated reserve withdrawal | done — ADR 0005 |
| D2.2 | Internal liquidation backstop | done — ADR 0006 |
| C2.1 | DUSD redemption (the peg floor) | done — ADR 0007 |
| — | Dust-scale accrual rounding in `accrue()` | done — ADR 0008 |
| — | Token add/remove admin | done — ADR 0009 |
| — | Harness reachability (stale feeds, clamps, release bound) | done |
| C2.2 | DUSD supply caps | not started |
| C2.3 | The `dusdReserves` outlet | not started |
| D2.3 | External liquidation backstop (flash loan) | not started |
| D3 | ElizaOS automation | not started |
| — | Governance | not started |

**Baseline, verified at `810fbeb`:**

| Gate | Command (from `onchain/ethereum/`) | Result |
|---|---|---|
| Unit tests | `PRIVATE_KEY=0xac09... forge test` | **141 passing**, 10 suites, 0 failed |
| Medusa | `medusa fuzz --test-limit 50000` | **28 passed, 0 failed** |
| Echidna | `echidna . --contract CryticTester --config echidna.yaml --test-limit 30000` | **29 passing, 0 failed** |
| Size | `forge build --sizes` | `Desultory` **20,244** of 24,576 |

Nothing is red. Treat a green fuzz run as "not found at this limit" rather than "proved" —
and note that the old counts above meant even less than that: `warp` was leaving both price
feeds stale, so most targets reverted for the rest of every sequence and the campaigns were
green largely because nothing was executing. Fixed; measurements in [[Invariants]]. The
contract also grew 18,277 -> 20,244 with the listing admin, leaving ~4.3k of headroom
before EIP-170 — worth watching, since D2.3 is the largest remaining piece.

---

# Done on `backlog-tasks-1-8` (was tasks 1-8)

Seven commits, oldest first. Every accepted ADR 0001-0008 is byte-identical to `master`.

1. `002be53` — invariant 3's justification in `Properties.sol` rewritten around what
   actually holds: distribution is gated on `interest > 0`, the ceiling cut withholds at
   least a wei, the divisor ceilings. Retracts "debt can never exceed deposits" explicitly.
2. `8b9fbba` — the "~10% deficit" framing retired from `Liquidations`, `Invariants` and
   `Accounting`; ADRs 0004 and 0006 left alone with a "Superseded framings" pointer added
   instead. The wei-scale seam's "still harmless" conclusion **survives** restatement, but
   the reason changes, and it no longer generalizes to a dust-scale pool — said so in place.
3. `edaa61a` — `_retireDebt`'s DUSD branch routed through `_retireDusdDebt`. All existing
   DUSD and liquidation tests passed **unedited**.
4. `75a8b7f` — all seven `docs/Protocol/` notes re-verified claim by claim against the code
   and bumped. Real drift found, including: `Accounting`'s mermaid diagram encoded the
   *pre-fix* leaky accrual order; `Interest-Rate-Model`'s curve table gave segment rates as
   if they were the rate at each breakpoint (actual: 3/8/36/66%); `Oracles` claimed every
   state-changing function stops on a dead feed (deposit and repay do not).
5. `7150e66` — ADR 0009, `addToken` / `setTokenRetired`, 16 tests, fuzz target. Retirement
   is **not** removal: the list never shrinks, because every health computation iterates it.
6. `8847270` — `_commitBackstop`. See the note below; this one did not go as the task
   described.
7. `810fbeb` — the stale-feed hole and the reachability work (old tasks 7 and 8, landed
   together because `warp` was the shared root cause of both).

**Task 6 did not confirm its own premise, and the record should say so.** The backlog
described a tiny request converting a large slice of reserves into unrecoverable
`backstopScaledDeposits`. Two corrections. The deficit term is **forced**: availability *is*
`deposits - debt`, so a commit that does not clear the shortfall first unlocks nothing, and
no sizing both serves the caller and skips it. And the zero-benefit case **already
self-healed**: when reserves cannot cover the deficit the caller clamps to zero and reverts
`Desultory__ZeroAmount`, which unwinds the commit with it. The guard added is defence in
depth, labelled as such in the code, the test and the note — its regression test passes with
it removed, and says so. What is pinned instead is the true statement: nothing above the
deficit is spent except `want`.

# Needs the user — brainstorm, do not implement on assumption

Stop here and ask before starting any of these. Each one is a design with real trade-offs,
and the project's convention is `superpowers:brainstorming` → spec → `writing-plans` → build.
These keep their original numbers; there are no self-contained tasks left above them.

## 9. C2.2 — DUSD supply caps

A global ceiling on DUSD minting, enforced **send-side only**. ADR 0003 forbids any check in
`Adapter._lzReceive` permanently — the debt is already recorded on the source chain by the
time it runs, so a revert there strands a borrower owing DUSD they never received. Every
safety check belongs where reverting is free.

Open questions: global cap or per-position, who sets it, how it interacts with the peg now
that redemption exists.

## 10. C2.3 — the `dusdReserves` outlet

ADR 0005 deferred this here, and C2.1 unblocked it *in principle* by creating a DUSD →
collateral route. But paying protocol revenue out still means minting DUSD against no new
collateral, which now dilutes redemption backing rather than nothing. That is the design
problem, and it is not obviously solvable by minting.

## 11. D2.3 — the external liquidation backstop

The last and largest piece of D2: flash-loan the shortfall from Uniswap or Aave when the pool
genuinely holds nothing and internal reserves cannot cover it. The protocol's first real
external integration, with an untrusted venue's callback re-entering mid-liquidation. Note
`nonReentrant` sits on the `liquidate`/`redeem` wrappers and never on the private
`_liquidate`/`_redeem`.

## 12. D3 — ElizaOS automation

README Path B, the 0–4.9% / 5% band split. Mostly an off-chain agent plus a permissioned
entry point; the band structure is the documented extension point.

## 13. Governance

`src/governance/VoteToken.sol` is 13 lines — a bare OFT. Staking, boosting and slashing are
all unimplemented. Greenfield, nothing depends on it.

---

# Parked — real, small, none urgent

1. **Wei-scale seizure seam.** `getAvailableLiquidity` is computed in token units while
   `_seizeCollateral` converts with `__toScaledUp`, so a seizure that exactly saturates the
   cap can leave a pool 1–2 wei short. The backstop path meets that precondition on every
   call rather than occasionally. Documented in [[Liquidations]]; the obvious patch is an
   unexplained `-1`, which is why it was left. Its "harmless" argument was restated (commit
   `8b9fbba`) and still holds, but on the reserve cut's headroom rather than on a deficit
   threshold — and it no longer carries to a dust-scale pool. See [[Liquidations]].
2. **`totalBadDebtUSD` double-count.** `deposit()` is permissionless, so a stranded position
   can be re-collateralized and re-strand, crediting the same debt twice. A recognition-flag
   mapping was deliberately not added because it changes accounting semantics with no test
   designed for it.
3. **The redemption fee is rarely paid to the borrower.** A rational redeemer always picks
   `redeemWithBackstop`, since the net receipt is identical and it moves the fee to reserves.
   The fairness argument for caller-chosen targets is weaker in practice than ADR 0007
   claims — which ADR 0007 now says.
4. **Self-redemption on the backstopped path is a liquidity queue-jump** around the
   availability bound, for 0.5%. Recorded in ADR 0007 as an accepted consequence.

---

# How to work in this repo

**Build and test.** Foundry project is at `onchain/ethereum/`. Dependencies are NOT vendored
— see `onchain/ethereum/README.md` and install into the gitignored `lib/` with
`forge install ... --no-git` (`--no-commit` no longer exists in Foundry 1.x).

```
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 forge test
```

That key is the public Anvil account-0 key, not a secret. Every `forge` command needs it.

**Fuzzing**, from `onchain/ethereum/`:

```
medusa fuzz --test-limit 50000
echidna . --contract CryticTester --config echidna.yaml --test-limit 30000
```

`forge build --sizes` exits non-zero with an EIP-3860 initcode error for `CryticTester`. That
is pre-existing and benign — the harness is only ever deployed by Medusa and Echidna in their
own EVM, which does not enforce the limit. Do not chase it.

**Conventions that bite if ignored:**

- Line endings are LF, enforced by `.gitattributes`. Never commit CRLF.
- **Rounding always favors the pool.** Deposits round down, debts round up. Four private
  helpers enforce it: `__toScaledDown`, `__toScaledUp`, `__fromScaledDown`, `__fromScaledUp`.
  Any new scaled conversion must state its direction and why. ADR 0008 is what happens when
  one of them points the wrong way.
- **Accrual discipline.** `accrue()` and `accrueDusd()` charge borrowers FIRST and distribute
  exactly what was charged. Do not derive a notional interest figure separately from the
  index update — that bug leaked interest and was found by the fuzzer. Both roundings in the
  distribution step now ceiling, and both are load-bearing (ADR 0008). Change this function
  only with a root-caused reason and a regression test.
- **`Adapter._lzReceive` must never be able to revert.** No pause flag, no allowlist, no
  supply cap, no `require`. Debt is already recorded on the source chain when it runs.
- **No `liquidityIndex` writedown.** Bad debt is counted, never socialized. A decreasing
  index breaks `property_indexesNeverDecrease`.
- **Do not weaken a fuzzing invariant** to make a run go green. Extending a property with an
  additional known term is fine; loosening a bound is not. This harness is three for three on
  real defects in reviewed, merged code.
- `docs/superpowers/` and `.superpowers/` are gitignored — specs, plans and subagent scratch
  live there but are never committed.

**Documentation upkeep is mandatory** (see `CLAUDE.md`): `PROJECT_STRUCTURE.md` when files
move, `PROJECT_CONTEXT.md` when core logic changes, and the `docs/` vault when *behavior*
changes. Protocol notes carry `verified-against:` frontmatter naming the commit they were
checked against — bump it after committing, and only if you actually checked. Accepted ADRs
are never edited; supersede them with a new record that links back.

# Map of the vault

- `docs/Protocol/` — what the protocol does, per module. Maintained. `Accounting`,
  `Interest-Rate-Model`, `Positions`, `Oracles`, `Liquidations`, `Cross-Chain`, `DUSD`.
- `docs/Decisions/` — numbered ADRs. `0001` NFT-as-position, `0002` internal-consistency
  invariants, `0003` DUSD-only cross-chain, `0004` liquidation engine, `0005` treasury
  withdrawal, `0006` internal backstop, `0007` DUSD redemption, `0008` accrual roundings.
- `docs/Audit/` — `Invariants.md` (the twelve fuzzing properties in prose, plus what the
  harness has caught) and the June project assessment.
- `docs/Notes/` — scratch. Makes no accuracy claim.
