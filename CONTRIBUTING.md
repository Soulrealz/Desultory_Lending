# Contributing

How to build, verify and change this repo, and the rules that are easy to break by
accident. Read [`README.md`](README.md) first for what the project is, and
[`docs/Protocol/Architecture.md`](docs/Protocol/Architecture.md) for how it fits together.

## Toolchain

| Tool | Version in use |
|---|---|
| Foundry (`forge`) | 1.5.1 |
| solc | 0.8.28 (pinned in `foundry.toml`) |
| Medusa | 1.5.1 |
| Echidna | 2.3.3 |

Dependencies are not vendored. Install them into the gitignored `lib/` as described in
[`onchain/ethereum/README.md`](onchain/ethereum/README.md). Use `--no-git`, because
`--no-commit` no longer exists in Foundry 1.x.

## Verification gates

All from `onchain/ethereum/`. Every `forge` command needs `PRIVATE_KEY` set. Any key works;
the one below is Anvil's public account-0 key.

| Gate | Command | Must be |
|---|---|---|
| Unit tests | `PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 forge test` | 0 failed |
| Medusa | `medusa fuzz --test-limit 50000` | 0 failed |
| Echidna | `echidna . --contract CryticTester --config echidna.yaml --test-limit 30000` | 0 failed |
| Size | `forge build --sizes` | `Desultory` under 24,576 bytes (EIP-170) |

`forge build --sizes` exits non-zero with an EIP-3860 initcode error for `CryticTester`.
That is expected, since the harness is only deployed inside the fuzzers. Do not chase it.
`Desultory` is around 20.5k, so check the size after any sizeable change.

A green fuzz run means "nothing found at this limit", not "proved". Both fuzzers keep a
corpus between runs, and a warm corpus can reach states a cold one does not. Say which you
used when you report a number. Counterexamples replay as Foundry tests via
`test/recon/CryticToFoundry.sol`.

## Rules that bite if ignored

- **Rounding always favours the pool.** Deposits round down, debts round up. Four private
  helpers enforce it: `__toScaledDown`, `__toScaledUp`, `__fromScaledDown`,
  `__fromScaledUp`. Any new scaled conversion must state its direction and why. ADR 0008 is
  what happens when one points the wrong way.
- **Accrual discipline.** `accrue()` and `accrueDusd()` charge borrowers first and hand out
  exactly what was charged. Never compute a notional interest figure separately from the
  index update: that bug leaked interest and was found by the fuzzer. Both roundings in the
  split ceiling, and both matter (ADR 0008). Change this code only with a root-caused reason
  and a regression test.
- **Inverse pairs stay adjacent and agree.** Forward/inverse conversions
  (`seizeFromRepay`/`repayFromSeize`, `collateralFromDusd`/`dusdFromCollateral`,
  `_debtValueUSD`/`_debtAmountFromUSD`) must use the same pricing in both directions. A
  disagreeing pair is the defect class the old liquidation engine was full of.
- **`Adapter._lzReceive` must never be able to revert.** No pause flag, allowlist, supply
  cap or `require`. The debt is already recorded on the source chain when it runs. Every
  check belongs on the send side.
- **No `liquidityIndex` writedown.** Bad debt is counted, never spread across depositors.
  A decreasing index breaks `property_indexesNeverDecrease`.
- **Tokens are never removed from the list,** only retired. Every health computation
  iterates it (ADR 0009).
- **Do not weaken a fuzzing invariant** to make a run go green. Adding a known term to a
  property is fine; loosening a bound is not. This harness has found real bugs in reviewed,
  merged code three times.
- **Line endings are LF,** enforced by `.gitattributes`. Never commit CRLF.

## Workflow

- **Branch off `master`, merge by PR.** One branch per piece of work. Do not push to
  `master`.
- **Commit messages are one short line** saying what changed and why it mattered, in lower
  case. No trailers, no `Co-Authored-By`, no tool or model names, no emoji. From the log:
  `add owner-gated reserve withdrawal`,
  `round the reserve cut up so dust pools cannot invert the indexes`.
- **One task, one commit or a small series.** Code, tests and docs for a change land
  together.
- **Design before building anything with trade-offs.** A new subsystem gets a design
  discussion, then a spec, then a plan, then code. Specs and plans go in `docs/superpowers/`,
  which is gitignored. The decision itself becomes an ADR, which is committed. Small fixes
  need none of this.

## Documentation upkeep

Do this at the end of every change, before committing:

1. **`PROJECT_STRUCTURE.md`** — update when files or directories are added, removed,
   renamed or moved.
2. **`PROJECT_CONTEXT.md`** — update when core logic (contracts, libraries, deploy scripts,
   test infrastructure) is added or rewritten. Keep it a rough map; skip minor changes.
3. **The vault (`docs/`)** — update when **behaviour** changes:
   - Update the module's note in `docs/Protocol/` and set `verified-against:` in its
     frontmatter to the commit you checked it against. Only bump it if you actually checked.
   - Record a design decision as a numbered ADR in `docs/Decisions/`. An accepted ADR is
     never edited to reflect a changed mind; write a new one that supersedes it and links
     back.
   - Fixing or finding a weakness means updating `docs/Audit/Known-Issues.md`.
   - `docs/Notes/` is scratch and never required.
   - Use wikilinks (`[[Note Name]]`) for internal links and Mermaid for diagrams.

If a change touched neither structure nor behaviour, leave the docs alone.
