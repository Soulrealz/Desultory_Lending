pragma solidity 0.8.28;

import {LibDiamond} from "../libraries/LibDiamond.sol";

contract DiamondCutFacet {
    event DiamondCut(FacetCut[] _diamondCut, address _init, bytes _calldata);

    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }

    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata) external {
        LibDiamond.enforceOwnership();
        LibDiamond.diamondCut(_diamondCut, _init, _calldata);
        emit DiamondCut(_diamondCut, _init, _calldata);
    }

}
