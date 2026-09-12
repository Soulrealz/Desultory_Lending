---
status: accepted
date: 2026-09-12
---

# 0002 — Fuzz for internal consistency, not economic solvency

## Status

Accepted.

## Context

Before this, the protocol's only property tests were two `testFuzz*` functions in
`Desultory.t.sol`. Those are **stateless** Foundry fuzz tests: one bounded call
against fresh state, repeated with different inputs. They cannot find anything that
requires a *sequence* — an index that drifts after forty interleaved operations, a
rounding error that only compounds.

That is the class of bug the cross-chain work will introduce, because it moves storage
around underneath accounting that currently works. A regression net built afterwards
is a test suite; built beforehand, it is the thing that tells you the rewrite broke
something.

The open question was what to assert. The obvious candidate — the protocol is never
underwater, total collateral USD ≥ total debt USD — is a property this protocol does
not currently have. With no working liquidation engine (see [[Liquidations]]), a large
enough price drop makes it genuinely insolvent. Asserting solvency would mean either
failing constantly and correctly, or clamping price movement so narrowly that the
fuzzer stops exercising anything interesting.

## Decision

Assert **internal-consistency** invariants only — properties of the bookkeeping that
hold regardless of market conditions. See [[Invariants]] for the six.

Consequences of that choice:

- **Price movement can be wide** (0.01×–100× of the initial feed answer), because
  every invariant survives the protocol going economically underwater.
- **Bad debt is recorded, not flagged.** It is the known-missing engine, not a bug.
- **Liquidation entry points are excluded from the target surface.** Not by config —
  they are simply never written, so there is nothing to accidentally re-enable.
- **Both Medusa and Echidna** run the same Chimera scaffold. This earned its keep
  immediately: the accrual bug below was found by Medusa at 20k calls and missed by
  Echidna at 5k.

## Consequences

**Two production changes were required.**

`getScaledDeposit` and `getScaledBorrow` were added to `Desultory`. The per-position
scaled balances are private with no getters, so the "scaled balances reconcile"
invariant was simply unassertable. Reading storage slots with `vm.load` was rejected:
any future storage reordering would silently turn the invariant into a tautology, and
a test that passes because it reads the wrong slot is worse than no test.

`OracleLib`'s functions moved from `public` to `internal`. Public library functions
make the library a separate deployment requiring bytecode linking, which Echidna
refuses to do. As a side effect this removes a `DELEGATECALL` from every price read.

**The harness found a real bug on its first campaign.** `accrue()` was charging
borrowers and paying lenders from two different numbers, so the pool could distribute
more than it took in. Documented in [[Accounting]] and reproduced by
`test/recon/AccrualLeak.t.sol`. This is the justification for the whole ordering
decision — it was sitting in working, tested, reviewed code, and only a long random
sequence surfaced it.

**Solvency becomes assertable once liquidations exist.** At that point it is a
property the protocol is supposed to have, and a ghost bad-debt counter makes the
combined approach worthwhile. That is deliberately left for Project D.

## Alternatives considered

**Economic-solvency invariants.** Rejected: asserts a property the system does not
have, and forces price clamping narrow enough to stop testing anything.

**Include liquidations in the target surface.** Rejected: the seven documented defects
would flood every run, drowning other findings in known noise until the engine is
rewritten.

**Tolerance-based comparison of unscaled balances**, to avoid adding getters.
Rejected: tolerance hides exactly the small compounding drift the harness exists to
catch — and in the event, the real bug was a few hundred thousand wei against totals
of 1e23, which any sane tolerance would have swallowed.

## Related

- [[Invariants]] — the six properties in prose
- [[Accounting]] — the accrual bug this found, and the fix
- [[Liquidations]] — why that surface is excluded
