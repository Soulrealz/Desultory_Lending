# Next Steps

Cold-start handoff. Read this first, then `PROJECT_CONTEXT.md` for the module map and
`docs/` for the vault. Written 2026-09-22 against commit `8b72802` on `master`.

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

**Tasks 1–8 are self-contained — you can finish them without the user.** Tasks 9 onward are
architectural and need design decisions that are not yours to make alone: brainstorm them
with the user rather than implementing on assumption. If you reach task 9 with time left,
stop and ask rather than guessing.

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
| C2.2 | DUSD supply caps | not started |
| C2.3 | The `dusdReserves` outlet | not started |
| D2.3 | External liquidation backstop (flash loan) | not started |
| D3 | ElizaOS automation | not started |
| — | Governance | not started |
| — | Token add/remove admin | not started |

**Baseline, verified at `8b72802`:**

| Gate | Command (from `onchain/ethereum/`) | Result |
|---|---|---|
| Unit tests | `PRIVATE_KEY=0xac09... forge test` | **123 passing**, 9 suites, 0 failed |
| Medusa | `medusa fuzz --test-limit 50000` | **26 passed, 0 failed** |
| Echidna | `echidna . --contract CryticTester --config echidna.yaml --test-limit 30000` | **27/27** |
| Size | `forge build --sizes` | `Desultory` **18,277** of 24,576 |

Nothing is red. Treat a green fuzz run as "not found at this limit" rather than "proved" —
see task 7 and the lesson recorded in [[Invariants]].

---

# Self-contained tasks

## 1. Correct invariant 3's justification in `Properties.sol`

**Bounded. Smallest task here — do it first.**

`test/recon/Properties.sol`'s comment on `property_borrowIndexOutpacesLiquidityIndex` still
reads:

> debt can never exceed deposits, and the reserve factor removes 10% from the lender side
> before liquidityIndex grows, so borrow growth strictly dominates.

Both halves are now wrong. ADR 0008 changed the cut to round **up**, so it removes *at least*
10% and in a dust pool removes 100% of a 1-wei interest; and the `totalDeposits` divisor now
ceilings too, which is the other half of what makes the property hold. Worse, "debt can never
exceed deposits" was the premise that the ADR 0008 reproductions falsified at dust scale.

This comment is not decoration — ADR 0008's whole lesson is that this justification was
load-bearing code, and it went stale the moment the code was fixed. Rewrite it to state what
actually holds now.

**Acceptance:** comment matches `accrue()`. No code change, no test change. Suite still 123.

## 2. Retire the "~10% deficit" framing where it is still asserted

**Bounded.**

Several notes claim `property_borrowIndexOutpacesLiquidityIndex` needs roughly a 10% deficit
(`0.9B > D`) to trip. ADR 0008's second reproduction inverts the indexes at a **zero**
deficit — `deposits == debt == 3` scaled — so that framing is false as a general statement.

It survives in `docs/Protocol/Liquidations.md` and `docs/Audit/Invariants.md`, which are
editable, and in `docs/Decisions/0004-liquidation-engine.md` and
`docs/Decisions/0006-internal-liquidation-backstop.md`, which are **accepted ADRs and must
not be edited**. Correct the Protocol and Audit notes; for the two ADRs, add a pointer from
the Protocol notes saying the framing in them is superseded by ADR 0008 rather than touching
them.

Check whether the wei-scale seizure seam's "still harmless" argument, which leans on that
figure, still stands once restated. Say so either way.

**Acceptance:** no editable document asserts the ~10% bound as a general rule; ADRs 0004 and
0006 untouched; `verified-against` bumped on any Protocol note you change.

## 3. Extract the third copy of the DUSD retirement arithmetic

**Bounded.**

`_retireDusdDebt`'s natspec says it exists so `repayDUSD` and redemption retire debt through
identical arithmetic. But `_retireDebt`'s DUSD branch in `src/Desultory.sol` is still a
verbatim third inline copy, used by `liquidate` when `debtAsset == DUSD`. The comment already
admits this and points at it; the extraction was deliberately deferred out of a redemption
branch.

Behaviour is identical today, so this is a maintenance hazard rather than a bug — which means
the test to watch is that **nothing changes**. Every existing DUSD and liquidation test must
pass untouched; if one needs editing, the extraction was not behaviour-preserving.

**Acceptance:** one helper, three callers, comments updated to stop describing a third copy.
Suite still 123, all DUSD/liquidation tests unedited.

## 4. Audit `verified-against` drift across the vault

**Bounded.**

Protocol notes carry `verified-against:` frontmatter naming the commit they were checked
against. Several are behind — some were bumped to a commit that could not contain its own
hash, and the accrual work touched `Accounting.md`'s subject matter.

Go note by note: read what it claims, check it against the code at `HEAD`, fix what is stale,
and bump the hash only for notes you actually re-verified. **Do not bump a hash you did not
check** — a wrong `verified-against` is worse than an old one, because it claims a
verification that never happened.

**Acceptance:** every note in `docs/Protocol/` either re-verified and bumped, or left alone
with a note in your commit message about why.

## 5. Token add/remove admin

**Bounded-to-architectural — read the design question before deciding.**

`grep -c "function addToken" src/Desultory.sol` → 0. The supported-asset set is fixed at
deployment: the constructor is the only writer of `__tokenInfos`. The June assessment named
this alongside reserve withdrawal as a single gap; ADR 0005 closed only the reserve half and
said so.

Adding a token is straightforward. **Removing one is the design question**: what happens to
open positions holding that asset as collateral, or owing it as debt? Options range from
"removal only blocks new deposits/borrows, existing positions unwind naturally" to a full
wind-down path. The first is probably right and is much smaller — but make the argument
rather than assuming it, and write the ADR.

Note the constructor validates risk parameters (`liquidationThreshold <= 100`, bonus caps);
any `addToken` must apply the same validation, and ADR 0008's safety argument leans on that
bound holding for every listed token.

**Acceptance:** ADR, tests for add and for whichever removal semantics you argued for, fuzz
surface extended if the target set grows.

## 6. Size `_commitBackstop` against what it removes, not the pool's deficit

**Bounded, but touches reviewed liquidation machinery — be careful.**

`_commitBackstop(token, want)` sizes its commit as `need = debt + want - deposits`, which in a
saturated pool is dominated by the pool's own deficit rather than by `want`. A caller
requesting a tiny seizure or redemption can therefore convert a large slice of
`pool.reserves` into `backstopScaledDeposits`, which `releaseBackstop` cannot recover while
the pool stays saturated.

The zero-value case is already guarded (C2.1's final review added `removed == 0` → revert),
and the natspec no longer claims commits are self-limiting. What remains is the non-dust
shape. This was parked deliberately: fixing it means changing sizing logic that liquidation
depends on, which did not belong in a redemption branch. It belongs in its own.

Both `liquidateWithBackstop` and `redeemWithBackstop` call it. Any change must keep both
working and must not weaken `property_custodyReconciles`, whose argument for the backstop is
that deposits and reserves move together with cash untouched.

**Acceptance:** a test showing a small request commits proportionally rather than draining;
both backstop paths still pass; Medusa and Echidna green.

## 7. Make the backstop and clamp paths actually fuzz-reachable

**Bounded. This is the task that buys the most confidence per line.**

Two known coverage holes, both recorded in [[Invariants]]:

- `desultory_redeemWithBackstop`'s real call fired **zero** times across 300,000 Medusa
  calls. Four preconditions must align — healthy position, has DUSD debt, holds that
  collateral, pool short enough to need the backstop — and the last two pull against each
  other. That path is covered by four unit tests and nothing else.
- Neither redemption clamp is reachable: both redemption target functions bound input with
  `between(amount, 1, min(debt, balance))`, which can never exceed the debt, so the
  clamp-to-debt branch and its re-clamp are never executed by the fuzzer.

Do **not** relax the `healthFactor >= WAD` gate to raise the hit rate — that gate is the
feature. The honest fixes are to let the amount bound exceed the debt sometimes, and to add a
target function that deliberately drives a pool into the short state so the backstop
precondition can be met.

Also: **lcov line coverage is unreliable on this harness** — it has reported non-zero hits on
lines after a zero-hit call site, which is impossible if the mapping were accurate. Use
counter instrumentation if you need to prove reachability, and delete it before committing.

**Acceptance:** evidence (a counter or a trace, not lcov) that both paths execute under
Medusa, with the figures in your commit or report.

## 8. Fix `desultory_releaseBackstop`'s bound

**Bounded. Small.**

That target function bounds its amount from a snapshot taken **before** the call, but
`releaseBackstop` runs `accrue(token)` first. Accrual grows `borrowIndex` faster than
`liquidityIndex`, so post-accrual availability is *smaller* than the figure the bound was
computed against, and the call reverts `Desultory__InsufficientLiquidity` whenever the pool
has accrued since last touched. The release path is therefore fuzzed far less than its
presence in the target list suggests.

Re-derive the bound so it holds after the accrual the call itself performs.

**Acceptance:** evidence the target function actually succeeds under Medusa rather than
mostly reverting.

---

# Needs the user — brainstorm, do not implement on assumption

Stop here and ask before starting any of these. Each one is a design with real trade-offs,
and the project's convention is `superpowers:brainstorming` → spec → `writing-plans` → build.

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
   unexplained `-1`, which is why it was left. See task 2 about its "harmless" argument.
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
