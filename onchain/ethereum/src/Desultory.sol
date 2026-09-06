pragma solidity 0.8.28;

// Libs
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Other contracts
import "./PositionNFT.sol";
import "./DUSD.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";

contract Desultory {
    ////////////////////////
    // Errors
    ////////////////////////
    error Desultory__ZeroAmount();
    error Desultory__LTVRatioNotBroken();
    error Desultory__WithdrawalWillViolateLTV();
    error Desultory__CollateralValueNotEnough();
    error Desultory__AddressesAndFeedsDontMatch();
    error Desultory__NoExistingBorrow(address token);
    error Desultory__TokenNotWhitelisted(address token);
    error Desultory__NotPositionOwner(uint256 positionId);
    error Desultory__PositionDoesNotExist(uint256 positionId);
    error Desultory__InsufficientLiquidity(address token);

    //@dev
    error NotImplemented();

    ////////////////////////
    // Events
    ////////////////////////
    event IndexUpdate(address indexed token, uint256 timestamp, uint256 borrowIndex, uint256 liquidityIndex);
    event PositionOpened(address indexed owner, uint256 indexed position);
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
        uint8 feedDecimals; // decimals of the Chainlink price feed
        uint8 tokenDecimals; // decimals of the ERC20 itself
        uint8 ltvRatio; // Loan To Value ratio that this asset provides
        uint16 borrowRate; // Per-asset rate multiplier, 100 = 1x
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

    /**
     * @dev per-token pool bookkeeping. Deposits and debts are stored SCALED:
     * scaled = amount * WAD / index at interaction time, so every position's
     * real balance (scaled * index / WAD) grows as the index grows.
     */
    struct Pool {
        uint256 liquidityIndex; // starts at WAD, grows with lender yield
        uint256 borrowIndex; // starts at WAD, grows with the borrow rate
        uint256 totalScaledDeposits;
        uint256 totalScaledBorrows;
        uint256 reserves; // protocol cut, token units
        uint40 lastUpdate;
    }

    ////////////////////////
    // State Variables
    ////////////////////////

    // Pool & Position Accounting
    mapping(address token => Pool pool) private __pools;
    mapping(uint256 position => mapping(address token => uint256 scaled)) private __scaledDeposits;
    mapping(uint256 position => mapping(address token => uint256 scaled)) private __scaledBorrows;

    // Liquidation Variables (redesign pending — see PROJECT_ASSESSMENT.md point 4)
    uint256 private __liquidationPenalty = 10;
    uint256 private __liquidationPenaltyProtocol = 3;
    mapping(address token => uint256 amount) private __profit;

    // Token Variables
    mapping(address token => Collateral info) private __tokenInfos;
    mapping(uint256 tokenId => address token) private __tokenList;
    uint256 private __supportedTokensCount;

    // Contract Variables
    Position private __positionContract;
    DUSD private __DUSD;

    // Interest Variables
    Interest private __interest;
    uint16 private constant MAX_BPS = 10_000; // 100%
    uint16 private constant RESERVE_FACTOR = 1_000; // 10% of borrow interest to the protocol
    uint256 private constant WAD = 1e18;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

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

    modifier onlyPositionOwner(uint256 positionId) {
        if (!__positionContract.exists(positionId)) {
            revert Desultory__PositionDoesNotExist(positionId);
        }
        if (__positionContract.ownerOf(positionId) != msg.sender) {
            revert Desultory__NotPositionOwner(positionId);
        }
        _;
    }

    ////////////////////////
    // constructor
    ////////////////////////

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeeds,
        uint8[] memory feedDecimals,
        uint8[] memory tokenDecimals,
        uint8[] memory ltvs,
        uint16[] memory rates,
        address _positionContract,
        address _DUSDContract
    ) {
        if (
            ltvs.length != priceFeeds.length || ltvs.length != tokenAddresses.length
                || ltvs.length != feedDecimals.length || ltvs.length != tokenDecimals.length || ltvs.length != rates.length
        ) {
            revert Desultory__AddressesAndFeedsDontMatch();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            __tokenInfos[tokenAddresses[i]] =
                Collateral(priceFeeds[i], feedDecimals[i], tokenDecimals[i], ltvs[i], rates[i]);
            __tokenList[i] = tokenAddresses[i];
            __pools[tokenAddresses[i]] = Pool({
                liquidityIndex: WAD,
                borrowIndex: WAD,
                totalScaledDeposits: 0,
                totalScaledBorrows: 0,
                reserves: 0,
                lastUpdate: uint40(block.timestamp)
            });
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

    ////////////////////////
    // External Functions
    ////////////////////////

    /**
     * @dev deposit X amount of Y token into a position.
     * Deposits into existing positions are permissionless — adding collateral
     * only ever benefits the position owner.
     * @param positionId which position to deposit into; 0 mints a new position to msg.sender
     * @param token which token to deposit
     * @param amount how much of the token to deposit
     */
    function deposit(uint256 positionId, address token, uint256 amount)
        external
        moreThanZero(amount)
        isAllowedToken(token)
    {
        accrue(token);

        if (positionId == 0) {
            positionId = __positionContract.mint(msg.sender);
            emit PositionOpened(msg.sender, positionId);
        } else if (!__positionContract.exists(positionId)) {
            revert Desultory__PositionDoesNotExist(positionId);
        }

        Pool storage pool = __pools[token];
        uint256 scaled = __toScaledDown(amount, pool.liquidityIndex);
        if (scaled == 0) {
            revert Desultory__ZeroAmount();
        }

        __scaledDeposits[positionId][token] += scaled;
        pool.totalScaledDeposits += scaled;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, positionId, token, amount);
    }

    /**
     * @dev withdraw deposited tokens. Pass type(uint256).max to withdraw everything.
     * @param positionId which position to withdraw from (must be its owner)
     * @param token which token to withdraw
     * @param amount how much to withdraw
     */
    function withdraw(uint256 positionId, address token, uint256 amount)
        external
        moreThanZero(amount)
        isAllowedToken(token)
        onlyPositionOwner(positionId)
    {
        accrue(token);
        Pool storage pool = __pools[token];

        uint256 scaledBalance = __scaledDeposits[positionId][token];
        uint256 balance = __fromScaledDown(scaledBalance, pool.liquidityIndex);
        if (balance == 0) {
            revert Desultory__ZeroAmount();
        }

        uint256 scaledAmount;
        if (amount >= balance) {
            amount = balance;
            scaledAmount = scaledBalance;
        } else {
            scaledAmount = __toScaledUp(amount, pool.liquidityIndex);
            if (scaledAmount > scaledBalance) {
                scaledAmount = scaledBalance;
            }
        }

        if (amount > getAvailableLiquidity(token)) {
            revert Desultory__InsufficientLiquidity(token);
        }

        __scaledDeposits[positionId][token] = scaledBalance - scaledAmount;
        pool.totalScaledDeposits -= scaledAmount;

        // portfolio-wide check: total debt must stay within total borrow capacity
        if (userBorrowedAmountUSD(positionId) > userMaxBorrowValueUSD(positionId)) {
            revert Desultory__WithdrawalWillViolateLTV();
        }

        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawal(positionId, token, amount);
    }

    /**
     * @dev borrow against the position's collateral (must be its owner)
     * @param positionId which position takes on the debt
     * @param token which token to borrow
     * @param amount how much of that token to borrow
     */
    function borrow(uint256 positionId, address token, uint256 amount)
        external
        moreThanZero(amount)
        isAllowedToken(token)
        onlyPositionOwner(positionId)
    {
        accrue(token);
        Pool storage pool = __pools[token];

        if (amount > getAvailableLiquidity(token)) {
            revert Desultory__InsufficientLiquidity(token);
        }

        uint256 desiredUSD = getValueUSD(token, amount);
        if (userBorrowedAmountUSD(positionId) + desiredUSD > userMaxBorrowValueUSD(positionId)) {
            revert Desultory__CollateralValueNotEnough();
        }

        uint256 scaled = __toScaledUp(amount, pool.borrowIndex);
        __scaledBorrows[positionId][token] += scaled;
        pool.totalScaledBorrows += scaled;

        IERC20(token).safeTransfer(msg.sender, amount);
        emit Borrow(positionId, token, amount);
    }

    /**
     * @dev repay a position's debt. Permissionless — anyone may repay anyone.
     * Pass type(uint256).max (or any amount >= debt) to repay everything.
     * @param positionId which position's debt to repay
     * @param token which borrowed token to repay
     * @param amount how much of it to repay
     */
    function repay(uint256 positionId, address token, uint256 amount)
        external
        moreThanZero(amount)
        isAllowedToken(token)
    {
        accrue(token);
        Pool storage pool = __pools[token];

        uint256 scaledDebt = __scaledBorrows[positionId][token];
        if (scaledDebt == 0) {
            revert Desultory__NoExistingBorrow(token);
        }

        uint256 debt = __fromScaledUp(scaledDebt, pool.borrowIndex);
        uint256 scaledRepaid;
        if (amount >= debt) {
            amount = debt;
            scaledRepaid = scaledDebt;
        } else {
            scaledRepaid = __toScaledDown(amount, pool.borrowIndex);
        }

        __scaledBorrows[positionId][token] = scaledDebt - scaledRepaid;
        pool.totalScaledBorrows -= scaledRepaid;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Repayment(positionId, token, amount);
    }

    /**
     * @dev LIQUIDATIONS ARE PENDING REDESIGN (PROJECT_ASSESSMENT.md point 4).
     * These two functions are only mechanically re-pointed at the new scaled
     * storage so the contract compiles; their economics are known-broken
     * (wrong-token payout, zero-rounding proportions, over-seizure) and they
     * remain untested on purpose.
     */
    function liquidateAssetPosition(uint256 position, address tokenToRepay, address tokenToLiquidate) external {
        if (isPositionHealthy(position)) {
            revert Desultory__LTVRatioNotBroken();
        }

        uint256 totalDebt = getPositionBorrowForToken(position, tokenToRepay);
        uint256 collateralToTransfer = settleDebtSeizeCollateral(position, tokenToRepay, tokenToLiquidate);
        uint256 liquidatorFunds = IERC20(tokenToRepay).balanceOf(msg.sender);
        if (liquidatorFunds >= totalDebt) {
            IERC20(tokenToRepay).safeTransferFrom(msg.sender, address(this), totalDebt);
            // @bug known: pays collateral amount in the repay token; pending redesign
            IERC20(tokenToRepay).safeTransfer(msg.sender, collateralToTransfer);
        } else {
            if (IERC20(tokenToRepay).balanceOf(address(this)) >= totalDebt) {
                uint256 protocolLiquidationReward = collateralToTransfer * __liquidationPenaltyProtocol / 100;
                __profit[tokenToLiquidate] += collateralToTransfer - protocolLiquidationReward;
                IERC20(tokenToRepay).safeTransfer(msg.sender, protocolLiquidationReward);
            } else {
                //@todo call flash
                revert NotImplemented();
            }
        }

        emit DebtRepayment(msg.sender, position, tokenToRepay, totalDebt);
        emit AssetLiquidation(msg.sender, position, tokenToLiquidate, collateralToTransfer);
    }

    function liquidateProportionalPosition(uint256 position, address tokenToRepay) external {
        if (isPositionHealthy(position)) {
            revert Desultory__LTVRatioNotBroken();
        }

        uint256 totalDebt = getPositionBorrowForToken(position, tokenToRepay);
        uint256 liquidatorFunds = IERC20(tokenToRepay).balanceOf(msg.sender);

        if (liquidatorFunds >= totalDebt) {
            Pool storage debtPool = __pools[tokenToRepay];
            debtPool.totalScaledBorrows -= __scaledBorrows[position][tokenToRepay];
            __scaledBorrows[position][tokenToRepay] = 0;

            (address[] memory collateralTokens, uint256 totalCollateralUSD) = getPositionFullCollateralData(position);
            uint256 liquidationValueUSD = getValueUSD(tokenToRepay, totalDebt) * (100 - __liquidationPenalty) / 100;

            processCollateralLiquidation(position, collateralTokens, totalCollateralUSD, liquidationValueUSD, msg.sender);

            emit DebtRepayment(msg.sender, position, tokenToRepay, totalDebt);
        } else {
            //@todo call flash
            revert NotImplemented();
        }
    }

    ////////////////////////
    // Public Functions
    ////////////////////////

    function getPositionCollateralForToken(uint256 position, address token) public view returns (uint256) {
        return __fromScaledDown(__scaledDeposits[position][token], __pools[token].liquidityIndex);
    }

    function getPositionBorrowForToken(uint256 position, address token) public view returns (uint256) {
        return __fromScaledUp(__scaledBorrows[position][token], __pools[token].borrowIndex);
    }

    /**
     * @dev liquidity users may borrow/withdraw: deposits − debt. The actual
     * cash on hand is deposits + reserves − debt, so capping flows here keeps
     * the protocol reserves' cash backing intact.
     */
    function getAvailableLiquidity(address token) public view returns (uint256) {
        Pool storage pool = __pools[token];
        uint256 deposits = __fromScaledDown(pool.totalScaledDeposits, pool.liquidityIndex);
        uint256 debt = __fromScaledUp(pool.totalScaledBorrows, pool.borrowIndex);
        return deposits > debt ? deposits - debt : 0;
    }

    function getPoolInfo(address token) external view returns (Pool memory) {
        return __pools[token];
    }

    function isPositionHealthy(uint256 positionId) public view returns (bool) {
        return userBorrowedAmountUSD(positionId) <= userMaxBorrowValueUSD(positionId);
    }

    /**
     * @dev Get the full details of a position
     * @param position which position to get the info for
     * @return tokens an array of collateral tokens associated with the position
     * @return totalUSD the total value of all assets in USD (18 decimals)
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
            uint256 collateralAmount = getPositionCollateralForToken(position, collateralToken);

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
     * @dev USD value of a token amount, normalized to 18 decimals regardless
     * of feed or token decimals.
     */
    function getValueUSD(address token, uint256 amount) public view returns (uint256) {
        Collateral memory collat = __tokenInfos[token];
        AggregatorV3Interface priceFeed = AggregatorV3Interface(collat.priceFeed);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        uint256 price18 = uint256(price) * (10 ** (18 - collat.feedDecimals));
        return (amount * price18) / (10 ** collat.tokenDecimals);
    }

    /**
     * @dev a position's total debt in USD (18 decimals)
     */
    function userBorrowedAmountUSD(uint256 position) public view returns (uint256) {
        uint256 totalUSD;
        for (uint256 i = 0; i < __supportedTokensCount; i++) {
            address token = __tokenList[i];
            uint256 amount = getPositionBorrowForToken(position, token);
            if (amount > 0) {
                totalUSD += getValueUSD(token, amount);
            }
        }
        return totalUSD;
    }

    /**
     * @dev a position's total collateral value in USD (18 decimals)
     */
    function userCollateralValueUSD(uint256 position) public view returns (uint256) {
        uint256 totalUSD;
        for (uint256 i = 0; i < __supportedTokensCount; i++) {
            address token = __tokenList[i];
            uint256 amount = getPositionCollateralForToken(position, token);
            if (amount > 0) {
                totalUSD += getValueUSD(token, amount);
            }
        }
        return totalUSD;
    }

    /**
     * @dev a position's max borrow capacity in USD (18 decimals), per-token LTV weighted
     */
    function userMaxBorrowValueUSD(uint256 position) public view returns (uint256) {
        uint256 totalUSD;
        for (uint256 i = 0; i < __supportedTokensCount; i++) {
            address token = __tokenList[i];
            uint256 amount = getPositionCollateralForToken(position, token);
            if (amount > 0) {
                totalUSD += (getValueUSD(token, amount) * __tokenInfos[token].ltvRatio / 100);
            }
        }
        return totalUSD;
    }

    /**
     * @dev dynamic borrow rate of a token based on its utilization.
     * 4 tiers — Very Low, Normal, High, Extreme. Unchanged from the original
     * implementation.
     *
     * FB = Final rate, B = Base rate, L  = Low, N  = Normal, H  = High, E  = Extreme
     * U = Utilization,                Lu = Low, Nu = Normal, Hu = High, Eu = Extreme
     */
    function getBorrowRate(address token, uint16 utilization) public view returns (uint32) {
        Interest memory interest = __interest;
        uint32 baseRate;

        // FB = B + (U * L / Lu)
        if (utilization <= interest.lowUtilization) {
            // uint32 math: uint16 * uint16 overflows for utilization >= 328
            baseRate =
                interest.baseBorrowRate + (uint32(utilization) * interest.lowBorrowRate / interest.lowUtilization);
        }
        // FB = B + L + ((U - Lu) * (N - L) / (Nu - Lu))
        else if (utilization <= interest.normalUtilization) {
            uint32 excessUtilization = utilization - interest.lowUtilization;
            uint32 utilizationGap = interest.normalUtilization - interest.lowUtilization;

            baseRate = interest.baseBorrowRate + interest.lowBorrowRate
                + (excessUtilization * (interest.normalBorrowRate - interest.lowBorrowRate) / utilizationGap);
        }
        // FB = B + N + ((U - Nu) * (H - N) / (Hu - Nu))
        else if (utilization <= interest.highUtilization) {
            uint32 excessUtilization = utilization - interest.normalUtilization;
            uint32 utilizationGap = interest.highUtilization - interest.normalUtilization;

            baseRate = interest.baseBorrowRate + interest.normalBorrowRate
                + (excessUtilization * (interest.highBorrowRate - interest.normalBorrowRate) / utilizationGap);
        }
        // FB = B + H + ((U - Hu) * (E - H) / (Eu - Hu))
        else {
            uint32 excessUtilization = utilization - interest.highUtilization;
            uint32 utilizationGap = interest.extremeUtilization - interest.highUtilization;

            baseRate = interest.baseBorrowRate + interest.highBorrowRate
                + (excessUtilization * (interest.extremeBorrowRate - interest.highBorrowRate) / utilizationGap);
        }

        return (baseRate * __tokenInfos[token].borrowRate) / 100;
    }

    /**
     * @dev pool utilization in BPS: totalDebt / totalDeposits, 0 for an empty
     * pool, capped at 100%.
     */
    function getUtilization(address token) public view returns (uint16) {
        Pool storage pool = __pools[token];
        uint256 deposits = __fromScaledDown(pool.totalScaledDeposits, pool.liquidityIndex);
        if (deposits == 0) {
            return 0;
        }
        uint256 debt = __fromScaledUp(pool.totalScaledBorrows, pool.borrowIndex);
        uint256 util = (debt * MAX_BPS) / deposits;
        return util >= MAX_BPS ? MAX_BPS : uint16(util);
    }

    function getPriceFeedForToken(address token) public view returns (address) {
        return __tokenInfos[token].priceFeed;
    }

    ///////////////////////
    // Private Functions
    ///////////////////////

    /**
     * @dev accrue interest for a token's pool since the last update:
     * grows the borrow index by the current rate, sends RESERVE_FACTOR of the
     * accrued interest to reserves, and grows the liquidity index with the rest.
     * Must be called at the top of every state-changing function.
     */
    function accrue(address token) private {
        Pool storage pool = __pools[token];
        uint256 dt = block.timestamp - pool.lastUpdate;
        if (dt == 0) {
            return;
        }
        pool.lastUpdate = uint40(block.timestamp);

        uint256 totalDebt = __fromScaledDown(pool.totalScaledBorrows, pool.borrowIndex);
        if (totalDebt == 0) {
            emit IndexUpdate(token, block.timestamp, pool.borrowIndex, pool.liquidityIndex);
            return;
        }

        uint32 rate = getBorrowRate(token, getUtilization(token));
        uint256 factor = (uint256(rate) * dt * WAD) / (SECONDS_PER_YEAR * MAX_BPS);

        uint256 interest = (totalDebt * factor) / WAD;
        uint256 toReserves = (interest * RESERVE_FACTOR) / MAX_BPS;

        pool.borrowIndex += (pool.borrowIndex * factor) / WAD;
        pool.reserves += toReserves;

        uint256 totalDeposits = __fromScaledDown(pool.totalScaledDeposits, pool.liquidityIndex);
        if (totalDeposits > 0) {
            pool.liquidityIndex += (pool.liquidityIndex * (interest - toReserves)) / totalDeposits;
        }

        emit IndexUpdate(token, block.timestamp, pool.borrowIndex, pool.liquidityIndex);
    }

    /**
     * @dev scaled-amount helpers. Rounding always favors the pool:
     * deposits round down (scaled credit), debts round up (owed amount).
     */
    function __toScaledDown(uint256 amount, uint256 index) private pure returns (uint256) {
        return (amount * WAD) / index;
    }

    function __toScaledUp(uint256 amount, uint256 index) private pure returns (uint256) {
        return (amount * WAD + index - 1) / index;
    }

    function __fromScaledDown(uint256 scaled, uint256 index) private pure returns (uint256) {
        return (scaled * index) / WAD;
    }

    function __fromScaledUp(uint256 scaled, uint256 index) private pure returns (uint256) {
        return (scaled * index + WAD - 1) / WAD;
    }

    /**
     * @dev PENDING REDESIGN — mechanically ported only. Clears the position's
     * debt bookkeeping and seizes 90% of the chosen collateral.
     */
    function settleDebtSeizeCollateral(uint256 position, address tokenToRepay, address tokenToLiquidate)
        private
        returns (uint256 collateralToTransfer)
    {
        Pool storage debtPool = __pools[tokenToRepay];
        debtPool.totalScaledBorrows -= __scaledBorrows[position][tokenToRepay];
        __scaledBorrows[position][tokenToRepay] = 0;

        Pool storage collateralPool = __pools[tokenToLiquidate];
        uint256 scaledCollateral = __scaledDeposits[position][tokenToLiquidate];
        uint256 scaledSeized = scaledCollateral * (100 - __liquidationPenalty) / 100;
        collateralToTransfer = __fromScaledDown(scaledSeized, collateralPool.liquidityIndex);

        __scaledDeposits[position][tokenToLiquidate] = scaledCollateral - scaledSeized;
        collateralPool.totalScaledDeposits -= scaledSeized;
    }

    /**
     * @dev PENDING REDESIGN — mechanically ported only (the proportion math
     * still zero-rounds for any collateral < 100% of the total).
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
            Pool storage pool = __pools[collateralToken];
            uint256 collateralAmount = getPositionCollateralForToken(position, collateralToken);

            uint256 proportion = getValueUSD(collateralToken, collateralAmount) / totalCollateralUSD;
            uint256 amountToLiquidate = (liquidationValueUSD * proportion)
                / getValueUSD(collateralToken, 10 ** __tokenInfos[collateralToken].tokenDecimals);

            uint256 scaledOut = __toScaledUp(amountToLiquidate, pool.liquidityIndex);
            __scaledDeposits[position][collateralToken] -= scaledOut;
            pool.totalScaledDeposits -= scaledOut;
            IERC20(collateralToken).safeTransfer(liquidator, amountToLiquidate);

            emit AssetLiquidation(msg.sender, position, collateralToken, amountToLiquidate);
        }
    }
}
