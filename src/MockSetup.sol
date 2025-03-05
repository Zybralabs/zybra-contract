// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {MockAdapter} from "../test/mocks/MockAdapter.sol";
import {MockCentrifugeChain} from "../test/mocks/MockCentrifugeChain.sol";
import {MockGasService} from "../test/mocks/MockGasService.sol";
import {ERC20} from "../contracts/Zybra/token/ERC20.sol";
import {mockChainlink} from "../contracts/mocks/chainLinkMock.sol";

contract MockSetup {
    MockAdapter public adapter1;
    MockAdapter public adapter2;
    MockAdapter public adapter3;
    MockCentrifugeChain public centrifugeChain;
    MockGasService public mockedGasService;
    ERC20 public erc20;
    mockChainlink public chainlinkMock;

    address[] public testAdapters;

    function setupMocks(address deployer) external returns (address[] memory, address, address) {
        mockedGasService = new MockGasService();
        adapter1 = new MockAdapter(address(mockedGasService));
        adapter2 = new MockAdapter(address(mockedGasService));
        adapter3 = new MockAdapter(address(mockedGasService));

        centrifugeChain = new MockCentrifugeChain(testAdapters);

        erc20 = new ERC20(6);
        erc20.file("name", "X's Dollar");
        erc20.file("symbol", "USDX");

        chainlinkMock = new mockChainlink();

        adapter1.setReturn("estimate", uint256(1 gwei));
        adapter2.setReturn("estimate", uint256(1.25 gwei));
        adapter3.setReturn("estimate", uint256(1.75 gwei));

        testAdapters.push(address(adapter1));
        testAdapters.push(address(adapter2));
        testAdapters.push(address(adapter3));

        return (testAdapters, address(erc20), address(chainlinkMock));
    }
}
