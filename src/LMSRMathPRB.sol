// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

// PRB-Math value type (brings global using directives from the file)
import {UD60x18} from "lib/prb-math/src/ud60x18/ValueType.sol";

/**
 * @title LMSRMathPRB
 * @notice PRB-Math based implementation of core LMSR primitives (cost and probabilities)
 * @dev All inputs (shares, b) are 1e18-scaled. Returned costs are in share units (1e18 scale).
 *      Conversion to token units (payout) is done by caller. This avoids double-scaling bugs.
 */
library LMSRMathPRB {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant ONE_SQUARED = 1e36; // ONE * ONE

    /**
     * @notice Compute LMSR cost function C(q) = b * log( sum_i exp(q_i / b) )
     * @param b LMSR liquidity parameter (1e18 scaled)
     * @param shares Array of outcome share quantities (1e18 scaled)
     * @return costShares Cost value in share units (1e18 scaled)
     */
    function cost(uint256 b, uint256[] memory shares) internal pure returns (uint256 costShares) {
        uint256 n = shares.length;
        if (n == 0) return 0;
        require(b > 0, "B_ZERO");

        // First pass: ratios r_i = q_i / b and find maximum (all unsigned)
        uint256[] memory ratios = new uint256[](n);
        uint256 maxR = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 r = (shares[i] * ONE) / b; // 1e18 scaled
            ratios[i] = r;
            if (r > maxR) maxR = r;
        }

        // Second pass: compute exp(r_i - maxR) using reciprocal trick to avoid signed math.
        // exp(r_i - maxR) = 1 / exp(maxR - r_i)
        uint256 sumExp = 0;
        uint256[] memory expVals = new uint256[](n); // store for probabilities reuse
        for (uint256 i = 0; i < n; i++) {
            uint256 diff = maxR - ratios[i]; // >=0
            if (diff == 0) {
                expVals[i] = ONE; // exp(0)=1
            } else {
                // exp(diff) where diff is 1e18 scaled positive number
                uint256 ePos = UD60x18.unwrap(UD60x18.wrap(diff).exp()); // exp(diff)
                // Guard: ePos should be >= 1e18
                if (ePos <= ONE) {
                    // Extremely small diff rounding produced 1; reciprocal still 1
                    expVals[i] = ONE;
                } else {
                    // reciprocal: 1 / ePos
                    expVals[i] = ONE_SQUARED / ePos; // (1e18 * 1e18)/ePos => 1e18 scaled
                }
            }
            sumExp += expVals[i]; // n<=10 so no overflow risk
        }
        // sumExp is 1e18 scaled sum of exponentials ( >=1e18 )
        // logSumExp = maxR + ln(sumExp)
    uint256 lnSum = UD60x18.unwrap(UD60x18.wrap(sumExp).ln()); // ln(sumExp) where sumExp is 1e18 scaled
        uint256 logSumExp = maxR + lnSum; // 1e18 scaled
        costShares = (b * logSumExp) / ONE; // (1e18 * 1e18)/1e18 => 1e18
    }

    /**
     * @notice Compute normalized probabilities p_i = exp(q_i / b) / sum_j exp(q_j / b)
     * @dev Re-uses the same stable computation as cost() (two-pass with max subtraction).
     * @param b LMSR liquidity parameter
     * @param shares Outcome share quantities
     * @return probs Array of probabilities summing to 1e18
     */
    function probabilities(uint256 b, uint256[] memory shares) internal pure returns (uint256[] memory probs) {
        uint256 n = shares.length;
        probs = new uint256[](n);
        if (n == 0) return probs;
        require(b > 0, "B_ZERO");

        uint256[] memory ratios = new uint256[](n);
        uint256 maxR = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 r = (shares[i] * ONE) / b;
            ratios[i] = r;
            if (r > maxR) maxR = r;
        }
        uint256[] memory expVals = new uint256[](n);
        uint256 sumExp = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 diff = maxR - ratios[i];
            uint256 val;
            if (diff == 0) {
                val = ONE;
            } else {
                uint256 ePos = UD60x18.unwrap(UD60x18.wrap(diff).exp()); // exp(diff)
                if (ePos <= ONE) {
                    val = ONE; // near-zero diff
                } else {
                    val = ONE_SQUARED / ePos; // reciprocal
                }
            }
            expVals[i] = val;
            sumExp += val;
        }
        // Normalize
        if (sumExp == 0) {
            // fallback uniform
            uint256 uniform = ONE / n;
            for (uint256 i = 0; i < n; i++) probs[i] = uniform;
            return probs;
        }
        for (uint256 i = 0; i < n; i++) {
            probs[i] = (expVals[i] * ONE) / sumExp; // 1e18 scaled
        }
    }
}
