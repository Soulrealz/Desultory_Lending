pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Position} from "../src/PositionNFT.sol";

contract HealthStub {
    bool public healthy = true;

    function setHealthy(bool h) external {
        healthy = h;
    }

    function isPositionHealthy(uint256) external view returns (bool) {
        return healthy;
    }
}

contract PositionTest is Test {
    Position position;
    HealthStub stub;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        position = new Position("Desultor", "DST");
        stub = new HealthStub();
    }

    function testMintOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        position.mint(alice);

        uint256 id = position.mint(alice);
        assertEq(id, 1);
        assertEq(position.ownerOf(1), alice);
    }

    function testExists() public {
        assertFalse(position.exists(1));
        position.mint(alice);
        assertTrue(position.exists(1));
    }

    function testSetProtocolOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        position.setProtocol(address(stub));
    }

    function testSetProtocolOnlyOnce() public {
        position.setProtocol(address(stub));
        vm.expectRevert(Position.Position__ProtocolAlreadySet.selector);
        position.setProtocol(address(stub));
    }

    function testTransferUngatedWhenProtocolUnset() public {
        position.mint(alice);
        vm.prank(alice);
        position.transferFrom(alice, bob, 1);
        assertEq(position.ownerOf(1), bob);
    }

    function testTransferGate() public {
        position.setProtocol(address(stub));
        position.mint(alice);

        vm.prank(alice);
        position.transferFrom(alice, bob, 1);
        assertEq(position.ownerOf(1), bob);

        stub.setHealthy(false);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Position.Position__PositionUnhealthy.selector, 1));
        position.transferFrom(bob, alice, 1);
    }

    function testMintNotGatedWhenUnhealthy() public {
        position.setProtocol(address(stub));
        stub.setHealthy(false);
        uint256 id = position.mint(alice);
        assertEq(id, 1);
        assertEq(position.ownerOf(1), alice);
    }
}
