pragma solidity 0.8.28;

// Libs
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Other contracts
import "./PositionNFT.sol";
import "./DUSD.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {LiquidationMath} from "./libraries/LiquidationMath.sol";

/**
 * @dev the slice of the cross-chain Adapter the accounting core needs.
 *
 * The real sendMint returns a MessagingReceipt struct; declaring no return value
 * here is deliberate. Solidity skips return decoding entirely when none is declared,
 * so the call succeeds and the receipt is discarded, and this contract never has to
 * import LayerZero types. Do NOT "fix" this by declaring returns (bytes memory) —
 * the ABI decoder would then read a struct as dynamic bytes and revert.
 */
interface IAdapter {
    function sendMint(uint32 dstEid, address recipient, uint256 amount, bytes calldata options, address refund)
        external
        payable;
}

contract Desultory is Ownable, ReentrancyGuard {
    ////////////////////////
    // Errors
    ////////////////////////
    error Desultory__ZeroAmount();
    error Desultory__WithdrawalWillViolateLTV();
    error Desultory__CollateralValueNotEnough();
    error Desultory__InvalidRiskParams(address token);
    error Desultory__NoExistingBorrow(address token);
    error Desultory__TokenNotWhitelisted(address token);
    error Desultory__NotPositionOwner(uint256 positionId);
    error Desultory__PositionDoesNotExist(uint256 positionId);
    error Desultory__InsufficientLiquidity(address token);
    error Desultory__FeeTooHigh();
    error Desultory__ZeroAddress();
    error Desultory__InsufficientReserves(address token);
    error Desultory__NoDusdDebt(uint256 positionId);
    error Desultory__AdapterNotSet();
    error Desultory__DestinationNotAllowed(uint32 eid);
    error Desultory__NotLiquidatable(uint256 positionId, uint256 healthFactor);
    error Desultory__NoDebtInAsset(uint256 positionId, address asset);

    ////////////////////////
    // Events
    ////////////////////////
    event IndexUpdate(address indexed token, uint256 timestamp, uint256 borrowIndex, uint256 liquidityIndex);
    event PositionOpened(address indexed owner, uint256 indexed position);
    event Borrow(uint256 indexed position, address indexed token, uint256 amount);
    event Repayment(uint256 indexed position, address indexed token, uint256 amount);
    event Withdrawal(uint256 indexed position, address indexed token, uint256 amount);
    event Deposit(address indexed user, uint256 indexed position, address indexed token, uint256 amount);
    event AdapterSet(address indexed adapter);
    event DestinationSet(uint32 indexed eid, bool allowed);
    event DusdStabilityFeeSet(uint16 bps);
    event ReservesWithdrawn(address indexed token, address indexed to, uint256 amount);
    event BackstopCommitted(address indexed token, uint256 amount);
    event BackstopReleased(address indexed token, uint256 amount);
    event DusdBorrow(uint256 indexed position, address indexed recipient, uint256 amount, uint32 dstEid);
    event DusdRepay(uint256 indexed position, address indexed payer, uint256 amount);
    event DusdIndexUpdate(uint256 timestamp, uint256 dusdBorrowIndex, uint256 dusdReserves);
    event Liquidation(
        address indexed liquidator,
        uint256 indexed position,
        address debtAsset,
        address collateralAsset,
        uint256 repaid,
        uint256 seized,
        uint256 protocolCut
    );
    event BadDebtRecorded(uint256 indexed positionId, uint256 amountUSD);

    ///////////////////////
    // Types & interfaces
    ///////////////////////
    using SafeERC20 for IERC20;
    using OracleLib for AggregatorV3Interface;

    ////////////////////////
    // Structs
    ////////////////////////

    struct Collateral {
        address priceFeed; // 20 bytes
        uint8 feedDecimals; // decimals of the Chainlink price feed
        uint8 tokenDecimals; // decimals of the ERC20 itself
        uint8 ltvRatio; // borrow cap, percent
        uint8 liquidationThreshold; // seize line, percent — strictly above ltvRatio
        uint16 liquidationBonusBps; // discount handed to a liquidator
        uint16 borrowRate; // per-asset rate multiplier, 100 = 1x
    } // 28 bytes — still one slot

    /// @dev one struct instead of six parallel arrays: mismatched lengths become
    /// unrepresentable, and eight arrays would risk stack-too-deep in the constructor.
    struct TokenConfig {
        address token;
        address priceFeed;
        uint8 feedDecimals;
        uint8 tokenDecimals;
        uint8 ltvRatio;
        uint8 liquidationThreshold;
        uint16 liquidationBonusBps;
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

    /**
     * @dev per-token pool bookkeeping. Deposits and debts are stored SCALED:
     * scaled = amount * WAD / index at interaction time, so every position's
     * real balance (scaled * index / WAD) grows as the index grows.
     */
    struct Pool {
        uint256 liquidityIndex; // starts at WAD, grows with lender yield
        uint256 borrowIndex; // starts at WAD, grows with the borrow rate
        uint256 totalScaledDeposits;
        // the protocol's own share of totalScaledDeposits, funded out of reserves by the
        // liquidation backstop. A SUBSET of the line above, never a parallel figure: it is
        // included in every deposits total, utilization read and index distribution. It is
        // deliberately not a position, so withdraw() — which keys off
        // __scaledDeposits[positionId][token] and onlyPositionOwner — cannot reach it.
        uint256 backstopScaledDeposits;
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

    // Token Variables
    mapping(address token => Collateral info) private __tokenInfos;
    mapping(uint256 tokenId => address token) private __tokenList;
    uint256 private __supportedTokensCount;

    // Contract Variables
    Position private __positionContract;
    DUSD private __DUSD;

    // DUSD debt. Stored separately from __pools: DUSD is minted, not deposited, so it
    // has no liquidity side, no utilization, and no lender share.
    uint256 public dusdBorrowIndex;
    uint40 private __dusdLastUpdate;
    uint256 public totalScaledDusdDebt;
    uint256 public dusdReserves;
    mapping(uint256 position => uint256 scaled) private __scaledDusdDebt;

    /**
     * @dev USD value of debt recognized as uncollectable, 18 decimals.
     *
     * A monotone counter of RECOGNIZED loss, snapshotted at the moment collateral ran out.
     * It does not track prices afterward and is not decremented if the position is later
     * topped up. Anything better needs a loss-allocation policy, which is deliberately not
     * part of this project — nothing here writes down liquidityIndex.
     */
    uint256 public totalBadDebtUSD;

    // Cross-chain Configuration
    address public adapter;
    mapping(uint32 eid => bool allowed) public allowedDestination;
    uint16 public dusdStabilityFeeBps;

    // Interest Variables
    Interest private __interest;
    uint16 private constant MAX_BPS = 10_000; // 100%
    uint16 private constant MAX_BONUS_BPS = 2_000; // 20% — constructor cap
    uint16 private constant LIQ_PROTOCOL_SHARE = 3_000; // 30% of the bonus
    uint16 private constant LIQ_BACKSTOP_SHARE = 7_000; // 70% when the protocol funds the seizure
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

    constructor(TokenConfig[] memory configs, address _positionContract, address _DUSDContract)
        Ownable(msg.sender)
    {
        for (uint256 i = 0; i < configs.length; i++) {
            TokenConfig memory c = configs[i];

            // a threshold at or below the LTV leaves no buffer band: the position would
            // become liquidatable at the exact instant it reached maximum borrow.
            if (
                c.liquidationThreshold <= c.ltvRatio || c.liquidationThreshold > 100
                    || c.liquidationBonusBps > MAX_BONUS_BPS
            ) {
                revert Desultory__InvalidRiskParams(c.token);
            }

            __tokenInfos[c.token] = Collateral(
                c.priceFeed,
                c.feedDecimals,
                c.tokenDecimals,
                c.ltvRatio,
                c.liquidationThreshold,
                c.liquidationBonusBps,
                c.borrowRate
            );
            __tokenList[i] = c.token;
            __pools[c.token] = Pool({
                liquidityIndex: WAD,
                borrowIndex: WAD,
                totalScaledDeposits: 0,
                backstopScaledDeposits: 0,
                totalScaledBorrows: 0,
                reserves: 0,
                lastUpdate: uint40(block.timestamp)
            });
        }

        __supportedTokensCount = configs.length;
        dusdBorrowIndex = WAD;
        __dusdLastUpdate = uint40(block.timestamp);
        dusdStabilityFeeBps = 200; // 2% annual default
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
    // Admin Functions
    ////////////////////////

    /// @dev the cross-chain Adapter permitted to be paid for mint authorizations
    function setAdapter(address _adapter) external onlyOwner {
        adapter = _adapter;
        emit AdapterSet(_adapter);
    }

    /// @dev destination chains a position may mint DUSD to
    function setAllowedDestination(uint32 eid, bool allowed) external onlyOwner {
        allowedDestination[eid] = allowed;
        emit DestinationSet(eid, allowed);
    }

    /**
     * @dev withdraw a token pool's accumulated protocol revenue.
     *
     * Reserves fill from three places: the RESERVE_FACTOR cut of borrow interest, and
     * LIQ_PROTOCOL_SHARE of every liquidation bonus, both in this token. Until now there
     * was no way out of the contract for either.
     *
     * This cannot strand depositors. The identity getAvailableLiquidity documents is
     * cash = deposits + reserves - debt; withdrawing X drops the balance by X and
     * reserves by X, so both sides of it fall together. That is why no liquidity gate is
     * needed here, unlike withdraw() and borrow(), which move deposits against a fixed
     * reserve backing.
     *
     * DUSD reserves are deliberately NOT withdrawable here. dusdReserves is a claim, not
     * a balance: borrowDUSD mints to the borrower and repayDUSD burns from the payer, so
     * the protocol never holds DUSD. Paying it out would mean minting unbacked supply,
     * which is a monetary decision belonging with the peg design, not with treasury
     * plumbing.
     */
    function withdrawReserves(address token, address to, uint256 amount)
        external
        onlyOwner
        moreThanZero(amount)
        isAllowedToken(token)
    {
        if (to == address(0)) {
            revert Desultory__ZeroAddress();
        }

        // reserves grow during accrual; reading them first would pay out a stale figure
        accrue(token);

        Pool storage pool = __pools[token];
        if (amount > pool.reserves) {
            revert Desultory__InsufficientReserves(token);
        }

        pool.reserves -= amount;

        IERC20(token).safeTransfer(to, amount);
        emit ReservesWithdrawn(token, to, amount);
    }

    /**
     * @dev return committed backstop capital to the pool's reserves.
     *
     * The reverse of _commitBackstop, and it moves no tokens either. Cash leaves the
     * contract only through withdrawReserves, so there stays exactly one door out and its
     * custody argument is unchanged. Interest the backstop deposit earned through
     * liquidityIndex is realized into reserves on the way through.
     *
     * Unlike withdrawReserves this DOES need a liquidity gate: it lowers deposits against a
     * fixed reserve backing, exactly as withdraw() does, rather than moving both lines
     * together. Same gate, same reason.
     *
     * The shape deliberately mirrors withdraw() — full-balance shortcut, __toScaledUp for
     * the partial case so the protocol gives up at least the scaled amount it redeems,
     * clamp, then the gate — so the two read as the same operation.
     */
    function releaseBackstop(address token, uint256 amount)
        external
        onlyOwner
        moreThanZero(amount)
        isAllowedToken(token)
    {
        // the backstop deposit grows with the index; reading it first would release a
        // stale figure and strand the interest it earned
        accrue(token);

        Pool storage pool = __pools[token];

        uint256 scaledBalance = pool.backstopScaledDeposits;
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

        pool.backstopScaledDeposits = scaledBalance - scaledAmount;
        pool.totalScaledDeposits -= scaledAmount;
        pool.reserves += amount;

        emit BackstopReleased(token, amount);
    }

    /**
     * @dev annual DUSD stability fee in BPS. Flat, not a utilization curve: nobody
     * deposits DUSD, so utilization would be permanently zero and the kinked model
     * would return the base rate no matter how much is outstanding.
     */
    function setDusdStabilityFee(uint16 bps) external onlyOwner {
        if (bps > MAX_BPS) revert Desultory__FeeTooHigh();
        // settle at the old rate first: repricing outstanding debt retroactively
        // would charge interest that was never agreed to
        accrueDusd();
        dusdStabilityFeeBps = bps;
        emit DusdStabilityFeeSet(bps);
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
     * @dev seize collateral from an under-water position in exchange for retiring its debt.
     *
     * Replaces an engine with seven catalogued defects. The ones that shaped this:
     * value moves by allowance and never from protocol funds; the bonus is a bonus, not a
     * haircut; seizure is bounded by a close factor; and everything accrues before anything
     * is read.
     *
     * @param positionId the position to liquidate
     * @param debtAsset which debt to retire — DUSD or any whitelisted token
     * @param collateralAsset which collateral to seize
     * @param repayAmount how much debt to retire; clamped down to the close factor
     */
    function liquidate(uint256 positionId, address debtAsset, address collateralAsset, uint256 repayAmount)
        external
        nonReentrant
        moreThanZero(repayAmount)
        isAllowedToken(collateralAsset)
    {
        _liquidate(positionId, debtAsset, collateralAsset, repayAmount, false);
    }

    /**
     * @dev liquidate against a pool that cannot spare the liquidity, funding the seizure
     * from the protocol's own reserves.
     *
     * Identical to liquidate() in every respect but two: the seizure cap may draw on
     * reserves converted to a protocol-owned deposit (see _commitBackstop), and the
     * protocol keeps LIQ_BACKSTOP_SHARE of the bonus rather than LIQ_PROTOCOL_SHARE.
     *
     * A separate entry point rather than an automatic fallback inside liquidate(), so a
     * liquidator that quoted its profit off the ordinary split is never silently paid less.
     * Choosing this function is the consent.
     */
    function liquidateWithBackstop(uint256 positionId, address debtAsset, address collateralAsset, uint256 repayAmount)
        external
        nonReentrant
        moreThanZero(repayAmount)
        isAllowedToken(collateralAsset)
    {
        _liquidate(positionId, debtAsset, collateralAsset, repayAmount, true);
    }

    function _liquidate(
        uint256 positionId,
        address debtAsset,
        address collateralAsset,
        uint256 repayAmount,
        bool useBackstop
    ) private {
        if (debtAsset != address(__DUSD) && __tokenInfos[debtAsset].priceFeed == address(0)) {
            revert Desultory__TokenNotWhitelisted(debtAsset);
        }
        if (!__positionContract.exists(positionId)) {
            revert Desultory__PositionDoesNotExist(positionId);
        }

        _accrueAll();

        // clamp, rather than revert, so a bot that loses a race takes a partial fill
        // instead of burning a transaction. hf and debt are only needed to derive maxRepay
        // and are scoped to this block so they don't sit on the stack for the rest of the
        // function — maxRepay itself is kept alive below so the close-factor bound stays
        // locally evident at its second use.
        uint256 maxRepay;
        {
            uint256 hf = healthFactor(positionId);
            if (hf >= WAD) {
                revert Desultory__NotLiquidatable(positionId, hf);
            }

            uint256 debt = _debtInAsset(positionId, debtAsset);
            if (debt == 0) {
                revert Desultory__NoDebtInAsset(positionId, debtAsset);
            }

            maxRepay = (debt * LiquidationMath.closeFactorBps(hf)) / MAX_BPS;
        }
        if (repayAmount > maxRepay) {
            repayAmount = maxRepay;
        }

        uint16 bonusBps = __tokenInfos[collateralAsset].liquidationBonusBps;

        uint256 seizeAmount = _usdToTokenAmount(
            collateralAsset, LiquidationMath.seizeFromRepay(_debtValueUSD(debtAsset, repayAmount), bonusBps)
        );

        // The position may not hold enough, and the pool may not have enough uncommitted
        // liquidity to give up (collateral pools back other positions' debt too — the same
        // bound withdraw() and borrow() already enforce via getAvailableLiquidity, and the
        // one _seizeCollateral itself does not check). Cap the seizure at the lesser of what
        // is there and what the pool can spare, and recompute the repayment DOWN from the
        // capped figure — charging the original amount for a short delivery is the same
        // class of bug as paying out in the wrong token.
        uint256 seizeCap = getPositionCollateralForToken(positionId, collateralAsset);
        if (seizeAmount < seizeCap) {
            seizeCap = seizeAmount;
        }

        // On the backstop path, give the pool the liquidity first. Sized against seizeCap
        // rather than seizeAmount so the commit is bounded by the seizure that can actually
        // happen rather than the one that was asked for: reserves are never converted to
        // unlock liquidity for collateral that is not there. It is a bound on the amount,
        // not a guard against committing — a position short of collateral in a pool short
        // of liquidity still commits, just sized to the smaller figure. Then read
        // availability fresh: the commit raises deposits, so a figure taken beforehand is
        // stale by construction.
        if (useBackstop) {
            _commitBackstop(collateralAsset, seizeCap);
        }
        {
            uint256 availableLiquidity = getAvailableLiquidity(collateralAsset);
            if (availableLiquidity < seizeCap) {
                seizeCap = availableLiquidity;
            }
        }
        if (seizeAmount > seizeCap) {
            seizeAmount = seizeCap;
            repayAmount = _debtAmountFromUSD(
                debtAsset, LiquidationMath.repayFromSeize(getValueUSD(collateralAsset, seizeAmount), bonusBps)
            );

            // the recomputed repayment can still exceed the close-factor bound when rounding
            // runs the wrong way; clamp to the same maxRepay computed above rather than to
            // debt itself, so the close-factor bound stays locally evident here too
            if (repayAmount > maxRepay) {
                repayAmount = maxRepay;
            }
            if (repayAmount == 0) {
                revert Desultory__ZeroAmount();
            }
        }

        uint256 baseAmount = LiquidationMath.repayFromSeize(seizeAmount, bonusBps);
        (uint256 protocolCut, uint256 toLiquidator) = LiquidationMath.splitBonus(
            baseAmount, seizeAmount, useBackstop ? LIQ_BACKSTOP_SHARE : LIQ_PROTOCOL_SHARE
        );

        // --- effects, then an external call ---
        // _retireDebt itself performs an external call (DUSD burn, or safeTransferFrom for a
        // pool asset) rather than pure bookkeeping. That is safe here despite sitting after
        // _seizeCollateral: this function is nonReentrant, and the only other entry points
        // that read this position's state (withdraw/borrow) are bounded by accounting figures
        // this call has already updated, not by a balance check that a reentrant call could
        // race ahead of.
        _seizeCollateral(positionId, collateralAsset, seizeAmount, protocolCut);
        _retireDebt(positionId, debtAsset, repayAmount);

        // --- interactions ---
        IERC20(collateralAsset).safeTransfer(msg.sender, toLiquidator);

        _recordBadDebtIfStranded(positionId);

        emit Liquidation(
            msg.sender, positionId, debtAsset, collateralAsset, repayAmount, seizeAmount, protocolCut
        );
    }

    /**
     * @dev remove seized collateral from the position and book the protocol's cut.
     *
     * The scaled conversion rounds UP: the borrower gives up at least the scaled amount the
     * seizure warrants, which is the same direction withdraw() uses.
     *
     * The cut stays denominated in the seized token and lands in that pool's reserves, so it
     * never leaves the contract — which is why custody still reconciles: deposits fall by
     * `seizeAmount`, the balance falls by `seizeAmount - protocolCut`, reserves rise by
     * `protocolCut`.
     */
    function _seizeCollateral(uint256 positionId, address collateralAsset, uint256 seizeAmount, uint256 protocolCut)
        private
    {
        Pool storage pool = __pools[collateralAsset];
        uint256 scaled = __toScaledUp(seizeAmount, pool.liquidityIndex);

        __scaledDeposits[positionId][collateralAsset] -= scaled;
        pool.totalScaledDeposits -= scaled;
        pool.reserves += protocolCut;
    }

    /**
     * @dev convert protocol reserves into a protocol-owned deposit so a seizure of up to
     * `want` can proceed without leaving the pool's deposits below its debt.
     *
     * No token moves: reserves are already cash sitting in this contract. Only the split
     * between "protocol revenue" and "deposit base" changes, so the balance is untouched
     * and both sides of cash = deposits + reserves - debt fall together —
     * property_custodyReconciles is preserved by construction, not by a check, the same
     * argument withdrawReserves makes.
     *
     * The protocol becomes a lender in a pool it cannot withdraw from until utilization
     * falls. That liquidity risk is the real cost of the backstop, and it is what
     * LIQ_BACKSTOP_SHARE pays for.
     */
    function _commitBackstop(address token, uint256 want) private {
        Pool storage pool = __pools[token];

        // deposits round DOWN and debt rounds UP, each the direction that understates the
        // pool's own position, so the deficit sized against below is never too small
        uint256 deposits = __fromScaledDown(pool.totalScaledDeposits, pool.liquidityIndex);
        uint256 debt = __fromScaledUp(pool.totalScaledBorrows, pool.borrowIndex);

        // deposits + X must cover debt + want, so the seizure leaves deposits >= debt.
        //
        // Sized against the raw figures rather than getAvailableLiquidity, deliberately.
        // That view clamps a deposits-below-debt pool to zero, and a pool sits in exactly
        // that state after any accrual — borrowIndex grows faster than liquidityIndex by
        // the reserve cut, every time. Sizing from the clamped view would under-commit by
        // that whole deficit and the backstop would silently do nothing.
        uint256 need = debt + want;
        if (need <= deposits) {
            return;
        }
        need -= deposits;

        if (need > pool.reserves) {
            need = pool.reserves;
        }

        // the scaled credit rounds DOWN, the same direction deposit() uses: the protocol
        // never receives more deposit claim than it paid for
        uint256 scaled = __toScaledDown(need, pool.liquidityIndex);
        if (scaled == 0) {
            return;
        }

        // decrement reserves by the exact round-trip of that scaled figure rather than by
        // `need` — the truncated remainder simply stays in reserves. committed <= need <=
        // pool.reserves, so this cannot underflow.
        //
        // That round-trip is exact for `scaled` itself but NOT for the pool's deposits
        // figure. Deposits read as floor((T + scaled) * i / WAD), and floor(x + y) can
        // exceed floor(x) + floor(y), so deposits may rise by `committed + 1` while
        // pool.reserves falls by exactly `committed`. property_custodyReconciles is
        // balance + borrows >= deposits + reserves, so its right-hand side can gain up to
        // 1 wei per commit with nothing on the left to match. This is the one rounding
        // direction on this path that runs against the pool; it is bounded at <= 1 wei per
        // commit and every commit costs a real liquidation, so it is a documented seam
        // rather than a solvency concern. See docs/Protocol/Liquidations.md.
        //
        // releaseBackstop is safe under the same analysis: its scaledAmount rounds UP, so
        // deposits fall by at least `amount` while reserves rise by exactly `amount`, and
        // the property's right-hand side is non-increasing.
        uint256 committed = __fromScaledDown(scaled, pool.liquidityIndex);

        pool.reserves -= committed;
        pool.backstopScaledDeposits += scaled;
        pool.totalScaledDeposits += scaled;

        emit BackstopCommitted(token, committed);
    }

    ////////////////////////
    // DUSD Debt
    ////////////////////////

    function getPositionDusdDebt(uint256 positionId) public view returns (uint256) {
        return __fromScaledUp(__scaledDusdDebt[positionId], dusdBorrowIndex);
    }

    function getScaledDusdDebt(uint256 positionId) external view returns (uint256) {
        return __scaledDusdDebt[positionId];
    }

    /**
     * @dev accrue the DUSD stability fee. Charges borrowers FIRST and sends exactly
     * what was charged to reserves — deriving a notional interest figure separately
     * from the index update is what let the token-pool accrual distribute more than
     * it took in. See docs/Protocol/Accounting.md.
     *
     * There is no lender split: nobody deposits DUSD, so the whole fee is protocol
     * revenue.
     */
    function accrueDusd() public {
        uint256 dt = block.timestamp - __dusdLastUpdate;
        if (dt == 0) {
            return;
        }
        __dusdLastUpdate = uint40(block.timestamp);

        uint256 totalDebt = __fromScaledUp(totalScaledDusdDebt, dusdBorrowIndex);
        if (totalDebt == 0) {
            emit DusdIndexUpdate(block.timestamp, dusdBorrowIndex, dusdReserves);
            return;
        }

        uint256 factor = (uint256(dusdStabilityFeeBps) * dt * WAD) / (SECONDS_PER_YEAR * MAX_BPS);
        dusdBorrowIndex += (dusdBorrowIndex * factor) / WAD;

        uint256 charged = __fromScaledUp(totalScaledDusdDebt, dusdBorrowIndex) - totalDebt;
        dusdReserves += charged;

        emit DusdIndexUpdate(block.timestamp, dusdBorrowIndex, dusdReserves);
    }

    /// @dev borrow DUSD onto this chain. Owner-gated, like every other borrow.
    function borrowDUSD(uint256 positionId, uint256 amount) external moreThanZero(amount) {
        _borrowDusd(positionId, amount);
        __DUSD.mint(msg.sender, amount);
        emit DusdBorrow(positionId, msg.sender, amount, 0);
    }

    /**
     * @dev borrow DUSD onto another chain.
     *
     * Accounting is identical to borrowDUSD — debt is debt regardless of where the
     * tokens land. The only difference is that instead of minting locally we send one
     * message authorizing the mint on the destination.
     *
     * msg.value funds the LayerZero fee; excess is refunded to msg.sender.
     */
    function borrowDUSDTo(
        uint256 positionId,
        uint32 dstEid,
        address recipient,
        uint256 amount,
        bytes calldata options
    ) external payable moreThanZero(amount) {
        if (adapter == address(0)) revert Desultory__AdapterNotSet();
        if (!allowedDestination[dstEid]) revert Desultory__DestinationNotAllowed(dstEid);

        _borrowDusd(positionId, amount);

        IAdapter(adapter).sendMint{value: msg.value}(dstEid, recipient, amount, options, msg.sender);
        emit DusdBorrow(positionId, recipient, amount, dstEid);
    }

    /// @dev shared by borrowDUSD and the cross-chain path; records debt and checks health
    function _borrowDusd(uint256 positionId, uint256 amount) internal {
        if (!__positionContract.isOwner(msg.sender, positionId)) {
            revert Desultory__NotPositionOwner(positionId);
        }
        accrueDusd();

        uint256 scaled = __toScaledUp(amount, dusdBorrowIndex);
        __scaledDusdDebt[positionId] += scaled;
        totalScaledDusdDebt += scaled;

        if (userBorrowedAmountUSD(positionId) > userMaxBorrowValueUSD(positionId)) {
            revert Desultory__CollateralValueNotEnough();
        }
    }

    /// @dev permissionless, like repay: settling someone's debt only helps them
    function repayDUSD(uint256 positionId, uint256 amount) external moreThanZero(amount) {
        accrueDusd();

        uint256 debt = getPositionDusdDebt(positionId);
        if (debt == 0) {
            revert Desultory__NoDusdDebt(positionId);
        }
        if (amount > debt) {
            amount = debt;
        }

        uint256 scaled = __toScaledDown(amount, dusdBorrowIndex);
        if (scaled > __scaledDusdDebt[positionId]) {
            scaled = __scaledDusdDebt[positionId];
        }
        __scaledDusdDebt[positionId] -= scaled;
        totalScaledDusdDebt -= scaled;

        __DUSD.burn(msg.sender, amount);
        emit DusdRepay(positionId, msg.sender, amount);
    }

    /// @dev a position's debt in one asset, DUSD or a pool token
    function _debtInAsset(uint256 positionId, address asset) private view returns (uint256) {
        return asset == address(__DUSD)
            ? getPositionDusdDebt(positionId)
            : getPositionBorrowForToken(positionId, asset);
    }

    /// @dev USD value of a debt-asset amount. DUSD has no price feed and is valued at
    /// par (see userBorrowedAmountUSD); every other asset prices through getValueUSD.
    function _debtValueUSD(address asset, uint256 amount) private view returns (uint256) {
        return asset == address(__DUSD) ? amount : getValueUSD(asset, amount);
    }

    /// @dev inverse of _debtValueUSD. DUSD is valued at par in both directions; any other
    /// debt asset goes through the oracle. Using a different convention in each direction
    /// would make the back-solve disagree with the health factor.
    function _debtAmountFromUSD(address asset, uint256 usdAmount) private view returns (uint256) {
        return asset == address(__DUSD) ? usdAmount : _usdToTokenAmount(asset, usdAmount);
    }

    /**
     * @dev recognize uncollectable debt once a position has no collateral left anywhere.
     *
     * Checked across ALL collateral, not just the asset seized: a position with WETH gone
     * but USDC remaining is still collateralized and still liquidatable by someone else.
     */
    function _recordBadDebtIfStranded(uint256 positionId) private {
        if (userCollateralValueUSD(positionId) > 0) {
            return;
        }

        uint256 remaining = userBorrowedAmountUSD(positionId);
        if (remaining == 0) {
            return;
        }

        totalBadDebtUSD += remaining;
        emit BadDebtRecorded(positionId, remaining);
    }

    /**
     * @dev retire `amount` of a position's debt in `asset`, taking the value from the
     * liquidator. Scaled conversion rounds DOWN so the repayment retires at most the
     * scaled debt it covers — the pool keeps the remainder, as in repay().
     */
    function _retireDebt(uint256 positionId, address asset, uint256 amount) private {
        if (asset == address(__DUSD)) {
            uint256 scaled = __toScaledDown(amount, dusdBorrowIndex);
            if (scaled > __scaledDusdDebt[positionId]) {
                scaled = __scaledDusdDebt[positionId];
            }
            __scaledDusdDebt[positionId] -= scaled;
            totalScaledDusdDebt -= scaled;

            __DUSD.burn(msg.sender, amount);
        } else {
            Pool storage pool = __pools[asset];
            uint256 scaled = __toScaledDown(amount, pool.borrowIndex);
            if (scaled > __scaledBorrows[positionId][asset]) {
                scaled = __scaledBorrows[positionId][asset];
            }
            __scaledBorrows[positionId][asset] -= scaled;
            pool.totalScaledBorrows -= scaled;

            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
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
     * @dev raw scaled deposit balance. Real value is scaled * liquidityIndex / WAD.
     * Exposed so invariant tests can assert that the per-position scaled balances
     * sum to pool.totalScaledDeposits — an identity that is not recoverable from
     * the unscaled getters, because each of those rounds independently.
     */
    function getScaledDeposit(uint256 position, address token) external view returns (uint256) {
        return __scaledDeposits[position][token];
    }

    /**
     * @dev raw scaled borrow balance. Real value is scaled * borrowIndex / WAD.
     */
    function getScaledBorrow(uint256 position, address token) external view returns (uint256) {
        return __scaledBorrows[position][token];
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

    /**
     * @dev collateral value weighted by each asset's LIQUIDATION THRESHOLD, in USD
     * (18 decimals). The same loop as userMaxBorrowValueUSD, one weight different:
     * that one answers "how much may this borrow?", this one "when may it be seized?".
     */
    function weightedCollateralUSD(uint256 position) public view returns (uint256) {
        uint256 totalUSD;
        for (uint256 i = 0; i < __supportedTokensCount; i++) {
            address token = __tokenList[i];
            uint256 amount = getPositionCollateralForToken(position, token);
            if (amount > 0) {
                totalUSD += (getValueUSD(token, amount) * __tokenInfos[token].liquidationThreshold / 100);
            }
        }
        return totalUSD;
    }

    /**
     * @dev threshold-weighted collateral over total debt, WAD-scaled. Below WAD the
     * position may be liquidated. type(uint256).max when there is no debt.
     *
     * Debt reads through userBorrowedAmountUSD, which already includes DUSD debt at par,
     * so DUSD debt counts toward liquidation without any special casing here.
     */
    function healthFactor(uint256 positionId) public view returns (uint256) {
        return LiquidationMath.healthFactor(weightedCollateralUSD(positionId), userBorrowedAmountUSD(positionId));
    }

    /**
     * @dev whether the position is ABOVE the liquidation threshold — not whether it has
     * borrowing capacity left. Those were the same question while the threshold equalled
     * the LTV (defect 7); they are not any more.
     *
     * Borrow capacity is userMaxBorrowValueUSD, which borrow() and withdraw() check
     * directly. This function's only caller is Position._update, the transfer gate, and
     * it wants liquidatable semantics: a position that cannot be seized has no liquidator
     * to race, so it should be transferable even at its borrow cap.
     */
    function isPositionHealthy(uint256 positionId) public view returns (bool) {
        return healthFactor(positionId) >= WAD;
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

    /// @dev inverse of getValueUSD: how many token units a USD amount buys. Rounds DOWN.
    function _usdToTokenAmount(address token, uint256 usdAmount) private view returns (uint256) {
        Collateral memory collat = __tokenInfos[token];
        AggregatorV3Interface priceFeed = AggregatorV3Interface(collat.priceFeed);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        uint256 price18 = uint256(price) * (10 ** (18 - collat.feedDecimals));
        return (usdAmount * (10 ** collat.tokenDecimals)) / price18;
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

        // DUSD is valued at $1. This is an assumption, not a fact: it holds only while
        // the peg does, and the peg mechanism is not designed yet (project C2). If DUSD
        // trades above $1, debt here is understated and positions are under-collateralized
        // in real terms.
        totalUSD += getPositionDusdDebt(position);

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

    function getTokenInfo(address token) external view returns (Collateral memory) {
        return __tokenInfos[token];
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

        uint256 totalDebt = __fromScaledUp(pool.totalScaledBorrows, pool.borrowIndex);
        if (totalDebt == 0) {
            emit IndexUpdate(token, block.timestamp, pool.borrowIndex, pool.liquidityIndex);
            return;
        }

        // rate and factor are taken from pre-accrual utilization
        uint32 rate = getBorrowRate(token, getUtilization(token));
        uint256 factor = (uint256(rate) * dt * WAD) / (SECONDS_PER_YEAR * MAX_BPS);

        // Charge borrowers FIRST, then distribute exactly what was charged.
        //
        // Deriving `interest` from a notional totalDebt * factor / WAD instead
        // lets the pool pay out more than it took in: the debt actually charged
        // comes from truncating the *index*, and that lost sub-wei of index is
        // multiplied by totalScaledBorrows. At ~1e23 scaled borrows a single
        // truncated wei of index is ~1e5 wei of real debt, handed to lenders and
        // reserves regardless. It compounds, and the pool ends up owing more
        // than it holds. Found by the Chimera harness; see test/recon/AccrualLeak.t.sol.
        pool.borrowIndex += (pool.borrowIndex * factor) / WAD;
        uint256 interest = __fromScaledUp(pool.totalScaledBorrows, pool.borrowIndex) - totalDebt;

        uint256 toReserves = (interest * RESERVE_FACTOR) / MAX_BPS;
        pool.reserves += toReserves;

        uint256 totalDeposits = __fromScaledDown(pool.totalScaledDeposits, pool.liquidityIndex);
        if (totalDeposits > 0) {
            pool.liquidityIndex += (pool.liquidityIndex * (interest - toReserves)) / totalDeposits;
        }

        emit IndexUpdate(token, block.timestamp, pool.borrowIndex, pool.liquidityIndex);
    }

    /**
     * @dev accrue every pool plus DUSD.
     *
     * A liquidation reads the health factor, which sums ALL collateral and ALL debt.
     * Accruing only the two assets named in the call would evaluate the rest at whatever
     * index they were left at — defect 6, half-fixed. The loop is the same shape
     * userBorrowedAmountUSD already runs on every health check.
     */
    function _accrueAll() private {
        for (uint256 i = 0; i < __supportedTokensCount; i++) {
            accrue(__tokenList[i]);
        }
        accrueDusd();
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

}
