// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LMSRMath} from "./LMSRMath.sol";

/**
 * @title PolicastLogic
 * @notice Library containing complex LMSR calculation logic extracted from main contract
 * @dev This library helps reduce the main contract size by moving computational logic
 */
library PolicastLogic {
    // 1 share pays out 100 tokens when winning
    uint256 internal constant PAYOUT_PER_SHARE = 100 * 1e18;
    // Total market value - all share prices sum to this
    uint256 internal constant TOTAL_MARKET_VALUE = 100 * 1e18;
    uint256 internal constant PROB_EPS = 1e15; // 0.001 (1000 ppm) tolerance on probability sum
    
    // Custom errors for library operations
    error InsufficientSolvency();
    error PriceInvariant();
    error ProbabilityInvariant();
    error InvalidOptionId();
    error ZeroShares();
    error InvalidMarketData();
    error OverflowDetected();
    error DivisionByZero();

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
        uint256 currentPrice; // Current marginal price per share
    }

    /**
     * @notice Calculate LMSR cost for current market state
     * @param market Market data structure
     * @param options Array of option data
     * @return LMSR cost in tokens
     */
    function calculateLMSRCost(MarketData memory market, OptionData[] memory options) internal pure returns (uint256) {
        // CEI Pattern: Checks
        if (market.optionCount == 0) return 0;
        if (market.lmsrB == 0) revert InvalidMarketData();
        if (options.length != market.optionCount) revert InvalidMarketData();

        // Effects: Prepare calculation data
        uint256 b = market.lmsrB;
        uint256[] memory scaled = new uint256[](market.optionCount);

        // Calculate scaled shares: q_i / b
        for (uint256 i = 0; i < market.optionCount; i++) {
            scaled[i] = (options[i].totalShares * 1e18) / b;
        }

        // Interactions: Use LMSRMath library
        (uint256 maxScaled, uint256 lnSumExp) = LMSRMath.logSumExp(scaled);
        
        // Safe addition and multiplication
        uint256 logSum = maxScaled + lnSumExp;
        if (logSum == 0) return 0; // Handle edge case
        
        return (b * logSum) / 1e18;
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
        // CEI Pattern: Checks
        if (market.optionCount == 0) return 0;
        if (market.lmsrB == 0) revert InvalidMarketData();
        if (shares.length != market.optionCount) revert InvalidMarketData();

        // Effects: Prepare calculation data
        uint256 b = market.lmsrB;
        uint256[] memory scaled = new uint256[](market.optionCount);

        // Calculate scaled shares: q_i / b
        for (uint256 i = 0; i < market.optionCount; i++) {
            scaled[i] = (shares[i] * 1e18) / b;
        }

        // Interactions: Use LMSRMath library
        (uint256 maxScaled, uint256 lnSumExp) = LMSRMath.logSumExp(scaled);
        
        // Safe addition and multiplication
        uint256 logSum = maxScaled + lnSumExp;
        if (logSum == 0) return 0; // Handle edge case
        
        return (b * logSum) / 1e18;
    }

    /**
     * @notice Calculate the exact cost to buy a specific number of shares for an option
     * @param market Market data structure
     * @param options Current option states
     * @param optionId Which option to buy
     * @param sharesToBuy Number of shares to purchase
     * @return cost Exact cost in tokens to buy the shares
     * @return newShares Updated share amounts after purchase
     */
    function calculateBuyCost(
        MarketData memory market,
        OptionData[] memory options,
        uint256 optionId,
        uint256 sharesToBuy
    ) internal pure returns (uint256 cost, uint256[] memory newShares) {
        // CEI Pattern: Checks
        if (optionId >= market.optionCount) revert InvalidOptionId();
        if (sharesToBuy == 0) revert ZeroShares();
        if (options.length != market.optionCount) revert InvalidMarketData();

        // Effects: Prepare share arrays for cost calculation
        newShares = new uint256[](market.optionCount);
        for (uint256 i = 0; i < market.optionCount; i++) {
            newShares[i] = options[i].totalShares;
        }
        
        // Calculate cost before purchase
        uint256 costBefore = calculateLMSRCostWithShares(market, newShares);
        
        // Add shares to the specified option
        newShares[optionId] += sharesToBuy;
        
        // Calculate cost after purchase
        uint256 costAfter = calculateLMSRCostWithShares(market, newShares);
        
        // Handle case where costAfter might be less than costBefore due to precision
        cost = costAfter > costBefore ? costAfter - costBefore : 0;
    }

    /**
     * @notice Calculate the exact proceeds from selling shares for an option
     * @param market Market data structure
     * @param options Current option states
     * @param optionId Which option to sell
     * @param sharesToSell Number of shares to sell
     * @return proceeds Exact proceeds in tokens from selling shares
     * @return newShares Updated share amounts after sale
     */
    function calculateSellProceeds(
        MarketData memory market,
        OptionData[] memory options,
        uint256 optionId,
        uint256 sharesToSell
    ) internal pure returns (uint256 proceeds, uint256[] memory newShares) {
        // CEI Pattern: Checks
        if (optionId >= market.optionCount) revert InvalidOptionId();
        if (sharesToSell == 0) revert ZeroShares();
        if (options.length != market.optionCount) revert InvalidMarketData();
        if (options[optionId].totalShares < sharesToSell) revert ZeroShares();

        // Effects: Prepare share arrays for proceeds calculation
        newShares = new uint256[](market.optionCount);
        for (uint256 i = 0; i < market.optionCount; i++) {
            newShares[i] = options[i].totalShares;
        }
        
        // Calculate cost before sale
        uint256 costBefore = calculateLMSRCostWithShares(market, newShares);
        
        // Remove shares from the specified option
        newShares[optionId] -= sharesToSell;
        
        // Calculate cost after sale
        uint256 costAfter = calculateLMSRCostWithShares(market, newShares);
        
        // Handle case where costBefore might be less than costAfter due to precision
        proceeds = costBefore > costAfter ? costBefore - costAfter : 0;
    }

    /**
     * @notice Calculate the average price per share for a given purchase
     * @param market Market data structure
     * @param options Current option states
     * @param optionId Which option to buy
     * @param sharesToBuy Number of shares to purchase
     * @return averagePrice Average price per share for this specific purchase
     */
    function calculateAveragePrice(
        MarketData memory market,
        OptionData[] memory options,
        uint256 optionId,
        uint256 sharesToBuy
    ) internal pure returns (uint256 averagePrice) {
        // CEI Pattern: Checks
        if (sharesToBuy == 0) return 0;
        
        // Effects & Interactions: Get total cost
        (uint256 totalCost,) = calculateBuyCost(market, options, optionId, sharesToBuy);
        
        // Calculate average price
        averagePrice = (totalCost * 1e18) / sharesToBuy;
    }

    /**
     * @notice Validate market solvency after buy operations
     * @param market Market data structure
     */
    function validateBuySolvency(MarketData memory market) internal pure {
        // CEI Pattern: Checks
        if (market.maxOptionShares == 0) return; // No shares, no liability
        
        // Effects: Calculate liability and available funds
        uint256 liability = (market.maxOptionShares * PAYOUT_PER_SHARE) / 1e18;
        uint256 available = market.userLiquidity + market.adminInitialLiquidity;

        // Final check
        if (available < liability) {
            revert InsufficientSolvency();
        }
    }

    /**
     * @notice Update LMSR marginal prices for all options based on current share distribution
     * @dev Prices will fluctuate based on share imbalance and sum to TOTAL_MARKET_VALUE
     * @param market Market data structure
     * @param options Array of option data (will be modified in place)
     * @return Array of updated marginal prices
     */
    function updateLMSRPrices(MarketData memory market, OptionData[] memory options)
        internal
        pure
        returns (uint256[] memory)
    {
        // CEI Pattern: Checks
        if (market.optionCount == 0) return new uint256[](0);
        if (market.lmsrB == 0) revert InvalidMarketData();
        if (options.length != market.optionCount) revert InvalidMarketData();

        // Effects: Calculate scaled shares
        uint256 b = market.lmsrB;
        uint256[] memory scaled = new uint256[](market.optionCount);

        for (uint256 i = 0; i < market.optionCount; i++) {
            scaled[i] = (options[i].totalShares * 1e18) / b;
        }

        // Interactions: Use LMSRMath for log-sum-exp calculation
        (uint256 maxScaled,) = LMSRMath.logSumExp(scaled);

        // Calculate exponential values and denominator
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
            // Edge case: uniform distribution
            uint256 uniform = TOTAL_MARKET_VALUE / market.optionCount;
            for (uint256 i = 0; i < market.optionCount; i++) {
                options[i].currentPrice = uniform;
                prices[i] = uniform;
            }
        } else {
            // Calculate marginal prices based on LMSR formula
            // Price_i = TOTAL_MARKET_VALUE * exp(shares_i / b) / Σ exp(shares_j / b)
            for (uint256 i = 0; i < market.optionCount; i++) {
                uint256 numerator = expVals[i] * TOTAL_MARKET_VALUE;
                uint256 marginalPrice = numerator / denom;
                
                options[i].currentPrice = marginalPrice;
                prices[i] = marginalPrice;
            }
        }

        // Final validation
        _validatePrices(prices);

        return prices;
    }

    /**
     * @notice Compute LMSR B parameter based on initial liquidity and option count
     * @dev B parameter controls market sensitivity - higher B means less price movement per trade
     * @param initialLiquidity Initial liquidity amount
     * @param optionCount Number of options in the market
     * @return B parameter for LMSR
     */
    function computeB(uint256 initialLiquidity, uint256 optionCount) internal pure returns (uint256) {
        // CEI Pattern: Checks
        if (initialLiquidity == 0) revert InvalidMarketData();
        if (optionCount < 2) revert InvalidMarketData();
        
        // Effects & Interactions: Delegate to LMSRMath
        return LMSRMath.computeB(initialLiquidity, optionCount, PAYOUT_PER_SHARE);
    }

    /**
     * @notice Get current marginal price for a specific option without modifying state
     * @param market Market data structure
     * @param options Array of option data
     * @param optionId Option to get price for
     * @return Current marginal price for the option
     */
    function getCurrentPrice(
        MarketData memory market,
        OptionData[] memory options,
        uint256 optionId
    ) internal pure returns (uint256) {
        // CEI Pattern: Checks
        if (optionId >= market.optionCount) revert InvalidOptionId();
        if (options.length != market.optionCount) revert InvalidMarketData();
        
        // Effects & Interactions: Calculate and return current prices
        uint256[] memory currentPrices = updateLMSRPrices(market, options);
        return currentPrices[optionId];
    }

    /**
     * @notice Validate that marginal prices are within acceptable bounds and sum correctly
     * @param prices Array of marginal prices to validate
     */
    function _validatePrices(uint256[] memory prices) private pure {
        // CEI Pattern: Checks
        if (prices.length == 0) return;
        
        // Effects: Calculate sum and validate individual prices
        uint256 sumPrices = 0;

        for (uint256 i = 0; i < prices.length; i++) {
            uint256 p = prices[i];
            
            // Each marginal price should not exceed the total market value
            if (p > TOTAL_MARKET_VALUE) {
                revert PriceInvariant();
            }
            
            // Check for overflow in sum
            if (sumPrices > type(uint256).max - p) revert OverflowDetected();
            sumPrices += p;
        }

        // Marginal prices should sum to TOTAL_MARKET_VALUE (within tolerance)
        if (sumPrices < TOTAL_MARKET_VALUE - PROB_EPS || sumPrices > TOTAL_MARKET_VALUE + PROB_EPS) {
            revert ProbabilityInvariant();
        }
    }
}
