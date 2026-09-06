pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IPositionHealth {
    function isPositionHealthy(uint256 positionId) external view returns (bool);
}

contract Position is ERC721, Ownable {
    error Position__ProtocolAlreadySet();
    error Position__PositionUnhealthy(uint256 tokenId);

    uint256 private _nextTokenId = 1;
    IPositionHealth private _protocol;

    constructor(string memory _name, string memory _symbol) ERC721(_name, _symbol) Ownable(msg.sender) {}

    /**
     * @dev one-time wiring of the protocol used for the transfer health gate.
     * Must be called by the deployer BEFORE transferring ownership to the protocol.
     */
    function setProtocol(address protocol) external onlyOwner {
        if (address(_protocol) != address(0)) {
            revert Position__ProtocolAlreadySet();
        }
        _protocol = IPositionHealth(protocol);
    }

    function mint(address to) external onlyOwner returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        return tokenId;
    }

    function exists(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    function isOwner(address suspect, uint256 nftId) external view returns (bool) {
        return ownerOf(nftId) == suspect;
    }

    /**
     * @dev transfers (not mints) of liquidatable positions are blocked.
     * The position carries its debt with it; trading a position that is
     * mid-liquidation would race the liquidators.
     */
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0) && address(_protocol) != address(0)) {
            if (!_protocol.isPositionHealthy(tokenId)) {
                revert Position__PositionUnhealthy(tokenId);
            }
        }
        return super._update(to, tokenId, auth);
    }
}
