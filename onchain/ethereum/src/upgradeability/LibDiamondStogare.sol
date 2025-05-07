// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library LibAppStorage {
    bytes32 internal constant STORAGE_SLOT = keccak256("desultory.app.storage");
    
    uint16 constant MAX_BPS = 10_000;
    uint256 constant SECONDS_PER_YEAR = 365 days;
 
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
        mapping(address => uint256) lastBorrowIndex;
        mapping(address => uint256) borrowedAmounts;
    }

    struct AppStorage {
        // Protocol Variables
        uint256 protocolPositionId;
        mapping(address => uint256) profit;

        // Position Related User Variables
        mapping(uint256 => mapping(address => uint256)) userCollaterals;
        mapping(uint256 => Borrower) userBorrows;
        mapping(address => uint256) userPositions;
        uint256 liquidationPenalty;
        uint256 liquidationPenaltyProtocol;

        // Token Variables
        mapping(address => Collateral) tokenInfos;
        mapping(uint256 => address) tokenList;
        uint256 supportedTokensCount;

        // DUSD Variables
        uint256 protocolDebtInDUSD;
        uint256 totalFeesGenerated;

        // Contract References
        address positionContract;
        address DUSD;

        // Interest Variables
        Interest interest;
        mapping(address => uint256) globalBorrowIndex;
        mapping(address => uint256) lastUpdateTimestamp;
    }

    function get() internal pure returns (AppStorage storage s) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }
}
