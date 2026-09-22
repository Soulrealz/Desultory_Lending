// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";
import {TargetFunctions} from "./TargetFunctions.sol";
import {Desultory} from "../../src/Desultory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @dev minimal reproduction of the accrual leak found by the fuzzer.
 *
 * accrue() credits lenders and reserves from a notional `interest` figure
 * computed as totalDebt * factor / WAD, but borrowers' debt actually grows via
 * borrowIndex += borrowIndex * factor / WAD. Truncating the *index* loses up to
 * 1 wei of index, which is then multiplied by totalScaledBorrows — so the debt
 * charged can fall short of `interest` by roughly totalScaledBorrows / WAD wei.
 * That difference is handed to lenders and reserves regardless.
 */
contract AccrualLeak is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    function test_singleAccrualDistributesMoreThanItCharges() public {
        address a = actors[0];

        vm.startPrank(a);
        desultory.deposit(0, address(usdc), 500_000e18);
        desultory.borrow(1, address(usdc), 400_000e18);
        vm.stopPrank();

        uint256 totalLeak;
        for (uint256 i = 0; i < 6; i++) {
            Desultory.Pool memory p0 = desultory.getPoolInfo(address(usdc));
            uint256 dep0 = p0.totalScaledDeposits * p0.liquidityIndex / WAD;
            uint256 bor0 = (p0.totalScaledBorrows * p0.borrowIndex + WAD - 1) / WAD;

            // an odd interval keeps the index from landing on round numbers
            vm.warp(block.timestamp + 97 days + 1337);

            vm.prank(a);
            desultory.repay(1, address(usdc), 1);

            Desultory.Pool memory p1 = desultory.getPoolInfo(address(usdc));
            uint256 dep1 = p1.totalScaledDeposits * p1.liquidityIndex / WAD;
            uint256 bor1 = (p1.totalScaledBorrows * p1.borrowIndex + WAD - 1) / WAD;

            uint256 charged = bor1 + 1 - bor0;
            uint256 distributed = (dep1 - dep0) + (p1.reserves - p0.reserves);

            console.log("iteration", i);
            console.log("   borrowIndex", p1.borrowIndex);
            console.log("   charged    ", charged);
            console.log("   distributed", distributed);
            if (distributed > charged) {
                totalLeak += distributed - charged;
                console.log("   LEAK       ", distributed - charged);
            }
        }
        console.log("total leak (wei):", totalLeak);
        uint256 charged = 1;
        uint256 distributed = 1 + totalLeak;

        assertLe(distributed, charged, "accrual distributed more than it charged");
    }

    /**
     * @dev the second accrual defect the fuzzer found, and the reason toReserves ceils.
     *
     * property_borrowIndexOutpacesLiquidityIndex is justified by the reserve factor:
     * 10% of every accrual is removed from the lender side before liquidityIndex grows,
     * so borrow growth strictly dominates. That argument fails at dust scale, because
     * `toReserves = interest * RESERVE_FACTOR / MAX_BPS` floors to ZERO for any
     * interest below 10 wei — the reserve factor removes nothing and lenders take the lot.
     *
     * It compounds with a second rounding: `interest` is the difference of two CEILINGS
     * of totalScaledBorrows * borrowIndex / WAD, so a minuscule borrowIndex move still
     * ticks it a full wei. That wei was manufactured by rounding rather than earned at
     * the rate, and against a 51-wei deposit base it moves liquidityIndex by 1/51 — far
     * more than the rate moved borrowIndex.
     *
     * 51 scaled deposits and 45 scaled borrows are the figures the failing pool state
     * carried. One accrual is enough to invert the indexes.
     */
    function test_dustPoolDoesNotLetLiquidityIndexOvertakeBorrowIndex() public {
        address lender = actors[0];
        address duster = actors[1];

        // real borrowing capacity, so the dust pool below can actually be drawn on
        vm.prank(lender);
        desultory.deposit(0, address(usdc), 500_000e18); // position 1

        // a WETH pool holding dust, almost all of it lent out
        vm.prank(duster);
        desultory.deposit(0, address(weth), 51); // position 2
        vm.prank(lender);
        desultory.borrow(1, address(weth), 45);

        Desultory.Pool memory before = desultory.getPoolInfo(address(weth));
        assertEq(before.totalScaledDeposits, 51, "fixture must hold dust-scale deposits");

        vm.warp(block.timestamp + 3 days);
        wethFeed.updateAnswer(WETH_INITIAL_PRICE); // OracleLib times out after 3 hours
        usdcFeed.updateAnswer(USDC_INITIAL_PRICE);

        // poke accrual on the WETH pool with a 1-wei repayment
        vm.prank(lender);
        desultory.repay(1, address(weth), 1);

        Desultory.Pool memory p = desultory.getPoolInfo(address(weth));
        console.log("borrowIndex   ", p.borrowIndex);
        console.log("liquidityIndex", p.liquidityIndex);
        console.log("reserves      ", p.reserves);

        assertGe(p.borrowIndex, p.liquidityIndex, "borrowIndex fell behind liquidityIndex");
    }
}
