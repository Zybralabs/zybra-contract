// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {MockCentrifugeChain} from "../test/mocks/MockCentrifugeChain.sol";

contract MockCentrifugeChainSetup {
    MockCentrifugeChain public centrifugeChain;

    function setupCentrifugeChain(address[] memory testAdapters) external returns (address) {
        centrifugeChain = new MockCentrifugeChain(testAdapters);
        return address(centrifugeChain);
    }
}
