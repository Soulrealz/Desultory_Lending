// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {BaseSetup} from "@chimera/BaseSetup.sol";
import {vm} from "@chimera/Hevm.sol";

import {Desultory} from "../../src/Desultory.sol";
import {Position} from "../../src/PositionNFT.sol";
import {DUSD} from "../../src/DUSD.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

/**
 * @dev deploys the full system the way script/Deploy.s.sol does, plus three
 * funded actors. Parameters are kept identical to the deploy script on purpose:
 * a harness that fuzzes a differently-configured system proves nothing about
 * the one that ships.
 */
abstract contract Setup is BaseSetup {
    Desultory internal desultory;
    Position internal position;
    DUSD internal dusd;

    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockV3Aggregator internal wethFeed;
    MockV3Aggregator internal usdcFeed;

    address[3] internal actors;

    uint256[] internal positionIds;
    address[2] internal tokens;

    // Initial feed answers, mirroring script/Config.s.sol
    int256 internal constant WETH_INITIAL_PRICE = 3000e18;
    int256 internal constant USDC_INITIAL_PRICE = 1e8;

    uint256 internal constant ACTOR_FUNDING = 1_000_000e18;

    function setup() internal virtual override {
        wethFeed = new MockV3Aggregator(18, WETH_INITIAL_PRICE);
        usdcFeed = new MockV3Aggregator(8, USDC_INITIAL_PRICE);

        weth = new MockERC20("WETH", "WETH");
        usdc = new MockERC20("USDC", "USDC");

        tokens = [address(weth), address(usdc)];

        address[] memory tokenAddresses = new address[](2);
        tokenAddresses[0] = address(weth);
        tokenAddresses[1] = address(usdc);

        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = address(wethFeed);
        priceFeeds[1] = address(usdcFeed);

        uint8[] memory feedDecimals = new uint8[](2);
        feedDecimals[0] = 18;
        feedDecimals[1] = 8;

        uint8[] memory tokenDecimals = new uint8[](2);
        tokenDecimals[0] = 18;
        tokenDecimals[1] = 18;

        uint8[] memory ltvs = new uint8[](2);
        ltvs[0] = 70;
        ltvs[1] = 85;

        uint16[] memory rates = new uint16[](2);
        rates[0] = 400;
        rates[1] = 200;

        position = new Position("Desultor", "DST");
        dusd = new DUSD("DesultoryUSD", "DUSD");
        desultory = new Desultory(
            tokenAddresses, priceFeeds, feedDecimals, tokenDecimals, ltvs, rates, address(position), address(dusd)
        );

        // Order matters: setProtocol must run while the deployer still owns the
        // NFT contract. Reversed, the health gate is permanently disabled.
        position.setProtocol(address(desultory));
        position.transferOwnership(address(desultory));

        actors = [address(0xa11ce), address(0xb0b), address(0xca101)];
        for (uint256 i = 0; i < actors.length; i++) {
            weth.mint(actors[i], ACTOR_FUNDING);
            usdc.mint(actors[i], ACTOR_FUNDING);

            vm.prank(actors[i]);
            weth.approve(address(desultory), type(uint256).max);
            vm.prank(actors[i]);
            usdc.approve(address(desultory), type(uint256).max);
        }
    }

    function _getActor(uint8 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _getToken(uint8 seed) internal view returns (MockERC20) {
        return seed % 2 == 0 ? weth : usdc;
    }

    function _getFeed(uint8 seed) internal view returns (MockV3Aggregator) {
        return seed % 2 == 0 ? wethFeed : usdcFeed;
    }

    /// @dev returns 0 ("mint a new position") when none exist yet
    function _getPosition(uint8 seed) internal view returns (uint256) {
        if (positionIds.length == 0) {
            return 0;
        }
        return positionIds[seed % positionIds.length];
    }
}
