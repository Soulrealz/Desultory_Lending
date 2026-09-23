---
status: current
verified-against: 8847270
---

# Positions

A position is an ERC-721 token. Not a token that *represents* a position — the
token **is** the position. All collateral and debt accounting in `Desultory.sol`
is keyed by `positionId`, which is the NFT's `tokenId`.

Transferring the NFT transfers the collateral and the debt together.

## Authorization

| Action | Who may call |
|---|---|
| `deposit` | anyone |
| `repay` | anyone |
| `withdraw` | `positionNFT.ownerOf(positionId)` only |
| `borrow` | `positionNFT.ownerOf(positionId)` only |

The asymmetry is deliberate. Depositing collateral into someone's position and
repaying someone's debt both make that position strictly healthier — there is no
attack in letting a stranger do it for you, and permissionless repay is what makes
third-party liquidation bots possible. Withdrawing and borrowing extract value, so
they check ownership.

Orthogonal to the caller check, `deposit` and `borrow` also carry `notRetired(token)` —
the only two entry points that do. A retired asset takes no new exposure, while `withdraw`,
`repay` and every liquidation and redemption path stay open so an existing position can
still unwind. Retirement never removes the asset from `__tokenList`, so a retired token's
collateral and debt keep counting in every figure below exactly as before. See
[[0009-token-listing-admin]].

`deposit(0, token, amount)` mints a fresh position to `msg.sender` and deposits
into it. A single address can hold any number of positions, and they are
independent — one going bad does not touch the others. Tested by
`testMultiplePositionsPerAddress`.

## The transfer health gate

`Position._update` blocks transfers of unhealthy positions:

```solidity
function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
    if (_ownerOf(tokenId) != address(0) && address(_protocol) != address(0)) {
        if (!_protocol.isPositionHealthy(tokenId)) {
            revert Position__PositionUnhealthy(tokenId);
        }
    }
    return super._update(to, tokenId, auth);
}
```

The `_ownerOf(tokenId) != address(0)` guard is what distinguishes a transfer from
a mint. Mints must not be gated — a position is created empty, and an empty
position's health is evaluated before any collateral is in it.

Why gate at all: a liquidatable position is a hot potato. Without the gate, an
owner watching their position go underwater could sell it to someone who has not
noticed, and the liquidation would land on the buyer. It also prevents transfers
racing an in-flight liquidation.

`isPositionHealthy` is pointed at the same liquidatable semantics as the liquidation
engine (`healthFactor(positionId) >= WAD`), not at the LTV cap — see [[Liquidations]]
for the threshold/LTV split. That means the gate only blocks a transfer once the
position is actually seizable. Between the LTV cap and the liquidation threshold
there is a band where a position is over-borrowed-relative-to-LTV but not yet
liquidatable, and **transfers in that band are allowed**. This is deliberate, not
an oversight: a position that cannot yet be seized has no liquidator racing it, so
there is no hot potato to hand off and no race to protect against. The gate exists
to stop a liquidatable position from being sold out from under a liquidator's
in-flight transaction — a position that is merely over its LTV cap poses no such
risk. See [[0004-liquidation-engine]] for the ADR that records this as a deliberate
redefinition of `isPositionHealthy`, not a side effect.

## Wiring

`Position` is `Ownable`. The deploy sequence is order-dependent:

1. Deploy `Position`
2. Deploy `Desultory`, passing the `Position` address
3. `position.setProtocol(desultory)` — must happen while the deployer still owns it
4. `position.transferOwnership(desultory)` — so only the protocol can mint

`setProtocol` is one-shot; it reverts with `Position__ProtocolAlreadySet` on a
second call. Getting steps 3 and 4 out of order bricks the deployment: after
ownership moves to `Desultory`, nothing can call `setProtocol`, and the health
gate stays permanently disabled because `_protocol` is still the zero address.

## Known gap

Several files have no SPDX license identifier: `src/Desultory.sol`,
`src/PositionNFT.sol`, `src/governance/VoteToken.sol`, `script/Config.s.sol`,
`script/Deploy.s.sol` and `test/Desultory.t.sol`. The rest of `src/` (`DUSD.sol`,
`crosschain/Adapter.sol`, all three libraries) carries `UNLICENSED`.

## Related

- [[Accounting]] — what is stored per position
- [[Liquidations]] — what happens when the health check fails
