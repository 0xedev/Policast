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
    // Max safe input for PRB-Math exp for UD60x18 is about 133.084...; use a conservative bound
    uint256 internal constant MAX_EXP_INPUT = 133e18;

    /**
     * @notice Compute LMSR liquidity parameter b based on initial liquidity and option count
     * @dev Mirrors previous logic from legacy LMSRMath.computeB. Returns b in share units (1e18 scale).
     * @param initialLiquidity Initial token liquidity provided (1e18 tokens)
     * @param optionCount Number of outcomes (2-10 supported)
     * @param payoutPerShare Payout per winning share in tokens (1e18 scaled)
     */
    function computeB(uint256 initialLiquidity, uint256 optionCount, uint256 payoutPerShare)
        internal
        pure
        returns (uint256)
    {
        if (optionCount < 2) revert("BadOptionCount");
        if (optionCount > 10) revert("UnsupportedOptionCount");
        if (initialLiquidity == 0) revert("ZeroLiquidity");
        if (payoutPerShare == 0) revert("ZeroPayoutPerShare");

        uint256 lnN;
        if (optionCount == 2) lnN = 693147180559945309; // ln(2)

        else if (optionCount == 3) lnN = 1098612288668109692; // ln(3)

        else if (optionCount == 4) lnN = 1386294361119890648; // ln(4)

        else if (optionCount == 5) lnN = 1609437912434100375; // ln(5)

        else if (optionCount == 6) lnN = 1783378370508591168; // ln(6)

        else if (optionCount == 7) lnN = 1922703101705143167; // ln(7)

        else if (optionCount == 8) lnN = 2037421927016425482; // ln(8)

        else if (optionCount == 9) lnN = 2133745237141597423; // ln(9)

        else lnN = 2218487496163563680; // ln(10)

        uint256 sharesEquivalent = (initialLiquidity * ONE) / payoutPerShare; // convert tokens to share units
        uint256 bShares = (sharesEquivalent * ONE) / lnN; // divide by ln(n)
        if (bShares < 10e18) bShares = 10e18;
        if (bShares > 10_000_000e18) bShares = 10_000_000e18;
        return bShares;
    }

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
                if (diff >= MAX_EXP_INPUT) {
                    // exp(diff) too large -> contribution ~0
                    expVals[i] = 0;
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
                if (diff >= MAX_EXP_INPUT) {
                    val = 0; // negligible contribution
                } else {
                    uint256 ePos = UD60x18.unwrap(UD60x18.wrap(diff).exp()); // exp(diff)
                    if (ePos <= ONE) {
                        val = ONE; // near-zero diff
                    } else {
                        val = ONE_SQUARED / ePos; // reciprocal
                    }
                }
            }
            expVals[i] = val;
            sumExp += val;
        }
        // Normalize
        if (sumExp == 0) {
            // fallback uniform
            uint256 uniform = ONE / n;
            for (uint256 i = 0; i < n; i++) {
                probs[i] = uniform;
            }
            return probs;
        }
        // Softmax probabilities initial pass
        uint256 maxProb;
        uint256 maxIndex;
        for (uint256 i = 0; i < n; i++) {
            uint256 p = (expVals[i] * ONE) / sumExp;
            probs[i] = p;
            if (p > maxProb) {
                maxProb = p;
                maxIndex = i;
            }
        }
        // Hard cap at 95%: if exceeded, redistribute excess to others proportionally.
        uint256 CAP = 950000000000000000; // 0.95 * 1e18
        if (maxProb > CAP) {
            uint256 othersOrig = ONE - maxProb; // original mass for others
            uint256 targetOthers = ONE - CAP; // mass others must have after capping
            if (othersOrig == 0) {
                // Distribute uniformly among other buckets
                probs[maxIndex] = CAP;
                uint256 per = targetOthers / (n - 1);
                for (uint256 i = 0; i < n; i++) {
                    if (i != maxIndex) probs[i] = per;
                }
            } else {
                for (uint256 i = 0; i < n; i++) {
                    if (i == maxIndex) continue;
                    probs[i] = (probs[i] * targetOthers) / othersOrig;
                }
                probs[maxIndex] = CAP;
            }
            maxProb = CAP;
        }
        // Apply tiny floor (1e-12) to maintain meaningful tradability
        uint256 FLOOR = 1e6; // 1e-12 * 1e18
        uint256 added;
        for (uint256 i = 0; i < n; i++) {
            if (probs[i] < FLOOR) {
                added += (FLOOR - probs[i]);
                probs[i] = FLOOR;
            }
        }
        if (added > 0) {
            // Prefer taking from capped bucket if it is the largest and above FLOOR
            uint256 largest = 0;
            for (uint256 i = 1; i < n; i++) {
                if (probs[i] > probs[largest]) largest = i;
            }
            if (probs[largest] > added) {
                probs[largest] -= added;
                if (largest == maxIndex && probs[largest] > CAP) probs[largest] = CAP; // safety
            } else {
                // proportional fallback normalize
                uint256 tot;
                for (uint256 i = 0; i < n; i++) {
                    tot += probs[i];
                }
                for (uint256 i = 0; i < n; i++) {
                    probs[i] = (probs[i] * ONE) / tot;
                }
            }
        }
        // Final normalization adjust (rounding drift)
        uint256 sumFinal;
        for (uint256 i = 0; i < n; i++) {
            sumFinal += probs[i];
        }
        if (sumFinal != ONE) {
            if (sumFinal > ONE) {
                uint256 diff = sumFinal - ONE;
                uint256 largest = 0;
                for (uint256 i = 1; i < n; i++) {
                    if (probs[i] > probs[largest]) largest = i;
                }
                if (probs[largest] > diff) probs[largest] -= diff;
                else probs[largest] = 1; // minimal fallback
            } else {
                // sumFinal < ONE
                uint256 diff = ONE - sumFinal;
                // Add diff to first non-capped bucket if capped bucket already at CAP
                uint256 target = maxIndex;
                if (probs[maxIndex] >= CAP) {
                    for (uint256 i = 0; i < n; i++) {
                        if (i != maxIndex) {
                            target = i;
                            break;
                        }
                    }
                }
                probs[target] += diff;
                if (target == maxIndex && probs[target] > CAP) probs[target] = CAP; // clamp again
            }
        }
    }
}
