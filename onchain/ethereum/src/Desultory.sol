pragma solidity 0.8.28;

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

    //@dev
    error NotImplemented();

    ////////////////////////
    // Events
    ////////////////////////
    event IndexUpdate(address indexed token, uint256 timestamp, uint256 index);
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

    // @note Add trusted/untrusted asset?
    // if trusted can be used for various things
    struct Collateral {
        address priceFeed;
        uint8 decimals;
        uint8 ltvRatio; // Loan To Value ratio that this asset provides
        uint16 borrowRate;  // Default fee for asset
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
        uint256 lastTimestamp;  // Last borrow timestamp
        mapping(address token => uint256 index) lastBorrowIndex;    // Per Token last global borrow index
        mapping(address token => uint256 amount) borrowedAmounts;
    }

    ////////////////////////
    // State Variables
    ////////////////////////

    // Protocol Variables
    uint256 private constant __protocolPositionId = 1;
    mapping(address token => uint256 amount) private __profit;

    // Position Related User Variables
    mapping(uint256 position => mapping(address token => uint256 amount)) private __userCollaterals;
    mapping(uint256 position => Borrower info) private __userBorrows;
    mapping(address user => uint256 position) private __userPositions;
    uint256 private __liquidationPenalty = 10;
    uint256 private __liquidationPenaltyProtocol = 3;

    // Token Variables
    mapping(address token => Collateral info) private __tokenInfos;
    mapping(uint256 tokenId => address token) private __tokenList;
    uint256 private __supportedTokensCount;

    // @todo
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

    /**
     * @dev Save the first position for the protocol
     */
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

    /**
     * @dev function to borrow given token
     * @param token which token to borrow
     * @param amount how much of that token to borrow
     */
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
    // @todo payAndWithdraw
    // @todo will allow others to repay your debt

    /**
     * @dev function that allows position owners to repay their owed debt
     * @param token which token to repay their debt for
     * @param amount how much of it to repay
     */
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

    /**
     * @dev function for the liquidation of a specific asset in a given position given a breached LTV ratio
     * Liquidators can use their own funds or the protocol's funds to liquidate
     * @param position which position to liquidate the asset for
     * @param tokenToRepay which token to repay the debt for (aka borrowed token)
     * @param tokenToLiquidate which token to liquidate from the collateral
     */
    function liquidateAssetPosition(uint256 position, address tokenToRepay, address tokenToLiquidate) external {
        uint256 borrowedValueUSD = userBorrowedAmountUSD(position);
        uint256 maxBorrowValueUSD = userMaxBorrowValueUSD(position);

        if (maxBorrowValueUSD > borrowedValueUSD) {
            revert Desultory__LTVRatioNotBroken();
        }

        uint256 collateralToTransfer = settleDebtSeizeCollateral(position, tokenToRepay, tokenToLiquidate);
        uint256 totalDebt = __userBorrows[position].borrowedAmounts[tokenToRepay];
        uint256 liquidatorFunds = IERC20(tokenToRepay).balanceOf(msg.sender);
        if (liquidatorFunds >= totalDebt) {
            IERC20(tokenToRepay).safeTransferFrom(msg.sender, address(this), totalDebt);
            IERC20(tokenToRepay).safeTransfer(msg.sender, collateralToTransfer);
        } else {
            if (IERC20(tokenToRepay).balanceOf(address(this)) >= totalDebt) {
                uint256 protocolLiquidationReward = collateralToTransfer * __liquidationPenaltyProtocol / 100;

                __profit[tokenToLiquidate] += collateralToTransfer - protocolLiquidationReward;
                IERC20(tokenToRepay).safeTransfer(msg.sender, protocolLiquidationReward);
                //@todo trusted untrusted asset
                // if untrusted convert profit to USDC to preserve value
            } else {
                //@todo call flash
                revert NotImplemented();
            }
        }

        emit DebtRepayment(msg.sender, position, tokenToRepay, totalDebt);
        emit AssetLiquidation(msg.sender, position, tokenToLiquidate, collateralToTransfer);
    }

    /**
     * @dev function that allows the liquidation of all assets in the position proportionally (eg: 20% each of an asset)
     * Liquidators can use their own funds
     * @param position which position to liquidate
     * @param tokenToRepay which token to repay the debt for (aka borrowed token)
     */
    function liquidateProportionalPosition(uint256 position, address tokenToRepay) external {
        uint256 borrowedValueUSD = userBorrowedAmountUSD(position);
        uint256 maxBorrowValueUSD = userMaxBorrowValueUSD(position);

        if (maxBorrowValueUSD > borrowedValueUSD) {
            revert Desultory__LTVRatioNotBroken();
        }

        Borrower storage borrower = __userBorrows[position];
        uint256 totalDebt = borrower.borrowedAmounts[tokenToRepay];
        uint256 liquidatorFunds = IERC20(tokenToRepay).balanceOf(msg.sender);

        // @note allow the use of the protocol's funds to liquidate?
        if (liquidatorFunds >= totalDebt) {
            borrower.borrowedAmounts[tokenToRepay] = 0;

            (address[] memory collateralTokens, uint256 totalCollateralUSD) = getPositionFullCollateralData(position);

            uint256 liquidationValueUSD = getValueUSD(tokenToRepay, totalDebt) * (100 - __liquidationPenalty) / 100;

            processCollateralLiquidation(
                position, collateralTokens, totalCollateralUSD, liquidationValueUSD, msg.sender
            );

            emit DebtRepayment(msg.sender, position, tokenToRepay, totalDebt);
        } else {
            //@todo call flash
            revert NotImplemented();
        }        
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

    function getPositionBorrowForToken(uint256 position, address token) public view returns (uint256) {
        return __userBorrows[position].borrowedAmounts[token];
    }

    /**
     * @dev Get the full details of a position
     * @param position which position to get the info for
     * @return tokens an array of collateral tokens associated with the position
     * @return totalUSD the total value of all assets in USD
     */
    function getPositionFullCollateralData(uint256 position)
        public
        view
        returns (address[] memory tokens, uint256 totalUSD)
    {
        tokens = new address[](__supportedTokensCount);
        totalUSD = 0;
        uint256 collatNumber = 0;

        for (uint256 i = 0; i < __supportedTokensCount; i++) {
            address collateralToken = __tokenList[i];
            uint256 collateralAmount = __userCollaterals[position][collateralToken];

            if (collateralAmount > 0) {
                tokens[collatNumber++] = collateralToken;
                totalUSD += getValueUSD(collateralToken, collateralAmount);
            }
        }

        assembly {
            mstore(tokens, collatNumber)
        }
    }

    /**
     * @dev get USD value of token amount
     * @param token which token to get the USD value of
     * @param amount how much of that token to get the value for
     */
    function getValueUSD(address token, uint256 amount) public view returns (uint256) {
        Collateral memory collat = __tokenInfos[token];
        AggregatorV3Interface priceFeed = AggregatorV3Interface(collat.priceFeed);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        uint256 adjustedPrice = uint256(price) * (10 ** (18 - collat.decimals));
        //uint256 adjustedAmount = amount * (10 ** (18 - collat.decimals));

        return (amount * adjustedPrice) / 1e18;
    }

    /**
     * @dev get a position's total debt in USD
     * @param position which position to get the debt for
     */
    function userBorrowedAmountUSD(uint256 position) public view returns (uint256) {
        uint256 totalUSD;
        for (uint256 i = 0; i < __supportedTokensCount; i++) {
            address token = __tokenList[i];
            uint256 amount = __userBorrows[position].borrowedAmounts[token];
            totalUSD += getValueUSD(token, amount);
        }

        return totalUSD;
    }

    /**
     * @dev get a position's total collateral value in USD
     * @param position which position to get the collateral value of
     */
    function userCollateralValueUSD(uint256 position) public view returns (uint256) {
        uint256 totalUSD;
        for (uint256 i = 0; i < __supportedTokensCount; i++) {
            address token = __tokenList[i];
            uint256 amount = __userCollaterals[position][token];

            if (amount > 0) {
                totalUSD += getValueUSD(token, amount);
            }
        }

        return totalUSD;
    }

    /**
     * @dev how much a position can max borrow, not including any current borrows
     * @param position which position to get the max borrow for
     */
    function userMaxBorrowValueUSD(uint256 position) public view returns (uint256) {
        // @note add update debt here?
        uint256 totalUSD;
        for (uint256 i = 0; i < __supportedTokensCount; i++) {
            address token = __tokenList[i];
            uint256 amount = __userCollaterals[position][token];
            totalUSD += (getValueUSD(token, amount) * __tokenInfos[token].ltvRatio / 100);
        }

        return totalUSD;
    }

    /**
     * @dev get the dynamic borrow rate of a token based on its utilization.
     * Currently split into 4 tiers - Very Low, Normal, High and Extreme utilization
     * Each tier covers different utilization percentages (eg from 0 to 15% for Very Low)
     * Each tier has a different borrow rate depending on the utilization tier
     * 
     * FB = Final rate, B = Base rate, L  = Low, N  = Normal, H  = High, E  = Extreme
     * U = Utilization,                Lu = Low, Nu = Normal, Hu = High, Eu = Extreme
     * 
     * @param token which token to get the rate of
     * @param utilization the utilization rate of the given token
     */
    function getBorrowRate(address token, uint16 utilization) public view returns (uint32) {
        Interest memory interest = __interest;
        uint32 baseRate;

        // Very Low Utilization Case
        // FB = B + (U * L / Lu)
        if (utilization <= interest.lowUtilization) {
            baseRate = interest.baseBorrowRate + (utilization * interest.lowBorrowRate / interest.lowUtilization);
        }
        // Normal Utilization Case
        // FB = B + L + ((U - Lu) * (N - L) / (Nu - Lu))
        else if (utilization <= interest.normalUtilization) {
            uint32 excessUtilization = utilization - interest.lowUtilization;
            uint32 utilizationGap = interest.normalUtilization - interest.lowUtilization;

            baseRate = interest.baseBorrowRate + interest.lowBorrowRate
                + (excessUtilization * (interest.normalBorrowRate - interest.lowBorrowRate) / utilizationGap);
        }
        // High Utilization Case
        // FB = B + N + ((U - Nu) * (H - N) / (Hu - Nu))
        else if (utilization <= interest.highUtilization) {
            uint32 excessUtilization = utilization - interest.normalUtilization;
            uint32 utilizationGap = interest.highUtilization - interest.normalUtilization;

            baseRate = interest.baseBorrowRate + interest.normalBorrowRate
                + (excessUtilization * (interest.highBorrowRate - interest.normalBorrowRate) / utilizationGap);
        }
        // Extreme Utilization Case
        // FB = B + H + ((U - Hu) * (E - H) / (Eu - Hu))
        else {
            uint32 excessUtilization = utilization - interest.highUtilization;
            uint32 utilizationGap = interest.extremeUtilization - interest.highUtilization;

            baseRate = interest.baseBorrowRate + interest.highBorrowRate
                + (excessUtilization * (interest.extremeBorrowRate - interest.highBorrowRate) / utilizationGap);
        }

        return (baseRate * __tokenInfos[token].borrowRate) / 100;
    }

    // @note lower than 1e13 when collat is 1e18 and it will always return 0
    /**
     * @dev Get the utilization for the given token given borrow amount against provided amount
     * @param token which token to get the util for
     */
    function getUtilization(address token) public view returns (uint16) {
        return uint16(
            (__userBorrows[__protocolPositionId].borrowedAmounts[token] * MAX_BPS)
                / __userCollaterals[__protocolPositionId][token]
        );
    }

    function getPriceFeedForToken(address token) public view returns (address) {
        return __tokenInfos[token].priceFeed;
    }

    ///////////////////////
    // Private Functions
    ///////////////////////

    /**
     * @dev create a position for a new user upon first deposit
     * @return ID of the new position
     */
    function createPosition() private returns (uint256) {
        uint256 newPosition = __positionContract.mint(msg.sender);
        __userPositions[msg.sender] = newPosition;
        return newPosition;
    }

    /**
     * @dev functions to keep track of the assets in the protocol
     * and all movements regarding them
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

    /**
     * @dev function that updates the global index for a given token thus accumulating fees
     * @param token which token to update the index for
     */
    function updateGlobalBorrowIndex(address token) private {
        if (__lastUpdateTimestamp[token] != 0) {
            uint256 timeElapsed = block.timestamp - __lastUpdateTimestamp[token];
            if (timeElapsed == 0) return;

            uint32 borrowRate = getBorrowRate(token, getUtilization(token));
            uint256 interestFactor = ((borrowRate * timeElapsed * 1e18) / (SECONDS_PER_YEAR * MAX_BPS));

            __globalBorrowIndex[token] += (__globalBorrowIndex[token] * interestFactor) / 1e18;
            __lastUpdateTimestamp[token] = block.timestamp;
        } else {
            __globalBorrowIndex[token] = 1e18;
            __lastUpdateTimestamp[token] = block.timestamp;
        }

        emit IndexUpdate(token, block.timestamp, __globalBorrowIndex[token]);
    }

    /**
     * @dev sync a borrower's debt with any changes to the global index
     * @param token which token to update the debt for
     * @param position which position to update it for
     */
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

    /**
     * @dev Clear a position's debt and reduce collateral according to a penalty
     * @param position which position to do that for
     * @param tokenToRepay which borrowed token is being cleared
     * @param tokenToLiquidate which collateral to liquidate
     */
    function settleDebtSeizeCollateral(uint256 position, address tokenToRepay, address tokenToLiquidate)
        private
        returns (uint256 collateralToTransfer)
    {
        __userBorrows[position].borrowedAmounts[tokenToRepay] = 0;

        collateralToTransfer = __userCollaterals[position][tokenToLiquidate] * (100 - __liquidationPenalty) / 100;

        __userCollaterals[position][tokenToLiquidate] =
            __userCollaterals[position][tokenToLiquidate] - collateralToTransfer;
    }

    /**
     * @dev reduce proportionally each collateral in a position
     * @param position which position to do that for
     * @param collateralTokens array with the position's assets
     * @param totalCollateralUSD total USD value of all of the position's assets
     * @param liquidationValueUSD total USD amount that should be liquidated from the position
     * @param liquidator actor that performs the liquidation
     */
    function processCollateralLiquidation(
        uint256 position,
        address[] memory collateralTokens,
        uint256 totalCollateralUSD,
        uint256 liquidationValueUSD,
        address liquidator
    ) private {
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            address collateralToken = collateralTokens[i];
            uint256 collateralAmount = __userCollaterals[position][collateralToken];

            uint256 proportion = getValueUSD(collateralToken, collateralAmount) / totalCollateralUSD;

            uint256 amountToLiquidate = (liquidationValueUSD * proportion)
                / getValueUSD(collateralToken, 10 ** __tokenInfos[collateralToken].decimals);

            __userCollaterals[position][collateralToken] -= amountToLiquidate;
            IERC20(collateralToken).transfer(liquidator, amountToLiquidate);

            emit AssetLiquidation(msg.sender, position, collateralToken, amountToLiquidate);
        }
    }

    ///////////////////////
    // Internal Functions
    ///////////////////////
}
