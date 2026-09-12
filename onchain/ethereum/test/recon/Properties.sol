// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Asserts} from "@chimera/Asserts.sol";

import {BeforeAfter} from "./BeforeAfter.sol";
import {Desultory} from "../../src/Desultory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @dev internal-consistency invariants only. Economic solvency is deliberately
 * NOT asserted: with no working liquidation engine, a large enough price drop
 * makes the protocol genuinely insolvent, so asserting solvency would be
 * asserting a property the system does not have. Every property here survives
 * bad debt, which is what lets the fuzzer move prices as violently as it likes.
 *
 * See docs/Audit/Invariants.md and docs/Decisions/0002-internal-consistency-invariants.md
 */
abstract contract Properties is BeforeAfter, Asserts {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_BPS = 10_000;

    // indexed by token slot: 0 = weth, 1 = usdc
    uint256[2] internal ghostPaidIn;
    uint256[2] internal ghostPaidOut;

    /// @dev per-position scaled balances must sum to the pool totals, exactly.
    /// These are raw stored integers and no rounding happens in the summation,
    /// so any drift at all is a real bookkeeping bug.
    function property_scaledBalancesReconcile() public {
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 sumDeposits;
            uint256 sumBorrows;
            for (uint256 p = 0; p < positionIds.length; p++) {
                sumDeposits += desultory.getScaledDeposit(positionIds[p], tokens[i]);
                sumBorrows += desultory.getScaledBorrow(positionIds[p], tokens[i]);
            }

            Desultory.Pool memory pool = desultory.getPoolInfo(tokens[i]);
            eq(sumDeposits, pool.totalScaledDeposits, "scaled deposits must sum to pool total");
            eq(sumBorrows, pool.totalScaledBorrows, "scaled borrows must sum to pool total");
        }
    }

    /// @dev both indexes are monotonically non-decreasing across every call.
    function property_indexesNeverDecrease() public {
        for (uint256 i = 0; i < tokens.length; i++) {
            gte(_after[i].liquidityIndex, _before[i].liquidityIndex, "liquidityIndex decreased");
            gte(_after[i].borrowIndex, _before[i].borrowIndex, "borrowIndex decreased");
        }
    }

    /// @dev debt can never exceed deposits, and the reserve factor removes 10%
    /// from the lender side before liquidityIndex grows, so borrow growth
    /// strictly dominates. Both indexes start at WAD.
    function property_borrowIndexOutpacesLiquidityIndex() public {
        for (uint256 i = 0; i < tokens.length; i++) {
            Desultory.Pool memory pool = desultory.getPoolInfo(tokens[i]);
            gte(pool.borrowIndex, pool.liquidityIndex, "borrowIndex fell behind liquidityIndex");
        }
    }

    /// @dev cash on hand plus outstanding debt must cover deposits plus reserves.
    /// This identity is stated in getAvailableLiquidity's own natspec:
    /// cash = deposits + reserves - debt.
    function property_custodyReconciles() public {
        for (uint256 i = 0; i < tokens.length; i++) {
            Desultory.Pool memory pool = desultory.getPoolInfo(tokens[i]);

            uint256 deposits = pool.totalScaledDeposits * pool.liquidityIndex / WAD;
            uint256 borrows = (pool.totalScaledBorrows * pool.borrowIndex + WAD - 1) / WAD;
            uint256 balance = MockERC20(tokens[i]).balanceOf(address(desultory));

            gte(balance + borrows, deposits + pool.reserves, "custody does not cover obligations");
        }
    }

    function property_utilizationNeverExceeds100() public {
        for (uint256 i = 0; i < tokens.length; i++) {
            lte(uint256(desultory.getUtilization(tokens[i])), MAX_BPS, "utilization above 100%");
        }
    }

    /// @dev physical custody must match the harness's own record of every
    /// transfer. Independent of the protocol's accounting: property 4 asks
    /// whether the books match the balance; this asks whether the balance
    /// matches what actually moved.
    ///
    /// Stated additively rather than as paidIn - paidOut: the subtraction would
    /// panic on underflow in exactly the case this exists to catch, turning a
    /// clean assertion failure into a confusing arithmetic one.
    function property_tokenConservation() public {
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = MockERC20(tokens[i]).balanceOf(address(desultory));
            eq(ghostPaidIn[i], ghostPaidOut[i] + balance, "token conservation broken");
        }
    }
}
