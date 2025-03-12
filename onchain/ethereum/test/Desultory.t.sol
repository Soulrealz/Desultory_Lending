pragma solidity 0.8.28;

import { Test, console } from "forge-std/Test.sol";

import { Desultory } from "../src/Desultory.sol";
import { Position } from "../src/PositionNFT.sol";
import { DUSD } from "../src/DUSD.sol";
import { Deploy } from "../script/Deploy.s.sol";
import "./mocks/MockERC20.sol";

import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract DesultoryTest is Test
{
    Desultory desultory;
    Position position;
    DUSD dusd;
    Deploy deploy;

    uint256 constant private __protocolPositionId = 1;

    address weth;
    address usdc;

    address public alice = address(1);
    address public bob = address(2);
    address public lorem = address(3);
    address public ipsum = address(4);

    // Invalid Values
    uint256 zeroAmount = 0;
    address dead = 0x000000000000000000000000000000000000dEaD;

    function setUp() public
    {
        deploy = new Deploy();
        (address addr1, address addr2, address addr3) = deploy.run();
        desultory = Desultory(addr1);
        position = Position(addr2);
        dusd = DUSD(addr3);

        desultory.initializeProtocolPosition();

        weth = deploy.getAddrI(0);
        usdc = deploy.getAddrI(1);

        MockERC20(weth).mint(alice, 1000e18);
        vm.prank(alice);
        MockERC20(weth).approve(address(desultory), 100e18);

        MockERC20(usdc).mint(alice, 50_000e8);
        vm.prank(alice);
        MockERC20(usdc).approve(address(desultory), 10_000e8);
    }


    ///////////////////////
    // Deposit Tests
    ///////////////////////
    // @todo multiasset multiuser deposit (fuzzable)
    function testDepositReverts() public 
    {
        vm.startPrank(alice);

        vm.expectRevert(Desultory.Desultory__ZeroAmount.selector);
        desultory.deposit(weth, zeroAmount);

        vm.expectRevert(Desultory.Desultory__ZeroAmount.selector);
        desultory.deposit(weth, zeroAmount, 0);

        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__TokenNotWhitelisted.selector, dead));
        desultory.deposit(dead, 1);

        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__TokenNotWhitelisted.selector, dead));
        desultory.deposit(dead, 1, 0);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99999999));
        desultory.deposit(weth, 1, 99999999);

        vm.expectRevert(Desultory.Desultory__OwnerMismatch.selector);
        desultory.deposit(weth, 1, 1);

        vm.stopPrank();

        vm.expectRevert(Desultory.Desultory__ProtocolPositionAlreadyInitialized.selector);
        desultory.initializeProtocolPosition();
    }
 
    function testDepositNoPosition() public
    {
        // User 1
        uint256 depositAmount = 1e18;
        uint256 expectedPosition = 2;

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Desultory.Deposit(alice, expectedPosition, weth, depositAmount);
        desultory.deposit(weth, depositAmount);
        
        assertTrue(position.isOwner(alice, expectedPosition));
        assertEq(depositAmount, MockERC20(weth).balanceOf(address(desultory)));
        assertEq(depositAmount, desultory.getPositionCollateralForToken(expectedPosition, weth));
        assertEq(depositAmount, desultory.getPositionCollateralForToken(__protocolPositionId, weth));

        // User 2
        uint256 deposit2 = 5e15;
        uint256 position2 = 3;

        MockERC20(weth).mint(bob, 1000e18);
        vm.prank(bob);
        MockERC20(weth).approve(address(desultory), 100e18);

        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit Desultory.Deposit(bob, position2, weth, deposit2);
        desultory.deposit(weth, deposit2);
        
        assertTrue(position.isOwner(bob, position2));
        assertEq(deposit2, desultory.getPositionCollateralForToken(position2, weth));
        assertEq(deposit2 + depositAmount, desultory.getPositionCollateralForToken(__protocolPositionId, weth));
    }

    function testDepositWithPosition() public
    {
        // User 1
        uint256 depositAmount = 1e18;
        uint256 expectedPosition = 2;

        vm.startPrank(alice);

        desultory.deposit(weth, depositAmount);

        vm.expectEmit(true, true, true, true);
        emit Desultory.Deposit(alice, expectedPosition, weth, depositAmount * 2);
        desultory.deposit(weth, depositAmount * 2, expectedPosition);
        assertEq(depositAmount * 2 + depositAmount, desultory.getPositionCollateralForToken(expectedPosition, weth));
        assertEq(depositAmount * 2 + depositAmount, desultory.getPositionCollateralForToken(__protocolPositionId, weth));

        vm.stopPrank();
    }
}