---
status: accepted
date: 2026-06-10
implemented-in: 5db9f71
---

# 0001 — The Position NFT is the position

## Status

Accepted. Implemented in `5db9f71`.

## Context

The original design keyed all collateral and debt off
`__userPositions[msg.sender]` — an address-to-position mapping — while *also*
minting an ERC-721 on first deposit.

The two disagreed. Transferring the NFT moved nothing: the buyer received a token,
and the seller kept the collateral, the debt, and the right to withdraw and borrow
against it. The NFT was decoration.

Tradeable positions were a stated goal of the protocol, so this was not a cosmetic
inconsistency — it was the headline feature not existing.

## Decision

Make the NFT the sole source of truth for position ownership.

- All accounting maps key off `positionId`, which is the ERC-721 `tokenId`
- `withdraw` and `borrow` authorize against `positionNFT.ownerOf(positionId)`
- `deposit` and `repay` stay permissionless — both strictly improve the position
- `deposit(0, …)` mints a new position, so one address can hold many
- `Position._update` blocks transfer of a position that is currently liquidatable

## Consequences

**Gained.** Positions are genuinely tradeable; the buyer gets exactly what the
seller had. One address can run several isolated positions, so a bad one does not
endanger the others. Permissionless repay makes third-party liquidation bots
possible without any additional mechanism.

**Cost.** Every entry point takes a `positionId` parameter, so the API is wordier
than the address-keyed version. An `ownerOf` call is added to `withdraw` and
`borrow`. A position sitting just under the liquidation line cannot be sold, which
is exactly when its owner most wants to — accepted deliberately, and revisitable
once a liquidation threshold separate from LTV exists.

**Downstream.** The liquidation engine now has to reason about NFT ownership as
well as balances; it was mechanically re-pointed at the new storage and remains
broken. See [[Liquidations]].

## Alternatives considered

**Keep the address mapping, make the NFT a receipt.** Cheapest change and
preserves the simpler API — but abandons tradeable positions, which was the point.

**Dual bookkeeping: address mapping plus NFT, synced on transfer.** Would have
preserved the existing API. Rejected because two sources of truth for the same
fact drift, and every future feature would have had to keep them in step. The
failure mode is silent and unbounded.

## Related

- [[Positions]] — the resulting semantics as implemented
- [[Liquidations]] — the module this decision left broken
