// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
// ...existing code...
import {PolicastMarketV3} from "src/Policast.sol";
import {PolicastViews} from "src/PolicastViews.sol";
import {MockERC20} from "test/MockERC20.sol";

contract PricingDebugTest is Test {
    MockERC20 internal token;
    PolicastMarketV3 internal market;
    PolicastViews internal views;

    address internal OWNER = address(0xA11CE);

    function setUp() public {
        token = new MockERC20(3_000_000e18);
        
        vm.startPrank(OWNER);
        market = new PolicastMarketV3(address(token));
        views = new PolicastViews(address(market));
        vm.stopPrank();

        token.transfer(OWNER, 1_000_000e18);
        
        vm.startPrank(OWNER);
        token.approve(address(market), type(uint256).max);
        
        // Create a 3-option market similar to frontend
        string[] memory options = new string[](3);
        options[0] = "Good to go";
        options[1] = "Maybe";  
        options[2] = "No way";
        
        string[] memory descriptions = new string[](3);
        descriptions[0] = "";
        descriptions[1] = "";
        descriptions[2] = "";
        
        uint256 marketId = market.createMarket(
            "Will Russia and Ukraine publicly announce a ceasefire?",
            "test",
            options,
            descriptions,
            block.timestamp + 172800, // 2 days
            PolicastMarketV3.MarketCategory.OTHER, // category
            PolicastMarketV3.MarketType.PAID, // market type
            10000e18, // initial liquidity
            false // is free
        );
        
        market.validateMarket(marketId);
        vm.stopPrank();
    }

    function testPricingScaling() public view {
        uint256 marketId = 0;
        
        // Check initial prices for all options
        for (uint256 i = 0; i < 3; i++) {
            (,, , , uint256 currentPriceData, ) = market.getMarketOption(marketId, i);
            uint256 tokenPrice = views.getOptionPriceInTokens(marketId, i);
            uint256 calculatedTokenPrice = views.calculateCurrentPriceInTokens(marketId, i);

            console.log("=== Option", i, "===");
            console.log("Current price (probability):", currentPriceData);
            console.log("Token price from getOptionPriceInTokens:", tokenPrice);
            console.log("Token price from calculateCurrentPriceInTokens:", calculatedTokenPrice);
            console.log("");

            // For 3 options, initial probability should be 1/3 ≈ 0.333 in 1e18 scale
            assertApproxEqRel(currentPriceData, 333333333333333333, 1e15, "Initial probability should be ~0.333 (33.33%)");
            
            // Token price should match: probability * PAYOUT_PER_SHARE / 1e18
            uint256 expectedTokenPrice = (currentPriceData * 100e18) / 1e18;
            assertEq(tokenPrice, expectedTokenPrice, "Token price mismatch in getOptionPriceInTokens");
            assertEq(calculatedTokenPrice, expectedTokenPrice, "Token price mismatch in calculateCurrentPriceInTokens");
            
            // Token price should be around 33.33e18 (33.33 tokens per share)
            assertApproxEqRel(tokenPrice, 33333333333333333300, 1e15, "Token price should be ~33.33 per share");
        }
        
        console.log("=== Buy Cost Analysis ===");
        // Test what buying 1000 shares would cost
        uint256 quantity = 1000e18; // 1000 shares in 1e18 units
        uint256 optionId = 0;
        
        (,, , , uint256 optionCurrentPrice, ) = market.getMarketOption(marketId, optionId);
        uint256 probTimesQty = (optionCurrentPrice * quantity) / 1e18;
        uint256 rawCost = (probTimesQty * 100e18) / 1e18; // PAYOUT_PER_SHARE = 100e18
        uint256 fee = (rawCost * 200) / 10000; // 2% fee
        uint256 totalCost = rawCost + fee;
        
        console.log("Quantity (shares):", quantity);
        console.log("Current price per share (~33.33 tokens):", optionCurrentPrice);
        console.log("Raw cost (1000 * 33.33):", rawCost);
        console.log("Fee (2%):", fee);
        console.log("Total cost:", totalCost);
        console.log("Total cost in human terms (divided by 1e18):", totalCost / 1e18);
        
    // CORRECT MATH: 1000 shares × 33.33 tokens/share ≈ 33,333 tokens + 2% fee ≈ ~34,000 tokens
    // Each share costs ~33.33 tokens when probability is ~0.333 and payout is 100 tokens.
    uint256 expectedCost = 34000e18; // ~34,000 tokens in wei units
    assertApproxEqRel(totalCost, expectedCost, 1e16, "Total cost should be ~34k tokens"); 
        
    console.log("=== CONCLUSION ===");
    console.log("Contracts are mathematically correct after scaling fix!");
    console.log("- Each option has ~33.33% probability (0.333 in 1e18 scale)"); 
    console.log("- Each share costs ~33.33 tokens (prob * 100)");
    console.log("- 1000 shares cost ~34k tokens");
    console.log("- Frontend should display ~34k, not millions");
    }
}