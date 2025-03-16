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


    function testInit() public
    {
        vm.expectRevert(Desultory.Desultory__ProtocolPositionAlreadyInitialized.selector);
        desultory.initializeProtocolPosition();
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

        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__TokenNotWhitelisted.selector, dead));
        desultory.deposit(dead, 1);

        vm.stopPrank();        
    }
 
    function testDeposit() public
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

    ///////////////////////
    // Withdraw Tests
    ///////////////////////
    function testWithdrawReverts() public 
    {
        vm.startPrank(alice);

        vm.expectRevert(Desultory.Desultory__ZeroAmount.selector);
        desultory.withdraw(weth, zeroAmount);

        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__TokenNotWhitelisted.selector, dead));
        desultory.withdraw(dead, 1);

        vm.expectRevert(Desultory.Desultory__NoDepositMade.selector);
        desultory.withdraw(weth, 1e18);
        
        desultory.deposit(weth, 1e18);

        vm.expectRevert(Desultory.Desultory__NoDepositMade.selector);
        desultory.withdraw(usdc, 1e18);

        desultory.borrow(weth, 1e9);

        vm.expectRevert(Desultory.Desultory__WithdrawalWillViolateLTV.selector);
        desultory.withdraw(weth, 1e18);

        vm.stopPrank();        
    }

    // @todo multiasset multiuser deposit (fuzzable)
    function testWithdraw() public
    {
        uint256 depositAmount = 1e18;
        uint256 balBefore = MockERC20(weth).balanceOf(alice);

        vm.startPrank(alice);

        desultory.deposit(weth, depositAmount);
        desultory.withdraw(weth, depositAmount);

        vm.stopPrank();

        assertEq(0, MockERC20(weth).balanceOf(address(desultory)));
        assertEq(0, desultory.getPositionCollateralForToken(2, weth));
        assertEq(0, desultory.getPositionCollateralForToken(__protocolPositionId, weth));
        assertEq(balBefore, MockERC20(weth).balanceOf(alice));
    }
}