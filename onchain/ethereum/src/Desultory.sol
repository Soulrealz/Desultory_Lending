pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";

// Libs
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

// Other contracts
import "./PositionNFT.sol";
import "./DUSD.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";

////////////////////////
import {console} from "forge-std/Test.sol";

contract Desultory is IERC721Receiver {
    ////////////////////////
    // Errors
    ////////////////////////
    error Desultory__ZeroAmount();
    error Desultory__OwnerMismatch();
    error Desultory__NoDepositMade();
    error Desultory__LTVRatioNotBroken();
    error Desultory__WithdrawalWillViolateLTV();
    error Desultory__CollateralValueNotEnough();
    error Desultory__AddressesAndFeedsDontMatch();
    error Desultory__NoExistingBorrow(address token);
    error Desultory__TokenNotWhitelisted(address token);
    error Desultory__ProtocolPositionAlreadyInitialized();
    error Desultory__ProtocolNotEnoughFunds(address token);

    ////////////////////////
    // Events
    ////////////////////////
    //@todo add event for update of global index
    event Borrow(uint256 indexed position, address indexed token, uint256 amount);
    event Repayment(uint256 indexed position, address indexed token, uint256 amount);
    event Withdrawal(uint256 indexed position, address indexed token, uint256 amount);
    event Deposit(address indexed user, uint256 indexed position, address indexed token, uint256 amount);
    event DebtRepayment(
        address indexed liquidator, uint256 indexed debtor, address indexed repaidAsset, uint256 amountLiquidated
    );
    event AssetLiquidation(
        address indexed liquidator, uint256 indexed debtor, address indexed liquidatedAsset, uint256 amountLiquidated
    );

    ///////////////////////
    // Types & interfaces
    ///////////////////////
    using SafeERC20 for IERC20;
    using OracleLib for AggregatorV3Interface;

    ////////////////////////
    // Structs
    ////////////////////////
    struct Collateral {
        address priceFeed;
        uint8 decimals;
        uint8 ltvRatio;
        uint16 borrowRate;
    }

    struct Interest {
        uint16 lowUtilization;
        uint16 normalUtilization;
        uint16 highUtilization;
        uint16 extremeUtilization;
        uint16 baseBorrowRate;
        uint16 lowBorrowRate;
        uint16 normalBorrowRate;
        uint16 highBorrowRate;
        uint16 extremeBorrowRate;
    }

    struct Borrower {
        uint256 lastTimestamp;
        mapping(address token => uint256 index) lastBorrowIndex;
        mapping(address token => uint256 amount) borrowedAmounts;
    }

    ////////////////////////
    // State Variables
    ////////////////////////

    // Protocol Variables
    uint256 private constant __protocolPositionId = 1;

    // Position Related User Variables
    mapping(uint256 position => mapping(address token => uint256 amount)) private __userCollaterals;
    mapping(uint256 position => Borrower info) private __userBorrows;
    mapping(address user => uint256 position) private __userPositions;
    uint256 private __liquidationPenalty = 10;

    // Token Variables
    mapping(address token => Collateral info) private __tokenInfos;
    mapping(uint256 tokenId => address token) private __tokenList;
    uint256 private __supportedTokensCount;

    // DUSD Variables
    uint256 private __protocolDebtInDUSD;
    uint256 private __totalFeesGenerated;

    // Contract Variables
    Position private __positionContract;
    DUSD private __DUSD;
    //@todo governor contract variable

    // Interest Variables
    Interest private __interest;
    uint16 private constant MAX_BPS = 10_000; // 100%
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    mapping(address token => uint256 index) private __globalBorrowIndex;
    mapping(address token => uint256 timestamp) private __lastUpdateTimestamp;

    ////////////////////////
    // Modifiers
    ////////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert Desultory__ZeroAmount();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (__tokenInfos[token].priceFeed == address(0)) {
            revert Desultory__TokenNotWhitelisted(token);
        }
        _;
    }

    ////////////////////////
    // constructor & init
    ////////////////////////

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeeds,
        uint8[] memory decimals,
        uint8[] memory ltvs,
        uint16[] memory rates,
        address _positionContract,
        address _DUSDContract
    ) {
        if (
            ltvs.length != priceFeeds.length || ltvs.length != tokenAddresses.length || ltvs.length != decimals.length
                || ltvs.length != rates.length
        ) {
            revert Desultory__AddressesAndFeedsDontMatch();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            __tokenInfos[tokenAddresses[i]] = Collateral(priceFeeds[i], decimals[i], ltvs[i], rates[i]);
            __tokenList[i] = tokenAddresses[i];
        }

        __supportedTokensCount = tokenAddresses.length;
        __positionContract = Position(_positionContract);
        __DUSD = DUSD(_DUSDContract);
        __interest = Interest({
            lowUtilization: 1500, // 15%
            normalUtilization: 8000, // 80%
            highUtilization: 9500, // 95%
            extremeUtilization: MAX_BPS, // 100%
            baseBorrowRate: 100, // 1%
            lowBorrowRate: 200, // 2%
            normalBorrowRate: 700, // 7%
            highBorrowRate: 3500, // 35%
            extremeBorrowRate: 6500 // 65%
        });
    }

    function initializeProtocolPosition() external {
        if (__userPositions[address(this)] != 0) {
            revert Desultory__ProtocolPositionAlreadyInitialized();
        }

        __userPositions[address(this)] = __positionContract.mint(address(this));
    }

    ////////////////////////
    // External Functions
    ////////////////////////

    // @todo for stablecoin LP providal
    // function depositStable()

    // @todo Add payable deposit for Ethereum deposits
    /**
     * @dev deposit X amount of Y token
     * @param token which token to deposit
     * @param amount how much of the token to deposit
     */
    function deposit(address token, uint256 amount) external moreThanZero(amount) isAllowedToken(token) {
        updateGlobalBorrowIndex(token);

        uint256 position = __userPositions[msg.sender];
        if (position == 0) {
            position = createPosition();
        }

        recordDeposit(token, amount);

        __userCollaterals[position][token] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, position, token, amount);
    }

    // @todo withdrawAll function
    /**
     * @dev function to withdraw a given token
     * @param token which token to withdraw deposit from
     * @param amount how much to withdraw
     */
    function withdraw(address token, uint256 amount) external moreThanZero(amount) isAllowedToken(token) {
        updateGlobalBorrowIndex(token);

        uint256 position = __userPositions[msg.sender];
        if (position == 0 || __userCollaterals[position][token] == 0) {
            revert Desultory__NoDepositMade();
        }

        updateBorrowerDebt(token, position);

        uint256 borrowedAmountUSD = getValueUSD(token, __userBorrows[position].borrowedAmounts[token]);
        uint256 depositedAmount = __userCollaterals[position][token];
        amount = depositedAmount < amount ? depositedAmount : amount;

        uint256 postWithdrawCollateralUSD = getValueUSD(token, depositedAmount - amount);
        uint256 newLTVToUphold = postWithdrawCollateralUSD * __tokenInfos[token].ltvRatio / 100;
        if (borrowedAmountUSD > newLTVToUphold) {
            revert Desultory__WithdrawalWillViolateLTV();
        }

        __userCollaterals[position][token] -= amount;

        recordWithdrawal(token, amount);
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawal(position, token, amount);
    }

    // @note to make a borrow for DUSD? is it necessary?
    // @note make a borrow for ETH
    // function borrow(uint256 amount) external moreThanZero(amount)
    // {
    //     this.borrow(address(__DUSD), amount);
    // }

    function borrow(address token, uint256 amount) external moreThanZero(amount) isAllowedToken(token) {
        updateGlobalBorrowIndex(token);

        uint256 position = __userPositions[msg.sender];
        if (position == 0) {
            revert Desultory__NoDepositMade();
        }

        if (amount > __userCollaterals[__protocolPositionId][token]) {
            revert Desultory__ProtocolNotEnoughFunds(token);
        }

        updateBorrowerDebt(token, position);

        uint256 desiredUSD = getValueUSD(token, amount);
        uint256 availableUSD = userMaxBorrowValueUSD(position);
        uint256 currentBorrowed = userBorrowedAmountUSD(position);
        if (currentBorrowed > 0) {
            availableUSD -= currentBorrowed;
        }

        if (desiredUSD > availableUSD) {
            revert Desultory__CollateralValueNotEnough();
        }

        Borrower storage borrower = __userBorrows[position];
        borrower.borrowedAmounts[token] += amount;
        borrower.lastTimestamp = block.timestamp;

        recordBorrow(token, amount);
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Borrow(position, token, amount);
    }

    // @note withdrawMulti ? for multi token withdrawal
    // @note payAndWithdraw

    // @todo
    // will allow others to repay your debt
    function repay(address token, uint256 amount) external moreThanZero(amount) isAllowedToken(token) {
        updateGlobalBorrowIndex(token);

        uint256 position = __userPositions[msg.sender];
        if (position == 0) {
            revert Desultory__NoDepositMade();
        }

        Borrower storage borrower = __userBorrows[position];
        if (borrower.borrowedAmounts[token] == 0) {
            revert Desultory__NoExistingBorrow(token);
        }

        updateBorrowerDebt(token, position);

        if (amount > borrower.borrowedAmounts[token]) {
            amount = borrower.borrowedAmounts[token];
        }

        borrower.borrowedAmounts[token] -= amount;
        borrower.lastTimestamp = block.timestamp;

        recordRepayment(token, amount);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Repayment(position, token, amount);
    }

    function liquidateAssetPosition(uint256 position, address tokenToRepay, address tokenToLiquidate) external {
        uint256 borrowedValueUSD = userBorrowedAmountUSD(position);
        uint256 maxBorrowValueUSD = userMaxBorrowValueUSD(position);

        if (maxBorrowValueUSD > borrowedValueUSD) {
            revert Desultory__LTVRatioNotBroken();
        }

        uint256 totalDebt = __userBorrows[position].borrowedAmounts[tokenToRepay];
        uint256 liquidatorFunds = IERC20(tokenToRepay).balanceOf(msg.sender);
        if (liquidatorFunds >= totalDebt) {
            __userBorrows[position].borrowedAmounts[tokenToRepay] = 0;

            uint256 collateralToTransfer =
                __userCollaterals[position][tokenToLiquidate] * (100 - __liquidationPenalty) / 100;
            __userCollaterals[position][tokenToLiquidate] =
                __userCollaterals[position][tokenToLiquidate] - collateralToTransfer;

            IERC20(tokenToRepay).safeTransferFrom(msg.sender, address(this), totalDebt);
            IERC20(tokenToRepay).safeTransfer(msg.sender, collateralToTransfer);

            emit DebtRepayment(msg.sender, position, tokenToRepay, totalDebt);
            emit AssetLiquidation(msg.sender, position, tokenToLiquidate, collateralToTransfer);
        } else {
            //@todo call flash
        }
    }

    // @todo
    function liquidateProportionalPosition(uint256 position, address tokenToRepay) external {
        uint256 borrowedValueUSD = userBorrowedAmountUSD(position);
        uint256 maxBorrowValueUSD = userMaxBorrowValueUSD(position);

        if (maxBorrowValueUSD > borrowedValueUSD) {
            revert Desultory__LTVRatioNotBroken();
        }

        uint256 totalDebt = __userBorrows[position].borrowedAmounts[tokenToRepay];
        uint256 liquidatorFunds = IERC20(tokenToRepay).balanceOf(msg.sender);

        if (liquidatorFunds >= totalDebt) {} else {}
    }

    function onERC721Received(address, /*operator*/ address, /*from*/ uint256, /*tokenId*/ bytes calldata /*data*/ )
        external
        pure
        override
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    ////////////////////////
    // Public Functions
    ////////////////////////

    function getPositionCollateralForToken(uint256 position, address token) public view returns (uint256) {
        return __userCollaterals[position][token];
    }

    function getValueUSD(address token, uint256 amount) public view returns (uint256) {
        Collateral memory collat = __tokenInfos[token];
        AggregatorV3Interface priceFeed = AggregatorV3Interface(collat.priceFeed);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        uint256 adjustedPrice = uint256(price) * (10 ** (18 - collat.decimals));
        uint256 adjustedAmount = amount * (10 ** (18 - collat.decimals));

        return (adjustedAmount * adjustedPrice) / 1e18;
    }

    function userBorrowedAmountUSD(uint256 position) public view returns (uint256) {
        uint256 totalUSD;
        for (uint256 i = 0; i < __supportedTokensCount; i++) {
            address token = __tokenList[i];
            uint256 amount = __userBorrows[position].borrowedAmounts[token];
            totalUSD += getValueUSD(token, amount);
        }

        return totalUSD;
    }

    function userCollateralValueUSD(uint256 position) public view returns (uint256) {
        uint256 totalUSD;
        for (uint256 i = 0; i < __supportedTokensCount; i++) {
            address token = __tokenList[i];
            uint256 amount = __userCollaterals[position][token];
            totalUSD += getValueUSD(token, amount);
        }

        return totalUSD;
    }

    function userMaxBorrowValueUSD(uint256 position) public view returns (uint256) {
        uint256 totalUSD;
        for (uint256 i = 0; i < __supportedTokensCount; i++) {
            address token = __tokenList[i];
            uint256 amount = __userCollaterals[position][token];
            totalUSD += (getValueUSD(token, amount) * __tokenInfos[token].ltvRatio / 100);
        }

        return totalUSD;
    }

    function getBorrowRate(address token, uint16 utilization) public view returns (uint16) {
        Interest memory interest = __interest;
        uint16 baseRate;

        // Very Low Utilization Case
        // FB = B + (U * L / Lu)
        if (utilization <= interest.lowUtilization) {
            baseRate = interest.baseBorrowRate + (utilization * interest.lowBorrowRate / interest.lowUtilization);
        }
        // Normal Utilization Case
        // FB = B + L + ((U - Lu) * (N - L) / (Nu - Lu))
        else if (utilization <= interest.normalUtilization) {
            uint16 excessUtilization = utilization - interest.lowUtilization;
            uint16 utilizationGap = interest.normalUtilization - interest.lowUtilization;

            baseRate = interest.baseBorrowRate + interest.lowBorrowRate
                + (excessUtilization * (interest.normalBorrowRate - interest.lowBorrowRate) / utilizationGap);
        }
        // High Utilization Case
        // FB = B + N + ((U - Nu) * (H - N) / (Hu - Nu))
        else if (utilization <= interest.highUtilization) {
            uint16 excessUtilization = utilization - interest.normalUtilization;
            uint16 utilizationGap = interest.highUtilization - interest.normalUtilization;

            baseRate = interest.baseBorrowRate + interest.normalBorrowRate
                + (excessUtilization * (interest.highBorrowRate - interest.normalBorrowRate) / utilizationGap);
        }
        // Extreme Utilization Case
        // FB = B + H + ((U - Hu) * (E - H) / (Eu - Hu))
        else {
            uint16 excessUtilization = utilization - interest.highUtilization;
            uint16 utilizationGap = interest.extremeUtilization - interest.highUtilization;

            baseRate = interest.baseBorrowRate + interest.highBorrowRate
                + (excessUtilization * (interest.extremeBorrowRate - interest.highBorrowRate) / utilizationGap);
        }

        return (baseRate * __tokenInfos[token].borrowRate) / 100;
    }

    // @note lower than 1e16 when collat is 1e18 and it will always return 0
    function getUtilization(address token) public view returns (uint16) {
        return uint16(
            (__userBorrows[__protocolPositionId].borrowedAmounts[token] * 100)
                / __userCollaterals[__protocolPositionId][token]
        );
    }

    ///////////////////////
    // Private Functions
    ///////////////////////

    function createPosition() private returns (uint256) {
        uint256 newPosition = __positionContract.mint(msg.sender);
        __userPositions[msg.sender] = newPosition;
        return newPosition;
    }

    /**
     * @dev functions to keep track of the assets
     * in the protocol and how they're used
     */
    function recordDeposit(address token, uint256 amount) private {
        __userCollaterals[__protocolPositionId][token] += amount;
    }

    function recordWithdrawal(address token, uint256 amount) private {
        __userCollaterals[__protocolPositionId][token] -= amount;
    }

    function recordBorrow(address token, uint256 amount) private {
        __userBorrows[__protocolPositionId].borrowedAmounts[token] += amount;
    }

    function recordRepayment(address token, uint256 amount) private {
        __userBorrows[__protocolPositionId].borrowedAmounts[token] -= amount;
    }
    ///////////////////////////////////////////////////////////////////////////////

    function updateGlobalBorrowIndex(address token) private {
        if (__lastUpdateTimestamp[token] != 0) {
            uint256 timeElapsed = block.timestamp - __lastUpdateTimestamp[token];
            if (timeElapsed == 0) return;

            uint16 borrowRate = getBorrowRate(token, getUtilization(token));
            uint256 interestFactor = ((borrowRate * timeElapsed * 1e18) / (SECONDS_PER_YEAR * MAX_BPS));

            __globalBorrowIndex[token] += (__globalBorrowIndex[token] * interestFactor) / 1e18;
            __lastUpdateTimestamp[token] = block.timestamp;
        } else {
            __globalBorrowIndex[token] = 1e18;
            __lastUpdateTimestamp[token] = block.timestamp;
        }
    }

    function updateBorrowerDebt(address token, uint256 position) private {
        Borrower storage borrower = __userBorrows[position];
        uint256 prevIndex = borrower.lastBorrowIndex[token];
        uint256 currIndex = __globalBorrowIndex[token];

        if (prevIndex > 0 && currIndex > prevIndex) {
            uint256 interestAccrued = (borrower.borrowedAmounts[token] * (currIndex - prevIndex)) / prevIndex;
            borrower.borrowedAmounts[token] += interestAccrued;
            recordBorrow(token, interestAccrued);
        }
        borrower.lastBorrowIndex[token] = currIndex;
    }

    ///////////////////////
    // Internal Functions
    ///////////////////////
}
