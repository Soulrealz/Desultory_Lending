# Project Structure

> Maintained per the rule in `CLAUDE.md`: update when files/directories are added, removed, renamed, or moved.
> Gitignored content (`lib/`, `out/`, `cache/`, `.env`, `broadcast/`) is excluded.

```
Desultory_Lending/
├── .gitattributes              # Enforces LF line endings
├── .gitignore
├── CLAUDE.md                   # AI agent project instructions (doc upkeep rule, build/test notes)
├── LICENSE                     # Apache 2.0
├── PROJECT_CONTEXT.md          # High-level map of core logic per module
├── PROJECT_STRUCTURE.md        # This file
├── README.md                   # Protocol specification: rates model, liquidation engine, governance
├── docs/
│   ├── PROJECT_ASSESSMENT.md   # 2026-06-10 state-of-the-project audit (what works, what's broken/missing)
│   └── superpowers/
│       ├── specs/lending-core/June_2026/
│       │   └── 2026-06-10-nft-positions-lender-accounting-design.md  # Approved design spec
│       └── plans/lending-core/June_2026/
│           └── 2026-06-10-nft-positions-lender-accounting.md         # Executed implementation plan
└── onchain/
    └── ethereum/               # Foundry project (solc 0.8.28)
        ├── README.md           # Dependency install + test instructions
        ├── foundry.toml
        ├── remappings.txt
        ├── script/
        │   ├── Config.s.sol    # Per-network config: token/feed addresses, deploys mocks on Anvil
        │   └── Deploy.s.sol    # Deploys Position NFT, DUSD, Desultory; wires ownership
        ├── src/
        │   ├── Desultory.sol   # Core lending pool (positionId-keyed; pool indexes; lender yield)
        │   ├── DUSD.sol        # Protocol stablecoin (plain ERC20 for now; OFT planned)
        │   ├── PositionNFT.sol # ERC721 position — source of truth for ownership, health-gated transfers
        │   ├── crosschain/
        │   │   └── Adapter.sol # Empty placeholder for LayerZero cross-chain adapter
        │   ├── governance/
        │   │   └── VoteToken.sol # Bare LayerZero OFT; governance not implemented
        │   └── libraries/
        │       └── OracleLib.sol # Chainlink price feed wrapper with staleness check
        └── test/
            ├── Desultory.t.sol # Core suite: deposit/withdraw/borrow/repay, yield, NFT transfers, fuzz
            ├── Position.t.sol  # Position NFT unit tests (mint auth, health-gated transfers)
            └── mocks/
                ├── MockERC20.sol
                ├── MockLZ.sol            # LayerZero endpoint mock (currently unused)
                └── MockV3Aggregator.sol  # Chainlink aggregator mock
```
