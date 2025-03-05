pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Position } from "./PositionNFT.sol";
import { OracleLib, AggregatorV3Interface } from "./libraries/OracleLib.sol";

contract Desultory 
{
    ////////////////////////
    // Errors
    ////////////////////////
    error Desultory__AddressesAndFeedsDontMatch();
    error Desultory__ZeroAmount();
    error Desultory__TokenNotWhitelisted(address token);
    error Desultory__OwnerMismatch();
    error Desultory__WithdrawalWillViolateLTV();

    ////////////////////////
    // Events
    ////////////////////////
    event Deposit(address indexed user, address indexed token, uint256 amount);

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
    mapping(address token => Collateral info) private __tokenInfos;
    mapping(uint256 position => mapping(address token => uint256 amount)) private __collateralBalances;
    mapping(uint256 position => uint256 amount) private __userBorrows;
    mapping(address user => uint256 position) private __userPositions;

    uint256 private __protocolDebtInDUSD;
    uint256 private __totalFeesGenerated;

    Position private __positionContract;

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
    // constructor
    ////////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeeds, uint8[] memory decimals, uint8[] memory ltvs,
                address _positionContract) 
    {
        if (tokenAddresses.length != priceFeeds.length || tokenAddresses.length != ltvs.length || tokenAddresses.length != decimals.length)
        {
            revert Desultory__AddressesAndFeedsDontMatch();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++)
        {
            __tokenInfos[tokenAddresses[i]] = Collateral(priceFeeds[i], decimals[i], ltvs[i]);
        }

        __positionContract = Position(_positionContract);
    }

    ////////////////////////
    // External Functions
    ////////////////////////

    // @note for stablecoin LP providal
    // function depositStable()

    function deposit(address token, uint256 amount) external moreThanZero(amount) isAllowedToken(token)
    {
        this.deposit(token, amount, 0); 
    }

    function deposit(address token, uint256 amount, uint256 positionId) external moreThanZero(amount) isAllowedToken(token)
    {   
        // @audit 
        // Case 1: PositionId = 0, __userPositions[msg.sender] = 0 -> New user
        // Case 2: PositionId = 0, __userPositions[msg.sender] = 1 -> Old user passing wrong positionId (doesnt know his position)
        // Case 3: PositionId = 1, __userPositions[msg.sender] = 1 -> Old user passing correct positionId
        // Case 4: PositionId = 1, __userPositions[msg.sender] = 0 -> New user passing positionId

        // @note Special Cases
        // Case 5: PositionId = 5, __userPositions[msg.sender] = 3 -> Old user passing wrong positionId (deposit for someone else)
        // Will not handle Case 5. "Donations" will only be allowed from accounts that do not currently have a position

        uint256 userPositionId = __userPositions[msg.sender];

        // user without position donates to a different user
        if (positionId != 0 && userPositionId == 0)
        {
            userPositionId = positionId;
        }
        // new user will create position
        else if (positionId == 0 && userPositionId == 0)
        {
            userPositionId = createPosition();
        }

        // old user with correct position will increase his deposit
        // if (positionId != 0 && positionId == userPositionId) {}

        // old user doesnt know his position will use position from mapping
        // if (positionId != 0 && positionId != userPositionId) {}        

        __collateralBalances[userPositionId][token] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, token, amount);
    }

    function withdraw(address token, uint256 amount, uint256 positionId) external moreThanZero(amount) isAllowedToken(token)
    {
        if (msg.sender != __positionContract.ownerOf(positionId))
        {
            revert Desultory__OwnerMismatch();
        }

        uint256 borrowedAmount = __userBorrows[positionId];
        uint256 depositedAmount = __collateralBalances[positionId][token];
        amount = depositedAmount < amount ? depositedAmount : amount;
        
        uint256 postWithdrawCollateralUSD = getValueInUSD(token, depositedAmount - amount);
        uint256 newLTVToUphold = postWithdrawCollateralUSD * __tokenInfos[token].ltvRatio / 100;
        if (borrowedAmount > newLTVToUphold)
        {
            revert Desultory__WithdrawalWillViolateLTV();
        }
        
        __collateralBalances[positionId][token] -= amount;
        IERC20(token).transfer(msg.sender, amount);
    }

    // @note withdrawMulti ? for multi token withdrawal
    // @note payAndWithdraw

    ////////////////////////
    // Public Functions
    ////////////////////////

    function getValueInUSD(address token, uint256 amount) public view returns (uint256)
    {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(__tokenInfos[token].priceFeed);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        uint256 adjustedPrice = uint256(price) * (10 ** (18 - __tokenInfos[token].decimals));
        uint256 adjustedAmount = amount * (10 ** (18 - __tokenInfos[token].decimals));

        return (adjustedAmount * adjustedPrice) / 1e18;
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

    ///////////////////////
    // Internal Functions
    ///////////////////////
}