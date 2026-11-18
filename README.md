# Desultory_Lending

An over-collateralized, cross-chain lending protocol, written in Solidity with Foundry.
It is a learning project.

- **Positions are NFTs.** Each position is an ERC721 token. The holder controls its
  collateral and its debt, and transferring the token hands both to the buyer.
- **One home chain per position.** Collateral and debt live on the chain where the
  position was opened. Only the protocol's stablecoin, **DUSD**, crosses chains: a
  borrower can have DUSD minted on another chain over LayerZero V2.
- **Two kinds of debt.** Borrow other depositors' assets (interest set by a kinked
  utilization curve), or mint DUSD against collateral (a flat stability fee).

## Status

| Area | State |
|---|---|
| Deposit / withdraw / borrow / repay, kinked interest, lender yield | Built |
| Position NFTs (transferable, health-gated transfers) | Built |
| DUSD: local and cross-chain minting, repayment, stability fee | Built |
| DUSD redemption (the $1 peg floor) and per-chain debt ceiling | Built |
| Liquidation engine with an internal (reserve-funded) backstop | Built |
| Owner-gated reserve withdrawal and token listing admin | Built |
| Stateful invariant fuzzing (Medusa + Echidna via Chimera) | Built |
| Paying out DUSD reserves | Not started (design open) |
| External flash-loan liquidation backstop | Not started |
| ElizaOS automated liquidation | Not started |
| Governance: staking, boosting, slashing | Not started (`VoteToken` is a bare OFT) |

Nothing is deployed anywhere. Access control is a single `Ownable` owner.

## Roadmap

Each of these needs a design decision before any code, and gets an ADR when it is made.

- **The `dusdReserves` outlet.** The DUSD stability fee piles up in `dusdReserves`, a claim
  with no tokens behind it. Paying it out means minting DUSD against no new collateral,
  which dilutes what redemption is backed by. ADR 0005 put this off. It is not obviously
  solvable by minting.
- **External liquidation backstop.** When a pool holds nothing and reserves cannot cover a
  liquidation, flash-loan the shortfall from Uniswap or Aave. The first real external
  integration, with an untrusted callback in the middle of a liquidation. It is the largest
  remaining piece, and `Desultory` has about 4k bytes of room left under EIP-170.
- **ElizaOS automation.** Path B of the spec below: an off-chain agent plus a permissioned
  entry point that liquidates positions automatically.
- **Governance.** Staking, boosting and slashing from section D below. Greenfield; nothing
  depends on it.

## Getting started

Everything on-chain lives in `onchain/ethereum/`. Dependencies are not vendored, so install
them first, following [`onchain/ethereum/README.md`](onchain/ethereum/README.md). Then:

```
cd onchain/ethereum
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 forge test
```

`PRIVATE_KEY` is required by every `forge` command. The key above is Anvil's public
account-0 key and is not a secret.

## Where to read next

| File | What it is for |
|---|---|
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Toolchain, verification gates, the rules that are easy to break, workflow and doc upkeep. Read before changing anything. |
| [`docs/Protocol/Architecture.md`](docs/Protocol/Architecture.md) | The contracts, who calls whom, and the main flows on one page. Start here for the code. |
| [`docs/Protocol/Glossary.md`](docs/Protocol/Glossary.md) | Every term the docs use without explaining. |
| [`docs/Audit/Threat-Model.md`](docs/Audit/Threat-Model.md) | Trust assumptions, owner powers, attack surface. [`Known-Issues.md`](docs/Audit/Known-Issues.md) next to it lists what is known and not fixed. |
| [`PROJECT_STRUCTURE.md`](PROJECT_STRUCTURE.md) | Every file in the repo, with a one-line description. |
| [`PROJECT_CONTEXT.md`](PROJECT_CONTEXT.md) | What each contract and module does, in a few paragraphs each. |
| [`docs/`](docs/README.md) | An Obsidian vault: per-module protocol notes, numbered design decisions (ADRs), and the fuzzing invariants. |

---

## Original specification

The design the project set out to build. Some of it has been built as specified, some
was changed by a later design decision, and some is not built yet. Each section says
which. For what the code does today, the notes in `docs/Protocol/` are authoritative.

### 1. System Overview

The system is a decentralized, over-collateralized lending and borrowing protocol. It
supports multi-tiered dynamic interest rates, a multi-path liquidation engine (including
automated and user-driven liquidations with flash loan integration), and a
governance/voting subsystem featuring staking incentives, power boosting, and
participation-slashing mechanics. The protocol also supports a native or pegged
stablecoin ($DUSD$) and offers advanced asset-clearing mechanics during liquidations.

### 2. Core Functional Modules

#### A. User Flow & Liquidity Management

> **Status: built.** Depositors earn 90% of borrow interest through a rising liquidity
> index; the other 10% goes to protocol reserves. See `docs/Protocol/Accounting.md`.

Users interact with the protocol primarily as Depositors, Borrowers, or both.
- Deposit Liquidity: Users deposit assets from a curated set of approved collateral types.
- Passive Depositor Path: Users can choose to Remain a Depositor only to passively Earn a portion of the protocol fees.
- Borrower Path: Users can borrow assets against their collateral up to a set Loan-to-Value (LTV) ratio.
- Borrowable Assets: Users can borrow $DUSD$ minted by the protocol or other assets deposited by other users.
- Debt Accrual: Borrowers accrue interest/debt dynamically based on real-time Borrow Utilization.

#### B. Dynamic Debt Formula Engine

> **Status: built as specified** for deposited assets, with a per-token multiplier applied
> on top of the curve. DUSD does not use this curve: nobody deposits DUSD, so its
> utilization would always be zero, and it charges a flat stability fee instead. Default
> parameters are in `docs/Protocol/Interest-Rate-Model.md`.

The protocol utilizes a multi-bracket (kinked) interest rate model to determine the Final Borrow Rate based on current capital utilization ($U$). Variables Defined:

- $B$: Base borrow rate
- $L, N, H, E$: Rate constants for Low, Normal, High, and Extreme brackets.
- $U$: Current Utilization rate ($U = \frac{\text{Borrows}}{\text{Total Liquidity}}$)
- $Lu, Nu, Hu, Eu$: Utilization thresholds defining the boundaries for Low, Normal, High, and Extreme brackets.

Rate Calculations by Bracket:

Low:
- Condition: $U \le Lu$
- Formula: $$B + \left(\frac{U \cdot L}{Lu}\right)$$

Normal:
- Condition: $Lu < U \le Nu$
- Formula: $$B + L + \frac{(U - Lu) \cdot (N - L)}{Nu - Lu}$$

High:
- Condition: $Nu < U \le Hu$
- Formula: $$B + N + \frac{(U - Nu) \cdot (H - N)}{Hu - Nu}$$

Extreme:
- Condition: $Hu < U \le Eu$
- Formula: $$B + H + \frac{(U - Hu) \cdot (E - H)}{Eu - Hu}$$

#### C. Liquidation Engine

> **Status: partly built, and partly changed.**
> - **Path A is built,** with one change. There is no 0–4.9% band. A position is
>   liquidatable once its health factor drops below 1. A liquidator can repay up to 50% of
>   the debt, or 100% once the health factor is below 0.95, and receives the collateral at
>   a per-token bonus.
> - **Settlement changed.** The separate proportional and per-asset entry points were
>   replaced by one `liquidate` call that names one debt asset and one collateral asset
>   (`docs/Decisions/0004-liquidation-engine.md`). Liquidators fund themselves; there is
>   no protocol-provided flash loan for them.
> - **The internal backstop is built** (`liquidateWithBackstop`, ADR 0006). The protocol
>   takes 70% of the bonus on that path, against 30% normally.
> - **Not built:** Path B (ElizaOS) and the external flash-loan backstop.
>
> See `docs/Protocol/Liquidations.md`.

1. Liquidator Triggers & Execution Paths
    - Path A: External Liquidator (Manual/Bot)
        - Triggered when a position is breached anywhere between (0 : 4.9]% of the liquidation threshold.
        - The liquidator repays the debt and receives the user's collateral at a discount.
        - Funding Options for Liquidator:
            - Liquidate with own funds: Direct capital deployment.
            - Use flashloan: The liquidator triggers an internal or external flash loan to execute capital-free liquidations.
    - Path B: ElizaOS Automatic Liquidation
        - Triggered automatically when the liquidation threshold reaches exactly 5%.
        - The entire liquidation reward is collected directly by the protocol treasury.

2. Protocol Flash Loan Backstop

    If a liquidation is routed through a FlashLoan structural block, the protocol determines handling based on liquidity pools:
    - Internal Backstop: If the protocol has enough native funds to cover the liquidation, it processes internally (Yielding a Bigger Reward for the Protocol).
    - External Backstop: The protocol programmatically executes a flash loan from external venues (e.g., UniSwap or Aave) to cover and clear the bad debt (Yielding a Partial Liquidation Reward for the Protocol).

3. Settlement Mechanics

    Liquidations can be executed under two strategies (allowing users to choose percentage liquidation per asset):

    - Proportional Liquidation
    - Per Asset Liquidation
    - In the future - Percentage liquidation per asset (eg 10% asset 1, 90% asset 2)

#### D. Voting, Staking & Governance

> **Status: not built.** `src/governance/VoteToken.sol` is a bare LayerZero OFT with no
> staking, locking, boosting or slashing. Nothing else in the protocol depends on it.

A tokenomics layer built using standard DeFi governance primitives extended for cross-chain capabilities and active participation enforcement.

- Locking Deposits: Users can lock their liquidity deposits to increase their APY.
- Staking for Governance: Locking deposits yields Voting Tokens.
    - Implementation Base: Modeled on CompoundV2 Governor Bravo.
    - Extensions: Extended with ERC5805 and features native slashing functionality.
    - Cross-Chain: Integrates LayerZero (LZ) for cross-chain governance voting.
- Incentive Mechanisms:
    - Borrower Incentives: Borrowers who repay their debt also receive Voting Tokens.
    - Power Boosting: Users can actively lock their earned voting tokens further to increase their aggregate voting power.
- Slashing Guardrail: Voting tokens that remain stagnant and are not used in active proposals over time get slashed for non-participation.
