pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";

import {Desultory} from "../src/Desultory.sol";
import {Position} from "../src/PositionNFT.sol";
import {DUSD} from "../src/DUSD.sol";
import {Deploy} from "../script/Deploy.s.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockV3Aggregator.sol";

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract DesultoryTest is Test {
    Desultory desultory;
    Position position;
    DUSD dusd;
    Deploy deploy;

    uint256 private constant __protocolPositionId = 1;

    address weth;
    address usdc;

    address public alice = address(1);
    address public bob = address(2);
    address public lorem = address(3);
    address public ipsum = address(4);

    // Invalid Values
    uint256 zeroAmount = 0;
    address dead = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
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

    function testInit() public {
        vm.expectRevert(Desultory.Desultory__ProtocolPositionAlreadyInitialized.selector);
        desultory.initializeProtocolPosition();
    }

    ///////////////////////
    // Deposit Tests
    ///////////////////////
    // @todo multiasset multiuser deposit (fuzzable)
    function testDepositReverts() public {
        vm.startPrank(alice);

        vm.expectRevert(Desultory.Desultory__ZeroAmount.selector);
        desultory.deposit(weth, zeroAmount);

        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__TokenNotWhitelisted.selector, dead));
        desultory.deposit(dead, 1);

        vm.stopPrank();
    }

    function testDeposit() public {
        // User 1
        uint256 depositAmount = 1e18;
        uint256 expectedPosition = 2;

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Desultory.IndexUpdate(weth, block.timestamp, 1e18);
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
    function testWithdrawReverts() public {
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

    // @todo multiasset multiuser withdraw (fuzzable)
    function testWithdraw() public {
        uint256 depositAmount = 1e18;
        uint256 expectedPosition = 2;
        uint256 balBefore = MockERC20(weth).balanceOf(alice);

        vm.startPrank(alice);

        vm.expectEmit(true, true, true, true);
        emit Desultory.IndexUpdate(weth, block.timestamp, 1e18);
        desultory.deposit(weth, depositAmount);

        // @note why 4 true instead of 3?
        vm.expectEmit(true, true, true, true);
        emit Desultory.Withdrawal(expectedPosition, weth, depositAmount);
        desultory.withdraw(weth, depositAmount);

        vm.stopPrank();

        assertEq(0, MockERC20(weth).balanceOf(address(desultory)));
        assertEq(0, desultory.getPositionCollateralForToken(2, weth));
        assertEq(0, desultory.getPositionCollateralForToken(__protocolPositionId, weth));
        assertEq(balBefore, MockERC20(weth).balanceOf(alice));
    }

    ///////////////////////
    // Borrow Tests
    ///////////////////////

    // @todo multiasset multiuser borrow with time passes (fuzzable)
    function testBorrowReverts() public {
        uint256 depositAmount = 1e18;
        vm.startPrank(alice);

        vm.expectRevert(Desultory.Desultory__ZeroAmount.selector);
        desultory.borrow(weth, zeroAmount);

        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__TokenNotWhitelisted.selector, dead));
        desultory.borrow(dead, 1);

        vm.expectRevert(Desultory.Desultory__NoDepositMade.selector);
        desultory.borrow(weth, depositAmount);

        desultory.deposit(weth, depositAmount);

        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__ProtocolNotEnoughFunds.selector, weth));
        desultory.borrow(weth, depositAmount + 1);

        vm.expectRevert(Desultory.Desultory__CollateralValueNotEnough.selector);
        desultory.borrow(weth, depositAmount - 1);

        vm.stopPrank();
    }

    function testBorrow() public {
        uint256 depositAmount = 1e18;
        uint256 borrowAmount = 5e17;
        uint256 expectedPosition = 2;

        vm.startPrank(alice);

        vm.expectEmit(true, true, true, true);
        emit Desultory.IndexUpdate(weth, block.timestamp, 1e18);
        desultory.deposit(weth, depositAmount);
        uint256 balAfterDeposit = MockERC20(weth).balanceOf(alice);
        uint256 contractBalAfterDeposit = MockERC20(weth).balanceOf(address(desultory));

        vm.expectEmit(true, true, true, true);
        emit Desultory.Borrow(expectedPosition, weth, borrowAmount);
        desultory.borrow(weth, borrowAmount);

        vm.stopPrank();

        uint256 util = desultory.getUtilization(weth);

        assertEq(5000, util);
        assertEq(balAfterDeposit + borrowAmount, MockERC20(weth).balanceOf(alice));
        assertEq(contractBalAfterDeposit - borrowAmount, MockERC20(weth).balanceOf(address(desultory)));
    }

    function testBorrowAfterTime() public {
        uint256 depositAmount = 1e18;
        uint256 borrowAmount = 5e17;
        uint256 expectedPosition = 2;

        vm.startPrank(alice);

        desultory.deposit(weth, depositAmount);
        skip(1 days);
        MockV3Aggregator(desultory.getPriceFeedForToken(weth)).updateAnswer(2005 * 1e8);
        MockV3Aggregator(desultory.getPriceFeedForToken(usdc)).updateAnswer(1 * 1e6);

        uint256 rate = 400;
        uint256 num = (rate * 1 days * 1e18);
        uint256 denum = (365 days * 10_000);
        uint256 interest = (num / denum);
        uint256 index = 1e18 + (1e18 * interest / 1e18);

        vm.expectEmit(true, true, true, true);
        emit Desultory.IndexUpdate(weth, block.timestamp, index);
        desultory.borrow(weth, borrowAmount);
        
        skip(1 days);
        MockV3Aggregator(desultory.getPriceFeedForToken(weth)).updateAnswer(2005 * 1e8);
        MockV3Aggregator(desultory.getPriceFeedForToken(usdc)).updateAnswer(1 * 1e6);

        rate = 300; // low + base
        uint256 excess = 3500;
        uint256 gap = 6500;
        uint256 calcRate = rate + (excess * 500) / gap;
        uint256 finalRate = (calcRate * 400) / 100;
        num = (finalRate * 1 days * 1e18);
        interest = num / denum;
        index = index + (index * interest / 1e18);

        vm.expectEmit(true, true, true, true);
        emit Desultory.IndexUpdate(weth, block.timestamp, index);
        desultory.borrow(weth, borrowAmount / 5);

        uint256 totalBorrow = desultory.getPositionBorrowForToken(expectedPosition, weth);

        vm.stopPrank();
    }

    ///////////////////////
    // Repay Tests
    ///////////////////////
    // @todo multiasset multiuser repay with time passes (fuzzable)
    function testRepayReverts() public {
        vm.startPrank(alice);

        vm.expectRevert(Desultory.Desultory__ZeroAmount.selector);
        desultory.repay(weth, zeroAmount);

        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__TokenNotWhitelisted.selector, dead));
        desultory.repay(dead, 1);

        vm.expectRevert(Desultory.Desultory__NoDepositMade.selector);
        desultory.repay(weth, 1);

        desultory.deposit(weth, 1);

        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__NoExistingBorrow.selector, weth));
        desultory.repay(weth, 1);

        vm.stopPrank();
    }

    function testRepay() public {
        uint256 depositAmount = 1e18;
        uint256 borrowAmount = 5e17;
        uint256 expectedPosition = 2;

        vm.startPrank(alice);

        vm.expectEmit(true, true, true, true);
        emit Desultory.IndexUpdate(weth, block.timestamp, 1e18);
        desultory.deposit(weth, depositAmount);
        desultory.borrow(weth, borrowAmount);

        vm.expectEmit(true, true, true, true);
        emit Desultory.Repayment(expectedPosition, weth, borrowAmount / 2);
        desultory.repay(weth, borrowAmount / 2);

        vm.stopPrank();
    }
}
