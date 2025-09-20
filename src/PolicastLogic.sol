// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LMSRMath} from "./LMSRMath.sol";

/**
 * @title PolicastLogic
 * @notice Library containing complex LMSR calculation logic extracted from main contract
 * @dev This library helps reduce the main contract size by moving computational logic
 */
library PolicastLogic {
    // Constants from main contract
    uint256 internal constant PAYOUT_PER_SHARE = 100 * 1e18;
    uint256 internal constant PROB_EPS = 5e12; // 0.000005 (5 ppm) tolerance on probability sum

    // Custom errors for library operations
    error InsufficientSolvency();
    error PriceInvariant();
    error ProbabilityInvariant();

    /**
     * @notice Data structure for market information needed by library functions
     */
    struct MarketData {
        uint256 optionCount;
        uint256 lmsrB;
        uint256 maxOptionShares;
        uint256 userLiquidity;
        uint256 adminInitialLiquidity;
    }

    /**
     * @notice Data structure for option information
     */
    struct OptionData {
        uint256 totalShares;
        uint256 currentPrice;
    }

    /**
     * @notice Calculate LMSR cost for current market state
     * @param market Market data structure
     * @param options Mapping of option data (passed as array for library compatibility)
     * @return LMSR cost in tokens
     */
    function calculateLMSRCost(MarketData memory market, OptionData[] memory options) internal pure returns (uint256) {
        if (market.optionCount == 0) return 0;

        uint256 b = market.lmsrB;
        uint256[] memory scaled = new uint256[](market.optionCount);

        for (uint256 i = 0; i < market.optionCount; i++) {
            scaled[i] = (options[i].totalShares * 1e18) / b;
        }

        (uint256 maxScaled, uint256 lnSumExp) = LMSRMath.logSumExp(scaled);
        return (b * (maxScaled + lnSumExp)) / 1e18;
    }

    /**
     * @notice Calculate LMSR cost for given share amounts
     * @param market Market data structure
     * @param shares Array of share amounts for each option
     * @return LMSR cost in tokens
     */
    function calculateLMSRCostWithShares(MarketData memory market, uint256[] memory shares)
        internal
        pure
        returns (uint256)
    {
        if (market.optionCount == 0) return 0;

        uint256 b = market.lmsrB;
        uint256[] memory scaled = new uint256[](market.optionCount);

        for (uint256 i = 0; i < market.optionCount; i++) {
            scaled[i] = (shares[i] * 1e18) / b;
        }

        (uint256 maxScaled, uint256 lnSumExp) = LMSRMath.logSumExp(scaled);
        return (b * (maxScaled + lnSumExp)) / 1e18;
    }

    /**
     * @notice Validate market solvency after buy operations
     * @param market Market data structure
     */
    function validateBuySolvency(MarketData memory market) internal pure {
        uint256 liability = (market.maxOptionShares * PAYOUT_PER_SHARE) / 1e18;
        uint256 available = market.userLiquidity + market.adminInitialLiquidity;

        if (available < liability) {
            revert InsufficientSolvency();
        }
    }

    /**
     * @notice Update LMSR prices for all options and return new prices
     * @param market Market data structure
     * @param options Array of option data (will be modified in place)
     * @return Array of new prices
     */
    function updateLMSRPrices(MarketData memory market, OptionData[] memory options)
        internal
        pure
        returns (uint256[] memory)
    {
        if (market.optionCount == 0) return new uint256[](0);

        uint256 b = market.lmsrB;
        uint256[] memory scaled = new uint256[](market.optionCount);

        for (uint256 i = 0; i < market.optionCount; i++) {
            scaled[i] = (options[i].totalShares * 1e18) / b;
        }

        (uint256 maxScaled,) = LMSRMath.logSumExp(scaled);

        // Compute exp(q_i/b - max)
        uint256[] memory expVals = new uint256[](market.optionCount);
        uint256 denom = 0;

        for (uint256 i = 0; i < market.optionCount; i++) {
            uint256 diff = scaled[i] >= maxScaled ? 0 : (maxScaled - scaled[i]);
            uint256 e = LMSRMath.expNeg(diff);
            expVals[i] = e;
            denom += e;
        }

        uint256[] memory prices = new uint256[](market.optionCount);

        if (denom == 0) {
            // Fallback to uniform distribution scaled to PAYOUT_PER_SHARE
            uint256 uniform = PAYOUT_PER_SHARE / market.optionCount;
            for (uint256 i = 0; i < market.optionCount; i++) {
                options[i].currentPrice = uniform;
                prices[i] = uniform;
            }
        } else {
            // Calculate normalized probabilities scaled to PAYOUT_PER_SHARE
            for (uint256 i = 0; i < market.optionCount; i++) {
                uint256 p = (expVals[i] * PAYOUT_PER_SHARE) / denom;
                options[i].currentPrice = p;
                prices[i] = p;
            }
        }

        // Validate prices and probability sum
        _validatePrices(prices);

        return prices;
    }

    /**
     * @notice Compute LMSR B parameter based on initial liquidity and option count
     * @param initialLiquidity Initial liquidity amount
     * @param optionCount Number of options in the market
     * @return B parameter for LMSR
     */
    function computeB(uint256 initialLiquidity, uint256 optionCount) internal pure returns (uint256) {
        return LMSRMath.computeB(initialLiquidity, optionCount, PAYOUT_PER_SHARE);
    }

    /**
     * @notice Validate that prices are within acceptable bounds and sum to ~PAYOUT_PER_SHARE
     * @param prices Array of prices to validate
     */
    function _validatePrices(uint256[] memory prices) private pure {
        uint256 sumProb = 0;

        for (uint256 i = 0; i < prices.length; i++) {
            uint256 p = prices[i];
            if (p > PAYOUT_PER_SHARE) {
                revert PriceInvariant();
            }
            sumProb += p;
        }

        if (sumProb + PROB_EPS < PAYOUT_PER_SHARE || sumProb > PAYOUT_PER_SHARE + PROB_EPS) {
            revert ProbabilityInvariant();
        }
    }
}
