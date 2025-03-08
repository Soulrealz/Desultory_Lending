pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Position } from "./PositionNFT.sol";
import { DUSD } from "./DUSD.sol";
import { OracleLib, AggregatorV3Interface } from "./libraries/OracleLib.sol";

contract Desultory 
{
    ////////////////////////
    // Errors
    ////////////////////////
    error Desultory__ZeroAmount();
    error Desultory__OwnerMismatch();
    error Desultory__NoDepositMade();
    error Desultory__WithdrawalWillViolateLTV();    
    error Desultory__CollateralValueNotEnough();
    error Desultory__AddressesAndFeedsDontMatch();    
    error Desultory__TokenNotWhitelisted(address token);    
    error Desultory__ProtocolPositionAlreadyInitialized();
    error Desultory__ProtocolNotEnoughFunds(address token);

    ////////////////////////
    // Events
    ////////////////////////
    event Borrow(uint256 indexed position, address indexed token, uint256 amount);
    event Withdrawal(uint256 indexed position, address indexed token, uint256 amount);
    event Deposit(address indexed user, uint256 indexed position, address indexed token, uint256 amount);   
    
    ///////////////////////
    // Types & interfaces
    ///////////////////////
    using SafeERC20 for IERC20;
    using OracleLib for AggregatorV3Interface;

    ////////////////////////
    // Structs
    ////////////////////////
    struct Collateral 
    {
        address priceFeed;
        uint8 decimals;
        uint8 ltvRatio;
    }

    ////////////////////////
    // State Variables
    ////////////////////////

    // @note Protocol Variables
    uint256 constant private __protocolPositionId = 1;

    // @note Position Related User Variables
    mapping(uint256 position => mapping(address token => uint256 amount)) private __userCollaterals;
    mapping(uint256 position => mapping(address token => uint256 amount)) private __userBorrows;
    mapping(address user => uint256 position) private __userPositions;

    // @note Token Variables
    mapping(address token => Collateral info) private __tokenInfos;
    mapping(uint256 tokenId => address token) private __tokenList;
    uint256 private __supportedTokensCount;

    // @note DUSD Variables
    uint256 private __protocolDebtInDUSD;
    uint256 private __totalFeesGenerated;

    // @note Contract Variables
    Position private __positionContract;
    DUSD private __DUSD;

    ////////////////////////
    // Modifiers
    ////////////////////////

    modifier moreThanZero(uint256 amount) 
    {
        if (amount == 0) 
        {
            revert Desultory__ZeroAmount();
        }
        _;
    }

    modifier isAllowedToken(address token) 
    {
        if (__tokenInfos[token].priceFeed == address(0)) 
        {
            revert Desultory__TokenNotWhitelisted(token);
        }
        _;
    }

    ////////////////////////
    // constructor & init
    ////////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeeds, uint8[] memory decimals, uint8[] memory ltvs,
                address _positionContract, address _DUSDContract) 
    {
        if (tokenAddresses.length != priceFeeds.length || tokenAddresses.length != ltvs.length || tokenAddresses.length != decimals.length)
        {
            revert Desultory__AddressesAndFeedsDontMatch();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++)
        {
            __tokenInfos[tokenAddresses[i]] = Collateral(priceFeeds[i], decimals[i], ltvs[i]);
            __tokenList[i] = tokenAddresses[i];
        }

        __supportedTokensCount = tokenAddresses.length;
        __positionContract = Position(_positionContract);
        __DUSD = DUSD(_DUSDContract);
    }

    function initializeProtocolPosition() external 
    {
        if (__userPositions[address(this)] != 0)
        {
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
     * @dev simple deposit for creating a position or increase a deposit in case you dont know your id
     * @param token which token to deposit
     * @param amount how much of the token to deposit
     */
    function deposit(address token, uint256 amount) external moreThanZero(amount) isAllowedToken(token)
    {
        this.deposit(token, amount, 0); 
    }

    /**
     * @dev deposit that requires the user to pass their position
     * @param token which token to deposit
     * @param amount how much of the token to deposit
     * @param positionId the nft id of the user's position
     */
    function deposit(address token, uint256 amount, uint256 positionId) external moreThanZero(amount) isAllowedToken(token)
    {
        uint256 userPositionId = __userPositions[msg.sender];
        if (positionId != 0 && !__positionContract.isOwner(msg.sender, positionId))
        {
            revert Desultory__OwnerMismatch();
        }
        // new user will create position
        else if (positionId == 0 && userPositionId == 0)
        {
            userPositionId = createPosition();
        }
        recordDeposit(token, amount);

        // old user with correct position will increase his deposit
        // if (positionId != 0 && positionId == userPositionId) {}

        // old user doesnt know his position will use position from mapping
        // if (positionId != 0 && positionId != userPositionId) {}
        // if (positionId == 0 && userPositionId != 0) {}        

        __userCollaterals[userPositionId][token] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, userPositionId, token, amount);
    }

    // @todo withdrawAll function
    /**
     * @dev function to withdraw a given token
     * @param token which token to withdraw deposit from
     * @param amount how much to withdraw
     * @param positionId the nft id of the user's position
     */
    function withdraw(address token, uint256 amount, uint256 positionId) external moreThanZero(amount) isAllowedToken(token)
    {
        if (!__positionContract.isOwner(msg.sender, positionId))
        {
            revert Desultory__OwnerMismatch();
        }

        uint256 borrowedAmountUSD = getValueUSD(token, __userBorrows[positionId][token]);
        uint256 depositedAmount = __userCollaterals[positionId][token];
        amount = depositedAmount < amount ? depositedAmount : amount;
        
        uint256 postWithdrawCollateralUSD = getValueUSD(token, depositedAmount - amount);
        uint256 newLTVToUphold = postWithdrawCollateralUSD * __tokenInfos[token].ltvRatio / 100;
        if (borrowedAmountUSD > newLTVToUphold)
        {
            revert Desultory__WithdrawalWillViolateLTV();
        }
        recordWithdrawal(token, amount);
        
        __userCollaterals[positionId][token] -= amount;
        IERC20(token).safeTransferFrom(address(this), msg.sender, amount);
        emit Withdrawal(positionId, token, amount);
    }

    // @note to make a borrow for DUSD? is it necessary?
    // @note make a borrow for ETH
    // function borrow(uint256 amount) external moreThanZero(amount)
    // {
    //     this.borrow(address(__DUSD), amount);
    // }

    function borrow(address token, uint256 amount) external moreThanZero(amount) isAllowedToken(token)
    {
        if (amount > __userCollaterals[__protocolPositionId][token])
        {
            revert Desultory__ProtocolNotEnoughFunds(token);
        }

        uint256 userPositionId = __userPositions[msg.sender];
        if (userPositionId == 0)
        {
            revert Desultory__NoDepositMade();
        }

        uint256 currentBorrowed = userBorrowedAmountUSD(userPositionId);
        if(currentBorrowed == 0)
        {
            uint256 desiredUSD = getValueUSD(token, amount);
            uint256 availableUSD = userMaxBorrowValueUSD(userPositionId);

            if (desiredUSD > availableUSD)
            {
                revert Desultory__CollateralValueNotEnough();
            }

            __userBorrows[userPositionId][token] += amount;
            IERC20(token).safeTransferFrom(address(this), msg.sender, amount);
            emit Borrow(userPositionId, token, amount);
        }
        else
        {
            // @todo add fee calculations here
            uint256 desiredUSD = getValueUSD(token, amount);
            uint256 availableUSD = userMaxBorrowValueUSD(userPositionId) - currentBorrowed;

            if (desiredUSD > availableUSD)
            {
                revert Desultory__CollateralValueNotEnough();
            }

            __userBorrows[userPositionId][token] += amount;
            IERC20(token).safeTransferFrom(address(this), msg.sender, amount);
            emit Borrow(userPositionId, token, amount);
        }
    }

    // @note withdrawMulti ? for multi token withdrawal
    // @note payAndWithdraw

    ////////////////////////
    // Public Functions
    ////////////////////////

    function getValueUSD(address token, uint256 amount) public view returns (uint256)
    {   
        Collateral memory collat = __tokenInfos[token];
        AggregatorV3Interface priceFeed = AggregatorV3Interface(collat.priceFeed);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        uint256 adjustedPrice = uint256(price) * (10 ** (18 - collat.decimals));
        uint256 adjustedAmount = amount * (10 ** (18 - collat.decimals));

        return (adjustedAmount * adjustedPrice) / 1e18;
    }

    function userBorrowedAmountUSD(uint256 position) public view returns (uint256)
    {
        uint256 totalUSD;
        for (uint256 i = 0; i < __supportedTokensCount; i++)
        {
            address token = __tokenList[i];
            uint256 amount = __userBorrows[position][token];
            totalUSD += getValueUSD(token, amount);
        }

        return totalUSD;
    }

    function userCollateralValueUSD(uint256 position) public view returns (uint256)
    {
        uint256 totalUSD;
        for (uint256 i = 0; i < __supportedTokensCount; i++)
        {
            address token = __tokenList[i];
            uint256 amount = __userCollaterals[position][token];
            totalUSD += getValueUSD(token, amount);
        }

        return totalUSD;
    }

    function userMaxBorrowValueUSD(uint256 position) public view returns (uint256)
    {
        uint256 totalUSD;
        for (uint256 i = 0; i < __supportedTokensCount; i++)
        {
            address token = __tokenList[i];
            uint256 amount = __userCollaterals[position][token];
            totalUSD += (getValueUSD(token, amount) * __tokenInfos[token].ltvRatio / 100);
        }

        return totalUSD;
    }

    ///////////////////////
    // Private Functions
    ///////////////////////

    function createPosition() private returns (uint256)
    {
        uint256 newPosition = __positionContract.mint(msg.sender);
        __userPositions[msg.sender] = newPosition;
        return newPosition;
    }

    function recordDeposit(address token, uint256 amount) private
    {
        __userCollaterals[__protocolPositionId][token] += amount;
    }

    function recordWithdrawal(address token, uint256 amount) private
    {
        __userCollaterals[__protocolPositionId][token] -= amount;
    }

    ///////////////////////
    // Internal Functions
    ///////////////////////
}