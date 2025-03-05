// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {MockAdapter} from "../test/mocks/MockAdapter.sol";
import {MockGasService} from "../test/mocks/MockGasService.sol";

contract MockAdapterSetup {
    MockAdapter public adapter1;
    MockAdapter public adapter2;
    MockAdapter public adapter3;
    MockGasService public mockedGasService;

    address[] public testAdapters;

    function setupMockAdapters() external returns (address[] memory) {
        mockedGasService = new MockGasService();

        adapter1 = new MockAdapter(address(mockedGasService));
        adapter2 = new MockAdapter(address(mockedGasService));
        adapter3 = new MockAdapter(address(mockedGasService));

        adapter1.setReturn("estimate", uint256(1 gwei));
        adapter2.setReturn("estimate", uint256(1.25 gwei));
        adapter3.setReturn("estimate", uint256(1.75 gwei));

        testAdapters.push(address(adapter1));
        testAdapters.push(address(adapter2));
        testAdapters.push(address(adapter3));

        return testAdapters;
    }
}
