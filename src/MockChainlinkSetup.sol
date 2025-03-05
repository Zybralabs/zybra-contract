// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {mockChainlink} from "../contracts/mocks/chainLinkMock.sol";

contract MockChainlinkSetup {
    mockChainlink public chainlinkMock;

    function setupMockChainlink() external returns (address) {
        chainlinkMock = new mockChainlink();
        return address(chainlinkMock);
    }
}
