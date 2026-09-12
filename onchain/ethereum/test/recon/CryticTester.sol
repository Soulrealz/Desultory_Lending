// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {CryticAsserts} from "@chimera/CryticAsserts.sol";
import {TargetFunctions} from "./TargetFunctions.sol";

/// @dev entrypoint for Echidna and Medusa.
contract CryticTester is TargetFunctions, CryticAsserts {
    constructor() payable {
        setup();
    }
}
