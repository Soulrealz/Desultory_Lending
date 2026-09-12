---
status: current
verified-against: 5db9f71
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

The cost is that a position sitting just above the liquidation line is untradeable
in exactly the moment its owner most wants to sell it. That is a real limitation,
accepted deliberately. Revisit it when the liquidation engine is redesigned — a
liquidation *threshold* separate from LTV would open a band where a position is
unhealthy-but-not-yet-liquidatable, and transfers could arguably be allowed there.

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

`src/PositionNFT.sol` has no SPDX license identifier. Every other source file
does.

## Related

- [[Accounting]] — what is stored per position
- [[Liquidations]] — what happens when the health check fails
