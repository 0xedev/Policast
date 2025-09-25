// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LMSRMathPRB} from "./LMSRMathPRB.sol";

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
        if (market.lmsrB == 0) revert PriceInvariant(); // Prevent division by zero
        if (options.length != market.optionCount) revert PriceInvariant(); // Validate array length

        uint256 b = market.lmsrB;
        uint256[] memory shares = new uint256[](market.optionCount);
        for (uint256 i = 0; i < market.optionCount; i++) {
            shares[i] = options[i].totalShares;
        }
        uint256 lmsrRaw = LMSRMathPRB.cost(b, shares); // share units (1e18)
        return (lmsrRaw * PAYOUT_PER_SHARE) / 1e18; // tokens
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
        if (market.lmsrB == 0) revert PriceInvariant(); // Prevent division by zero
        if (shares.length != market.optionCount) revert PriceInvariant(); // Validate array length

        uint256 b = market.lmsrB;
        uint256 lmsrRaw = LMSRMathPRB.cost(b, shares);
        return (lmsrRaw * PAYOUT_PER_SHARE) / 1e18;
    }

    /**
     * @notice Validate market solvency after buy operations
     * @param market Market data structure
     */
    function validateBuySolvency(MarketData memory market) internal pure {
        uint256 liability = (market.maxOptionShares * PAYOUT_PER_SHARE) / 1e18; // convert shares to tokens
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
        if (market.lmsrB == 0) revert PriceInvariant(); // Prevent division by zero
        if (options.length != market.optionCount) revert PriceInvariant(); // Validate array length

        uint256 b = market.lmsrB;
        uint256[] memory shares = new uint256[](market.optionCount);
        for (uint256 i = 0; i < market.optionCount; i++) {
            shares[i] = options[i].totalShares;
        }
        uint256[] memory prices = LMSRMathPRB.probabilities(b, shares);

        // Validate prices BEFORE updating options array (atomicity)
        _validatePrices(prices);

        // Only update options after validation passes
        for (uint256 i = 0; i < market.optionCount; i++) {
            options[i].currentPrice = prices[i];
        }

        return prices;
    }

    /**
     * @notice Compute LMSR B parameter based on initial liquidity and option count
     * @param initialLiquidity Initial liquidity amount
     * @param optionCount Number of options in the market
     * @return B parameter for LMSR
     */
    function computeB(uint256 initialLiquidity, uint256 optionCount) internal pure returns (uint256) {
        return LMSRMathPRB.computeB(initialLiquidity, optionCount, PAYOUT_PER_SHARE);
    }

    /**
     * @notice Validate that prices are within acceptable bounds and sum to ~1e18 (now without 100x scaling)
     * @param prices Array of prices to validate
     */
    function _validatePrices(uint256[] memory prices) private pure {
        uint256 sumProb = 0;

        for (uint256 i = 0; i < prices.length; i++) {
            uint256 p = prices[i];
            if (p > 1e18) {
                // Individual prices should not exceed 100%
                revert PriceInvariant();
            }
            sumProb += p;
        }

        if (sumProb + PROB_EPS < 1e18 || sumProb > 1e18 + PROB_EPS) {
            // Sum should be ~1e18 (100%)
            revert ProbabilityInvariant();
        }
    }
}
