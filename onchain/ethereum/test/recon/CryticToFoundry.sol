// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";
import {TargetFunctions} from "./TargetFunctions.sol";

/// @dev replays fuzzer counterexamples as ordinary Foundry tests.
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    /// @dev proves Setup deploys a live system without a fuzzer involved.
    /// A harness whose Setup reverts reports a clean run and tests nothing.
    function test_sanity() public {
        desultory_deposit(0, 0, 0, 100e18);

        assertEq(positionIds.length, 1, "a position should have been minted");
        assertGt(
            desultory.getPositionCollateralForToken(positionIds[0], address(weth)), 0, "collateral should be recorded"
        );

        property_scaledBalancesReconcile();
        property_custodyReconciles();
        property_tokenConservation();
        property_borrowIndexOutpacesLiquidityIndex();
        property_utilizationNeverExceeds100();
    }

    /// @dev a fuller sequence: deposit, borrow, let interest accrue, move the
    /// price, repay. Exercises every target at least once.
    function test_sequence() public {
        // positionSeed 0 mints; positionSeed 1 selects the existing position,
        // so both deposits land on position 1 and it is collateralised in both
        // tokens before anything borrows against it.
        desultory_deposit(0, 0, 0, 500e18);
        desultory_deposit(1, 1, 1, 500e18);
        desultory_borrow(0, 0, 1, 100e18);
        warp(90 days);
        oracle_setPrice(0, 1500e18);
        desultory_repay(0, 0, 1, 50e18);
        desultory_withdraw(0, 0, 1, 10e18);

        property_scaledBalancesReconcile();
        property_indexesNeverDecrease();
        property_borrowIndexOutpacesLiquidityIndex();
        property_custodyReconciles();
        property_utilizationNeverExceeds100();
        property_tokenConservation();
    }
}
