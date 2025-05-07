pragma solidity 0.8.28;

import {DiamondCut} from "../upgradeability/DiamondCut.sol";

library LibDiamond {
    bytes32 constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");

    struct Facet {
        address facetAddress;
        bytes4[] functionSelectors;
    }

    struct DiamondStorage {
        mapping(bytes4 => address) selectorToFacet;
        mapping(address => bytes4[]) facetToSelectors;
        mapping(bytes4 => bool) supportedInterfaces;
        address contractOwner;
    }

    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    function contractOwner() internal view returns (address contractOwner_) {
        contractOwner_ = diamondStorage().contractOwner;
    }

    function enforceOwnership() internal view {
        require(msg.sender == diamondStorage().contractOwner, "Not contract owner");
    }

    function diamondCut(
        DiamondCut.FacetCut[] memory _diamondCut, address _init, bytes memory _calldata
    ) internal {                    
        for (uint256 i = 0; i < _diamondCut.length; i++) {
            DiamondCut.FacetCut memory cut = _diamondCut[i];
            if (cut.action == DiamondCut.FacetCutAction.Add) {
                //addFunctions(cut.facetAddress, cut.functionSelectors);
            } else if (cut.action == DiamondCut.FacetCutAction.Replace) {
                //replaceFunctions(cut.facetAddress, cut.functionSelectors);
            } else if (cut.action == DiamondCut.FacetCutAction.Remove) {
                //removeFunctions(cut.facetAddress, cut.functionSelectors);
            }
        }
        
    
    function initializeDiamond(address _init, bytes memory _calldata) internal {
        if (_init == address(0)) {
            return;
        }
        enforceHasContractCode(_init, "LibDiamondCut: _init address has no code");        
        (bool success, bytes memory error) = _init.delegatecall(_calldata);
        if (!success) {
            if (error.length > 0) {
                // bubble up error
                /// @solidity memory-safe-assembly
                assembly {
                    let returndata_size := mload(error)
                    revert(add(32, error), returndata_size)
                }
            } else {
                revert InitializationFunctionReverted(_init, _calldata);
            }
        }        
    }


    // variant 2 na diamondInitialize
    //function diamondInitialize(
    //    address _init, bytes memory _calldata
    //) internal {
    //    if (_init == address(0)) {
    //        return;
    //    }
     //   require(_calldata.length > 0, "Must provide _calldata");
     //   require(_init != address(this), "Cannot initialize self");



    // variant 3 na diamondInitialize
    //function diamondInitialize(address _init, bytes memory _calldata) internal {
    //if (_init == address(0)) {
    //    return;
    //}
    //require(_calldata.length > 0, "Must provide _calldata");
    //require(_init != address(this), "Cannot initialize self");
    
    // Delegatecall to initialize contract
    //(bool success, ) = _init.delegatecall(_calldata);
    //require(success, "Initialization failed");
//}

// contract address + initialization function
    //function isContract(address _address) internal view returns (bool) {
    //uint256 size;
    //assembly {
    //    size := extcodesize(_address)
    //}
    //return size > 0;
//}

//function diamondInitialize(address _init, bytes memory _calldata) internal {
//    if (_init == address(0)) {
//        return;
//    }
 //   require(_calldata.length > 0, "Must provide _calldata");
 //   require(_init != address(this), "Cannot initialize self");
 //   require(isContract(_init), "Initialization target must be a contract");
    
 //   (bool success, ) = _init.delegatecall(_calldata);
 //   require(success, "Initialization failed");
//}



        //function isContract(address addr) returns (bool) {
        //uint size;
        //assembly { size := extcodesize(addr) }
        //return size > 0;
        //}
        // TO DO da dobavq funkciite v diamondCUT

        // funkciq za dobavqne na facet kum diamand 
    }   

    function addFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {        
        if(_facetAddress == address(0)) {
            revert CannotAddSelectorsToZeroAddress(_functionSelectors);
        }
        DiamondStorage storage ds = diamondStorage();
        uint16 selectorCount = uint16(ds.selectors.length);                
        enforceHasContractCode(_facetAddress, "LibDiamondCut: Add facet has no code");
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.facetAddressAndSelectorPosition[selector].facetAddress;
            if(oldFacetAddress != address(0)) {
                revert CannotAddFunctionToDiamondThatAlreadyExists(selector);
            }            
            ds.facetAddressAndSelectorPosition[selector] = FacetAddressAndSelectorPosition(_facetAddress, selectorCount);
            ds.selectors.push(selector);
            selectorCount++;
        }
    }

    function replaceFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {        
        DiamondStorage storage ds = diamondStorage();
        if(_facetAddress == address(0)) {
            revert CannotReplaceFunctionsFromFacetWithZeroAddress(_functionSelectors);
        }
        enforceHasContractCode(_facetAddress, "LibDiamondCut: Replace facet has no code");
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.facetAddressAndSelectorPosition[selector].facetAddress;
            // can't replace immutable functions -- functions defined directly in the diamond in this case
            if(oldFacetAddress == address(this)) {
                revert CannotReplaceImmutableFunction(selector);
            }
            if(oldFacetAddress == _facetAddress) {
                revert CannotReplaceFunctionWithTheSameFunctionFromTheSameFacet(selector);
            }
            if(oldFacetAddress == address(0)) {
                revert CannotReplaceFunctionThatDoesNotExists(selector);
            }
            // replace old facet address
            ds.facetAddressAndSelectorPosition[selector].facetAddress = _facetAddress;
        }
    }

    function removeFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {        
        DiamondStorage storage ds = diamondStorage();
        uint256 selectorCount = ds.selectors.length;
        if(_facetAddress != address(0)) {
            revert RemoveFacetAddressMustBeZeroAddress(_facetAddress);
        }        
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            FacetAddressAndSelectorPosition memory oldFacetAddressAndSelectorPosition = ds.facetAddressAndSelectorPosition[selector];
            if(oldFacetAddressAndSelectorPosition.facetAddress == address(0)) {
                revert CannotRemoveFunctionThatDoesNotExist(selector);
            }
            
            
            // can't remove immutable functions -- functions defined directly in the diamond
            if(oldFacetAddressAndSelectorPosition.facetAddress == address(this)) {
                revert CannotRemoveImmutableFunction(selector);
            }
            // replace selector with last selector
            selectorCount--;
            if (oldFacetAddressAndSelectorPosition.selectorPosition != selectorCount) {
                bytes4 lastSelector = ds.selectors[selectorCount];
                ds.selectors[oldFacetAddressAndSelectorPosition.selectorPosition] = lastSelector;
                ds.facetAddressAndSelectorPosition[lastSelector].selectorPosition = oldFacetAddressAndSelectorPosition.selectorPosition;
            }
            // delete last selector
            ds.selectors.pop();
            delete ds.facetAddressAndSelectorPosition[selector];
        }
    }
    
}