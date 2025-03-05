// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;

import "../interfaces/Iconfigurator.sol";
import "../interfaces/IEUSD.sol";
import "../interfaces/IZybra.sol";
import "../interfaces/IMiningIncentives.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IStakingRewards {
    function rewardRatio() external view returns (uint256);
}

contract ZybraHelper is Ownable {
    Iconfigurator public immutable configurator;
    address[] public pools;
    AggregatorV3Interface public priceFeed;
    IMiningIncentives miningIncentives;
    event BatchClaimingRewardsForUsers(address indexed caller, string desc, uint256 total);

    //priceFeed = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
    constructor(address _config, address _etherOracle, address _miningIncentives) {
        configurator = Iconfigurator(_config);
        priceFeed = AggregatorV3Interface(_etherOracle);
        miningIncentives = IMiningIncentives(_miningIncentives);
    }

    function setPools(address[] memory _pools) external onlyOwner {
        pools = _pools;
    }

    function getAssetPrice(address pool) public view returns (uint256) {
        (,int price, , , ) = priceFeed.latestRoundData();
        return IZybra(pool).getAsset2EtherExchangeRate() * uint(price) / 1e18;
    }

    function getEtherPrice() public view returns(uint256) {
        (,int etherPrice, , , ) = priceFeed.latestRoundData();
        return uint256(etherPrice);
    }

    function getToTalTVL() external view returns(uint256 a) {
        for(uint i; i < pools.length; i++) {
            a += IZybra(pools[i]).totalDepositedAsset() * getAssetPrice(pools[i]);
        }
    }

    function getCollateralRatio(
        address user,
        address pool
    ) public view returns (uint256) {
        IZybra ZybraPool = IZybra(pool);
        if (ZybraPool.getBorrowedOf(user) == 0) return 1e22;
        return
            (ZybraPool.depositedAsset(user) * getAssetPrice(pool) * 1e12) /
            ZybraPool.getBorrowedOf(user);
    }

    function getExcessIncomeAmount(
        address pool
    ) external view returns (uint256 assetAmount) {
        IZybra ZybraPool = IZybra(pool);
        if (ZybraPool.getVaultType() != 0) return 0;
        address asset = ZybraPool.getAsset();
        assetAmount =  IERC20(asset).balanceOf(address(pool)) -
            ZybraPool.totalDepositedAsset();
    }

    function getOverallCollateralRatio(
        address pool
    ) public view returns (uint256) {
        IZybra ZybraPool = IZybra(pool);
        return
            (ZybraPool.totalDepositedAsset() * getAssetPrice(pool) * 1e12) /
            ZybraPool.getPoolTotalCirculation();
    }

    function getLiquidateableAmount(
        address user,
        address pool
    ) external view returns (uint256 etherAmount, uint256 eusdAmount) {
        IZybra ZybraPool = IZybra(pool);
        if (getCollateralRatio(user, pool) > 150 * 1e18) return (0, 0);
        if (
            getCollateralRatio(user, pool) >= 125 * 1e18 ||
            getOverallCollateralRatio(pool) >= 150 * 1e18 || ZybraPool.getVaultType() != 0
        ) {
            etherAmount = ZybraPool.depositedAsset(user) / 2;
            eusdAmount = (etherAmount * getAssetPrice(pool)) / 1e8;
        } else {
            etherAmount = ZybraPool.depositedAsset(user);
            eusdAmount = (etherAmount * getAssetPrice(pool)) / 1e8;
            if (getCollateralRatio(user, pool) >= 1e20) {
                eusdAmount =
                    (eusdAmount * 1e20) /
                    getCollateralRatio(user, pool);
            }
        }
    }

    function getRedeemableAmount(address user, address pool) external view returns (uint256) {
        if (!configurator.isRedemptionProvider(user)) return 0;
        return IZybra(pool).getBorrowedOf(user);
    }

    function getRedeemableAmounts(address[] calldata users, address pool)
        external
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](users.length);
        for (uint256 i = 0; i < users.length; i++) {
            if (!configurator.isRedemptionProvider(users[i])) {
                amounts[i] = 0;
            } else {
                amounts[i] = IZybra(pool).getBorrowedOf(users[i]);
            }
        }
    }

    function getLiquidateFund(
        address user,
        address pool
    ) external view returns (uint256 eusdAmount) {
        IEUSD token = IZybra(pool).getVaultType() == 0 ? IEUSD(configurator.getEUSDAddress()) : IEUSD(configurator.peUSD());
        uint256 appro = token.allowance(
            user,
            address(pool)
        );
        if (appro == 0) return 0;
        uint256 bal = token.balanceOf(user);
        eusdAmount = appro > bal ? bal : appro;
    }

    function getBuyAbleEarnings(address[] memory users) external view returns(uint256[] memory amounts) {
        amounts = new uint256[](users.length);
        for(uint256 i; i < users.length; i++) {
            if(miningIncentives.isOtherEarningsClaimable(users[i])) {
                amounts[i] = miningIncentives.earned(users[i]);
            }
        }
    }

    function getWithdrawableAmount(
        address user,
        address pool
    ) external view returns (uint256) {
        IZybra ZybraPool = IZybra(pool);
        if (ZybraPool.getBorrowedOf(user) == 0)
            return ZybraPool.depositedAsset(user);
        uint256 safeCollateralRatio = configurator.getSafeCollateralRatio(pool);
        if (getCollateralRatio(user, pool) <= safeCollateralRatio) return 0;
        return
            (ZybraPool.depositedAsset(user) *
                (getCollateralRatio(user, pool) - safeCollateralRatio)) /
            getCollateralRatio(user, pool);
    }

    function getEusdMintableAmount(
        address user,
        address pool
    ) external view returns (uint256 eusdAmount) {
        IZybra ZybraPool = IZybra(pool);
        uint256 safeCollateralRatio = configurator.getSafeCollateralRatio(pool);
        if (getCollateralRatio(user, pool) <= safeCollateralRatio) return 0;
        return
            (ZybraPool.depositedAsset(user) * getAssetPrice(pool)) /
            1e24 /
            safeCollateralRatio -
            ZybraPool.getBorrowedOf(user);
    }

    function getStakingPoolAPR(
        address poolAddress,
        address lbr,
        address lpToken
    ) external view returns (uint256 apr) {
        uint256 pool_lp_stake = IERC20(poolAddress).totalSupply();
        uint256 rewardRatio = IStakingRewards(poolAddress).rewardRatio();
        uint256 lp_lbr_amount = IERC20(lbr).balanceOf(lpToken);
        uint256 lp_total_supply = IERC20(lpToken).totalSupply();
        apr =
            (lp_total_supply * rewardRatio * 86_400 * 365 * 1e6) /
            (pool_lp_stake * lp_lbr_amount * 2);
    }

    function getTokenPrice(
        address token,
        address UniPool,
        address wethAddress
    ) external view returns (uint256 price) {
        uint256 token_in_pool = IERC20(token).balanceOf(UniPool);
        uint256 weth_in_pool = IERC20(wethAddress).balanceOf(UniPool);
        price =
            (weth_in_pool * getEtherPrice() * 1e10) /
            token_in_pool;
    }
}
