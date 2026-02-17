// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 * @title TimeWeightedCapital Library
 * @notice O(1) time-weighted capital tracking for fair yield distribution
 * @dev Uses capital-seconds accumulation (similar to Compound/PoolTogether TWAB)
 *
 * MATH:
 * =====
 * UserYield = TotalYield × (∫ u(t) dt) / (∫ T(t) dt)
 * 
 * Where:
 *   u(t) = user capital at time t
 *   T(t) = total capital at time t
 *   CapitalSeconds = Σ (capital × Δt)
 *
 * User share = userCapSec / totalCapSec
 */
library TimeWeightedCapital {
    uint256 internal constant P = 1e18;  // Precision

    /**
     * @notice Calculate capital-seconds: c × Δt
     * @param c Capital amount
     * @param t0 Start time
     * @param t1 End time
     * @return Capital-seconds
     */
    function capSec(uint256 c, uint256 t0, uint256 t1) internal pure returns (uint256) {
        if (t1 <= t0 || c == 0) return 0;
        return c * (t1 - t0);
    }

    /**
     * @notice Calculate user yield share
     * @param uCS User capital-seconds
     * @param tCS Total capital-seconds
     * @param y Total yield
     * @return User's yield
     */
    function yieldShare(uint256 uCS, uint256 tCS, uint256 y) internal pure returns (uint256) {
        if (tCS == 0 || uCS == 0 || y == 0) return 0;
        return mulDiv(y, uCS, tCS);
    }

    /**
     * @notice Calculate yield rate per capital-second
     * @param y New yield
     * @param tCS Total capital-seconds
     * @return Yield per cap-sec (scaled by P)
     */
    function yieldRate(uint256 y, uint256 tCS) internal pure returns (uint256) {
        if (tCS == 0 || y == 0) return 0;
        return mulDiv(y, P, tCS);
    }

    /**
     * @notice Update accumulated capital-seconds
     * @param acc Current accumulated
     * @param c Capital
     * @param dt Elapsed time
     * @return New accumulated
     */
    function accrue(uint256 acc, uint256 c, uint256 dt) internal pure returns (uint256) {
        if (dt == 0 || c == 0) return acc;
        return acc + (c * dt);
    }

    /**
     * @notice Calculate pending yield
     * @param uCS User capital-seconds
     * @param rate Accumulated yield per cap-sec
     * @param debt Already claimed
     * @return Pending yield
     */
    function pending(uint256 uCS, uint256 rate, uint256 debt) internal pure returns (uint256) {
        if (uCS == 0) return 0;
        uint256 earned = mulDiv(uCS, rate, P);
        return earned > debt ? earned - debt : 0;
    }

    /**
     * @notice Full precision (a × b) / d using 512-bit intermediate
     * @param a Multiplicand
     * @param b Multiplier
     * @param d Divisor
     * @return (a × b) / d
     */
    function mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        require(d > 0, "div0");
        
        uint256 p0; // Low 256 bits
        uint256 p1; // High 256 bits
        
        assembly {
            let mm := mulmod(a, b, not(0))
            p0 := mul(a, b)
            p1 := sub(sub(mm, p0), lt(mm, p0))
        }
        
        if (p1 == 0) return p0 / d;
        
        require(p1 < d, "overflow");
        
        uint256 r;
        assembly {
            r := mulmod(a, b, d)
            p1 := sub(p1, gt(r, p0))
            p0 := sub(p0, r)
        }
        
        uint256 tw = d & (~d + 1);
        assembly {
            d := div(d, tw)
            p0 := div(p0, tw)
            tw := add(div(sub(0, tw), tw), 1)
        }
        
        p0 |= p1 * tw;
        
        uint256 inv = (3 * d) ^ 2;
        inv *= 2 - d * inv;
        inv *= 2 - d * inv;
        inv *= 2 - d * inv;
        inv *= 2 - d * inv;
        inv *= 2 - d * inv;
        inv *= 2 - d * inv;
        
        return p0 * inv;
    }
}
