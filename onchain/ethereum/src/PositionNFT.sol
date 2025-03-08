pragma solidity 0.8.28;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract Position is ERC721, Ownable
{
    uint256 private _nextTokenId = 1;

    constructor(string memory _name, string memory _symbol) ERC721(_name, _symbol) Ownable(msg.sender)
    {}

    function mint(address to) external onlyOwner returns (uint256) 
    {
        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        return tokenId;
    }

    function isOwner(address suspect, uint256 nftId) external view returns (bool)
    {
        return super.ownerOf(nftId) == suspect;
    }

    // @note make transfer and transferFrom onlyOwner. Make Desultory owner. NFT transfers will happen through this protocol only.
}