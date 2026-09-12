// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Setup} from "./Setup.sol";
import {Desultory} from "../../src/Desultory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @dev snapshots pool state around every target call. Only the index-monotonicity
 * property needs this today; it exists now because adding it later would mean
 * retrofitting every target function with the modifier.
 */
abstract contract BeforeAfter is Setup {
    struct TokenVars {
        uint256 liquidityIndex;
        uint256 borrowIndex;
        uint256 totalScaledDeposits;
        uint256 totalScaledBorrows;
        uint256 reserves;
        uint256 protocolBalance;
    }

    // indexed by token slot: 0 = weth, 1 = usdc
    mapping(uint256 => TokenVars) internal _before;
    mapping(uint256 => TokenVars) internal _after;

    function __snapshot(mapping(uint256 => TokenVars) storage target) private {
        for (uint256 i = 0; i < tokens.length; i++) {
            Desultory.Pool memory pool = desultory.getPoolInfo(tokens[i]);
            target[i] = TokenVars({
                liquidityIndex: pool.liquidityIndex,
                borrowIndex: pool.borrowIndex,
                totalScaledDeposits: pool.totalScaledDeposits,
                totalScaledBorrows: pool.totalScaledBorrows,
                reserves: pool.reserves,
                protocolBalance: MockERC20(tokens[i]).balanceOf(address(desultory))
            });
        }
    }

    function __before() internal {
        __snapshot(_before);
    }

    function __after() internal {
        __snapshot(_after);
    }

    modifier updateGhosts() {
        __before();
        _;
        __after();
    }
}
