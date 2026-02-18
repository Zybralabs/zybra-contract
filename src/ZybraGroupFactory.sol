// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ZybraGroup} from "./ZybraGroup.sol";

/**
 * @title ZybraGroupFactoryV2
 * @dev Factory contract for deploying ZybraGroupV2 contracts with capital-weighted yield distribution
 * @author Zybra Protocol
 */
contract ZybraGroupFactory {
    // Events
    event GroupDeployed(
        address indexed groupAddress,
        address indexed admin,
        address indexed asset,
        uint256 contributionAmount,
        uint256 cycleDuration,
        uint256 totalCycles,
        address vault
    );
    event FactoryOwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // Errors
    error OnlyOwner();
    error ZeroAddress();
    error InvalidAmount();
    error InvalidCycleLength();
    error DeploymentFailed();

    // Factory owner
    address public owner;

    // Deployment tracking
    mapping(address => bool) public isDeployedGroup;
    address[] public deployedGroups;
    mapping(address => address[]) public adminToGroups; // Track groups by admin

    // Factory constants
    uint256 public constant MIN_CONTRIBUTION = 1e6; // Minimum 1 USDC
    uint256 public constant MAX_CONTRIBUTION = 1000e6; // Maximum 1000 USDC
    uint256 public constant MIN_CYCLE_LENGTH = 1;
    uint256 public constant MAX_CYCLE_LENGTH = 52;

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier validAddress(address _addr) {
        if (_addr == address(0)) revert ZeroAddress();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /**
     * @dev Deploy a new ZybraGroupV2 with specified MetaMorpho vault
     * @param _asset The ERC20 token address for contributions
     * @param _contributionAmount The fixed contribution amount per cycle
     * @param _cycleDuration The duration of each cycle in seconds (e.g., 1 week, 2 weeks, 1 month)
     * @param _totalCycles The total number of cycles in the group
     * @param _admin The admin address for the new group
     * @param _vault The MetaMorpho vault address to use for this group
     * @param _treasury The treasury address for protocol fees
     * @return groupAddress The address of the deployed ZybraGroupV2 contract
     */
    function deployGroup(
        address _asset,
        uint256 _contributionAmount,
        uint256 _cycleDuration,
        uint256 _totalCycles,
        address _admin,
        address _vault,
        address _treasury
    ) external returns (address groupAddress) {
        return _deployGroup(
            _asset,
            _contributionAmount,
            _cycleDuration,
            _totalCycles,
            _admin,
            _vault,
            _treasury
        );
    }

    /**
     * @dev Internal function to deploy ZybraGroupV2 with validation
     */
    function _deployGroup(
        address _asset,
        uint256 _contributionAmount,
        uint256 _cycleDuration,
        uint256 _totalCycles,
        address _admin,
        address _vault,
        address _treasury
    ) internal validAddress(_asset) validAddress(_admin) validAddress(_vault) validAddress(_treasury) returns (address) {
        // Validate parameters
        if (_contributionAmount < MIN_CONTRIBUTION || _contributionAmount > MAX_CONTRIBUTION) {
            revert InvalidAmount();
        }
        if (_cycleDuration == 0) {
            revert InvalidCycleLength();
        }
        if (_totalCycles < MIN_CYCLE_LENGTH || _totalCycles > MAX_CYCLE_LENGTH) {
            revert InvalidCycleLength();
        }

        // Deploy new ZybraGroup
        try new ZybraGroup(
            _asset,
            _contributionAmount,
            _cycleDuration,
            _totalCycles,
            _admin,
            _vault,
            _treasury
        ) returns (ZybraGroup newGroup) {
            address groupAddress = address(newGroup);

            // Track deployment
            isDeployedGroup[groupAddress] = true;
            deployedGroups.push(groupAddress);
            adminToGroups[_admin].push(groupAddress);

            emit GroupDeployed(
                groupAddress,
                _admin,
                _asset,
                _contributionAmount,
                _cycleDuration,
                _totalCycles,
                _vault
            );

            return groupAddress;
        } catch {
            revert DeploymentFailed();
        }
    }

    /**
     * @dev Get all deployed groups
     * @return Array of deployed group addresses
     */
    function getAllDeployedGroups() external view returns (address[] memory) {
        return deployedGroups;
    }

    /**
     * @dev Get groups administered by a specific address
     * @param _admin The admin address to query
     * @return Array of group addresses administered by the admin
     */
    function getGroupsByAdmin(address _admin) external view returns (address[] memory) {
        return adminToGroups[_admin];
    }

    /**
     * @dev Get the number of deployed groups
     * @return The total count of deployed groups
     */
    function getDeployedGroupsCount() external view returns (uint256) {
        return deployedGroups.length;
    }

    /**
     * @dev Get group info for multiple groups at once
     * @param _groups Array of group addresses to query
     * @return infos Array of group information structs
     */
    function getGroupsInfo(address[] calldata _groups)
        external
        view
        returns (GroupInfo[] memory infos)
    {
        infos = new GroupInfo[](_groups.length);

        for (uint256 i = 0; i < _groups.length; i++) {
            if (isDeployedGroup[_groups[i]]) {
                ZybraGroup group = ZybraGroup(_groups[i]);
                infos[i] = GroupInfo({
                    groupAddress: _groups[i],
                    admin: group.admin(),
                    asset: address(group.asset()),
                    contributionAmount: group.contributionAmount(),
                    cycleDuration: group.cycleDuration(),
                    totalCycles: group.totalCycles(),
                    currentCycle: group.getCurrentCycle(),
                    poolStartTime: group.groupStartTime(),
                    poolStarted: group.groupStartTime() != 0,
                    poolEnded: group.groupEnded(),
                    memberCount: group.membersCount()
                });
            }
        }
    }

    /**
     * @dev Struct to hold group information
     */
    struct GroupInfo {
        address groupAddress;
        address admin;
        address asset;
        uint256 contributionAmount;
        uint256 cycleDuration;
        uint256 totalCycles;
        uint256 currentCycle;
        uint256 poolStartTime;
        bool poolStarted;
        bool poolEnded;
        uint256 memberCount;
    }

    // ==================== OWNER FUNCTIONS ====================

    /**
     * @dev Transfer ownership of the factory
     * @param _newOwner The new owner address
     */
    function transferOwnership(address _newOwner)
        external
        onlyOwner
        validAddress(_newOwner)
    {
        address oldOwner = owner;
        owner = _newOwner;
        emit FactoryOwnershipTransferred(oldOwner, _newOwner);
    }
}
