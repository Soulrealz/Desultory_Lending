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
}
