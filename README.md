# Desultory_Lending

## System Architecture & Protocol Specification

### 1. System Overview

The system is a decentralized, over-collateralized lending and borrowing protocol. It supports multi-tiered dynamic interest rates, a multi-path liquidation engine (including automated and user-driven liquidations with flash loan integration), and a governance/voting subsystem featuring staking incentives, power boosting, and participation-slashing mechanics.The protocol also supports a native or pegged stablecoin ($DUSD$) and offers advanced asset-clearing mechanics during liquidations.

### 2. Core Functional Modules

#### A. User Flow & Liquidity Management:

Users interact with the protocol primarily as Depositors, Borrowers, or both.
- Deposit Liquidity: Users deposit assets from a curated set of approved collateral types.
- Passive Depositor Path: Users can choose to Remain a Depositor only to passively Earn a portion of the protocol fees.
- Borrower Path: Users can borrow assets against their collateral up to a set Loan-to-Value (LTV) ratio.
- Borrowable Assets: Users can borrow $DUSD$ minted by the protocol or other assets deposited by other users.
- Debt Accrual: Borrowers accrue interest/debt dynamically based on real-time Borrow Utilization.

#### B. Dynamic Debt Formula Engine

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