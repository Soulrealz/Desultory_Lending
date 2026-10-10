---
status: accepted
date: 2026-10-10
---

# 0010 — DUSD issuance is bounded by a debt ceiling per home chain

## Status

Accepted.

## Context

Nothing bounded how much DUSD the protocol could issue. A borrower with enough collateral
could mint any amount, and total DUSD exposure grew without anyone deciding it should.
While the protocol is young that is the wrong default: issuance should grow at a pace
someone chose. This record adds a **risk limit** and nothing else.

## What this is not

**Not a peg mechanism.** A ceiling restricts minting, and when DUSD trades above par,
minting is what pulls it back down. A binding ceiling pushes the price *further* above par
— MakerDAO's debt ceilings did exactly this to DAI. The above-par lever is the stability
fee (`setDusdStabilityFee`): cheaper borrowing raises supply. The below-par direction is
held by redemption, [[0007-dusd-redemption]]. The ceiling does neither job and must not be
described as doing either.

**Not a defence against a compromised Adapter.** A bad peer mints through `DUSD.mint` on
the receive side without touching any `Desultory`, so a home-chain ceiling never sees it.
[[0003-dusd-only-cross-chain-borrowing]]'s statement that the adapter set is the entire
trust boundary stands unchanged.

## The constraint that decides the shape

A truly global ceiling cannot be enforced send-side. Every chain runs its own `Desultory`
as a home chain, and `DUSD.totalSupply()` on any one chain is only that chain's share — an
OFT transfer burns on one chain and mints on another. Enforcing a global figure would need
a cross-chain round-trip before every borrow, the asynchronous shape ADR 0003 rejected; a
receive-side check is forbidden outright.

What a home chain *does* know exactly is how much DUSD debt it issued, wherever the tokens
were minted. That is what is capped. A global figure is the owner keeping per-chain
ceilings that sum to it.

## Decision

- **One ceiling per home chain**, `dusdDebtCeiling` on `Desultory`, set by the owner with
  `setDusdDebtCeiling`. No change to `Adapter` or `DUSD`.
- **Counts total DUSD debt including accrued stability fee** —
  `__fromScaledUp(totalScaledDusdDebt, dusdBorrowIndex)`, exposed as `getTotalDusdDebt()`.
  That is what borrowers owe, which is the exposure a risk limit bounds.
- **Checked in `_borrowDusd`**, after the debt is recorded and before the health check, on
  the post-borrow total, strict `>`. Both `borrowDUSD` and `borrowDUSDTo` route through it,
  so it is send-side by construction and fires before any LayerZero message is attempted.
  It rounds up, so it may bind a wei or two early — never late.
- **Fail-closed.** The storage default is zero: DUSD borrowing is shut until the owner opens
  it. `Deploy.s.sol` sets the initial value from `Config.s.sol` (10,000,000 DUSD on Anvil and
  Sepolia). A forgotten configuration means nothing mints, which is noticed immediately; the
  limit can never silently be "unlimited".

`_borrowDusd` is the only site that adds DUSD debt and `_retireDusdDebt` the only one that
removes it, so the ceiling governs every route that adds debt and **no value of it can block
repayment, redemption, or liquidation** — zero included, below current debt included.
Debt above the ceiling — reached by accrual alone or by the owner lowering it — is a
legitimate state: new borrows revert until repayments bring the total back under, and
nothing is force-unwound. Same principle as [[0009-token-listing-admin]]: an admin lever
may shrink exposure, never trap anyone in it.

ADR 0003's receive-path rule is untouched; this record is consistent with it.

## Consequences

- A mint already in flight when the ceiling closes still lands. The ceiling governs new
  borrows; the debt behind an in-flight message was recorded before it moved.
- `getTotalDusdDebt()` reads the stored index like every other view, so between accruals it
  understates debt and headroom read from it is overstated. Callers needing exact headroom
  call `accrueDusd()` first or leave margin.
- Per-chain ceilings make the "global" figure an operational discipline, not an on-chain
  guarantee. Nothing stops the per-chain values from summing to more than intended.
- The owner is still a plain EOA behind `Ownable`; the ceiling is as trustworthy as that key.

## Alternatives rejected

**Mint cap in `DUSD.sol`** (`ERC20Capped`-style). `Adapter._lzReceive` calls `DUSD.mint`, so
this is a receive-path revert — forbidden by ADR 0003, and it would strand borrowers owing
DUSD they never received. It would also cap a chain's local token supply, which moves as
users bridge, rather than the debt that chain issued.

**Per-destination ceilings.** Issuance per destination is countable; outstanding per
destination is not, because DUSD is fungible and a borrower repaying at home cannot say
which chain their tokens were minted on. Only cumulative issuance is trackable, and it only
rises — it would eventually lock borrowing for good.

**A true global ceiling via messaging.** Puts asynchronous state on the borrow path, the
shape ADR 0003 rejected.

**Principal-only counting.** Closer to supply, but repayments do not separate principal from
fee today; all three retirement paths would need new bookkeeping.

**Fail-open default.** A forgotten configuration would mean no limit at all.

**Constructor parameter.** Same safety as a zero storage default, at the cost of the
constructor signature and every deploy site.

## Related

- [[0003-dusd-only-cross-chain-borrowing]] — the receive path stays unconditional
- [[0007-dusd-redemption]] — the below-par mechanism
- [[0009-token-listing-admin]] — the precedent for admin levers that never block unwinding
- [[DUSD]], [[Cross-Chain]]
