# Project Structure

> Maintained per the rule in `CLAUDE.md`: update when files/directories are added, removed, renamed, or moved.
> Gitignored content (`lib/`, `out/`, `cache/`, `.env`, `broadcast/`, `docs/superpowers/`) is excluded.

```
Desultory_Lending/
├── .gitattributes              # Enforces LF line endings
├── .gitignore
├── CLAUDE.md                   # AI agent project instructions (doc upkeep rule, build/test notes)
├── LICENSE                     # Apache 2.0
├── PROJECT_CONTEXT.md          # High-level map of core logic per module
├── PROJECT_STRUCTURE.md        # This file
├── README.md                   # Protocol specification: rates model, liquidation engine, governance
├── docs/                       # Obsidian vault (open this folder as the vault root)
│   ├── README.md               # Vault orientation: the four zones and their accuracy contracts
│   ├── .obsidian/              # Vault config (app/core-plugins/graph); workspace state gitignored
│   ├── Protocol/               # MAINTAINED: what the protocol actually does, per module
│   │   ├── Protocol.md         # Zone index
│   │   ├── Accounting.md       # Dual-index model, scaled balances, reserves, rounding policy
│   │   ├── Interest-Rate-Model.md  # 4-bracket kinked borrow curve, per-token multiplier
│   │   ├── Positions.md        # NFT-as-position semantics, authorization, transfer health gate
│   │   ├── Oracles.md          # Chainlink wrapper, staleness window, decimal normalization
│   │   └── Liquidations.md     # Documents the engine's defects; the module is broken
│   ├── Decisions/              # MAINTAINED: numbered ADRs, superseded rather than edited
│   │   ├── Decisions.md        # Zone index and status conventions
│   │   └── 0001-nft-as-position.md  # ADR: the Position NFT is the source of truth
│   ├── Audit/                  # MAINTAINED: threat model, invariants, findings
│   │   ├── Audit.md            # Zone index
│   │   └── 2026-06-10-project-assessment.md  # State-of-the-project audit
│   └── Notes/                  # NOT maintained: research and scratch thinking
│       ├── Notes.md            # Zone index
│       ├── Research/           # Reading notes on external systems (LayerZero, ElizaOS, Aave)
│       └── Log/                # Dated working notes
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
