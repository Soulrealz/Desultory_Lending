// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DUSD} from "../src/DUSD.sol";
import {EndpointV2Mock} from "@layerzerolabs/test-devtools-evm-foundry/contracts/mocks/EndpointV2Mock.sol";

contract DUSDTest is Test {
    DUSD dusd;
    EndpointV2Mock endpoint;

    address owner = address(this);
    address minter = makeAddr("minter");
    address alice = address(0xA11CE);

    function setUp() public {
        endpoint = new EndpointV2Mock(1, owner);
        dusd = new DUSD("DesultoryUSD", "DUSD", address(endpoint), owner);
    }

    function testOnlyMinterCanMint() public {
        vm.expectRevert(DUSD.DUSD__NotMinter.selector);
        vm.prank(alice);
        dusd.mint(alice, 1e18);

        dusd.setMinter(minter, true);

        vm.prank(minter);
        dusd.mint(alice, 1e18);
        assertEq(dusd.balanceOf(alice), 1e18);
    }

    function testOnlyMinterCanBurn() public {
        dusd.setMinter(minter, true);
        vm.prank(minter);
        dusd.mint(alice, 1e18);

        vm.expectRevert(DUSD.DUSD__NotMinter.selector);
        vm.prank(alice);
        dusd.burn(alice, 1e18);

        vm.prank(minter);
        dusd.burn(alice, 1e18);
        assertEq(dusd.balanceOf(alice), 0);
    }

    function testNonOwnerCannotSetMinter() public {
        vm.expectRevert();
        vm.prank(alice);
        dusd.setMinter(minter, true);
    }

    function testIsAnOFT() public view {
        // token() is OFT's self-reference; its presence proves the OFT base is wired
        assertEq(dusd.token(), address(dusd));
    }
}
