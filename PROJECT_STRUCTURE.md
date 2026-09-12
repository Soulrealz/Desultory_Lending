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
│   │   ├── Liquidations.md     # Documents the engine's defects; the module is broken
│   │   └── Cross-Chain.md      # DUSD-only remote borrowing over LayerZero V2; DUSD debt accounting
│   ├── Decisions/              # MAINTAINED: numbered ADRs, superseded rather than edited
│   │   ├── Decisions.md        # Zone index and status conventions
│   │   ├── 0001-nft-as-position.md  # ADR: the Position NFT is the source of truth
│   │   ├── 0002-internal-consistency-invariants.md  # ADR: fuzz internal consistency, not solvency
│   │   └── 0003-dusd-only-cross-chain-borrowing.md  # ADR: only DUSD crosses chains; one home chain per position
│   ├── Audit/                  # MAINTAINED: threat model, invariants, findings
│   │   ├── Audit.md            # Zone index
│   │   ├── Invariants.md       # The eight fuzzing invariants in prose, and what they found
│   │   └── 2026-06-10-project-assessment.md  # State-of-the-project audit
│   └── Notes/                  # NOT maintained: research and scratch thinking
│       ├── Notes.md            # Zone index
│       ├── Research/           # Reading notes on external systems (LayerZero, ElizaOS, Aave)
│       └── Log/                # Dated working notes
└── onchain/
    └── ethereum/               # Foundry project (solc 0.8.28)
        ├── README.md           # Dependency install (--no-git), test + fuzzing instructions
        ├── echidna.yaml        # Echidna campaign config (assertion mode)
        ├── medusa.json         # Medusa campaign config (assertion mode)
        ├── foundry.toml
        ├── remappings.txt
        ├── script/
        │   ├── Config.s.sol    # Per-network config: token/feed addresses + LZ endpoint/eid; mocks on Anvil
        │   └── Deploy.s.sol    # Deploys Position NFT, DUSD, Desultory, Adapter; wires ownership and minters
        ├── src/
        │   ├── Desultory.sol   # Core lending pool (positionId-keyed; pool indexes; lender yield; DUSD debt; owner)
        │   ├── DUSD.sol        # Protocol stablecoin: LayerZero OFT with owner-gated minters
        │   ├── PositionNFT.sol # ERC721 position — source of truth for ownership, health-gated transfers
        │   ├── crosschain/
        │   │   └── Adapter.sol # LayerZero V2 OApp carrying DUSD mint authorizations between chains
        │   ├── governance/
        │   │   └── VoteToken.sol # Bare LayerZero OFT; governance not implemented
        │   └── libraries/
        │       └── OracleLib.sol # Chainlink price feed wrapper with staleness check
        └── test/
            ├── Desultory.t.sol # Core suite: deposit/withdraw/borrow/repay, yield, NFT transfers, ownership, DUSD debt
            ├── DUSD.t.sol      # DUSD unit tests (minter gating, OFT wiring)
            ├── Position.t.sol  # Position NFT unit tests (mint auth, health-gated transfers)
            ├── crosschain/     # Two-chain tests on LayerZero's TestHelperOz5
            │   ├── Adapter.t.sol           # Messaging in isolation; unconditional receive path
            │   └── CrossChainBorrow.t.sol  # Deposit on A, DUSD on B; send-side reverts; bridge-home repay
            ├── recon/          # Chimera stateful fuzzing harness (Medusa + Echidna)
            │   ├── Setup.sol           # Deploys the system as Deploy.s.sol does, plus 3 actors
            │   ├── BeforeAfter.sol     # Per-token state snapshots around every call
            │   ├── Properties.sol      # The eight internal-consistency invariants
            │   ├── TargetFunctions.sol # Clamped call surface; no liquidation targets
            │   ├── CryticTester.sol    # Fuzzer entrypoint
            │   ├── CryticToFoundry.sol # Replays counterexamples as Foundry tests
            │   └── AccrualLeak.t.sol   # Regression test for the accrual leak the fuzzer found
            └── mocks/
                ├── MockERC20.sol
                └── MockV3Aggregator.sol  # Chainlink aggregator mock
```
