// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {PolicastViews} from "src/PolicastViews.sol";
import {MockERC20} from "./MockERC20.sol";

contract ThreeOptionMarketPricingTest is Test {
    MockERC20 internal token;
    PolicastMarketV3 internal market;
    PolicastViews internal views;
    address internal creator = address(0xA11CE);
    address internal user1 = address(0xBEEF1);
    address internal user2 = address(0xBEEF2);

    // Constants from contract
    uint256 constant PAYOUT_PER_SHARE = 100 * 1e18; // 100 tokens
    uint256 constant PROB_EPS = 5e12; // 0.000005 (5 ppm) tolerance
    
    uint256 marketId;
    string[] optionNames;

    function setUp() public {
        token = new MockERC20(10_000_000 ether);
        vm.prank(creator);
        market = new PolicastMarketV3(address(token));
        views = new PolicastViews(address(market));
        
        // Fund accounts
        token.transfer(creator, 2_000_000 ether);
        token.transfer(user1, 1_000_000 ether);
        token.transfer(user2, 1_000_000 ether);

        // Approve spending
        vm.prank(creator);
        token.approve(address(market), type(uint256).max);
        vm.prank(user1);
        token.approve(address(market), type(uint256).max);
        vm.prank(user2);
        token.approve(address(market), type(uint256).max);

        // Grant roles
        vm.startPrank(creator);
        market.grantQuestionCreatorRole(creator);
        market.grantQuestionResolveRole(creator);
        market.grantMarketValidatorRole(creator);
        vm.stopPrank();

        // Set up 3-option market
        optionNames = new string[](3);
        optionNames[0] = "Option A";
        optionNames[1] = "Option B";
        optionNames[2] = "Option C";

        string[] memory optionDescriptions = new string[](3);
        optionDescriptions[0] = "Description A";
        optionDescriptions[1] = "Description B";
        optionDescriptions[2] = "Description C";

        // Create 3-option market
        vm.prank(creator);
        marketId = market.createMarket(
            "Test 3-Option Market",
            "Testing pricing for 3 options",
            optionNames,
            optionDescriptions,
            1 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            1000 ether, // initial liquidity
            true // early resolution allowed
        );

        // Validate market
        vm.prank(creator);
        market.validateMarket(marketId);
    }

    function test_InitialPriceDistribution() public view {
        // Test that initial prices are correctly distributed
        uint256 expectedInitialPrice = PAYOUT_PER_SHARE / 3; // ~33.33 tokens per share
        
        console2.log("Expected initial price per option:", expectedInitialPrice);
        console2.log("PAYOUT_PER_SHARE:", PAYOUT_PER_SHARE);
        
        uint256 totalPrice = 0;
        
        for (uint256 i = 0; i < 3; i++) {
            (string memory name, , , , uint256 currentPrice, bool isActive) = market.getMarketOption(marketId, i);
            
            console2.log("Option", i, "- Name:", name);
            console2.log("Option", i, "- Current Price:", currentPrice);
            console2.log("Option", i, "- Expected Price:", expectedInitialPrice);
            
            // Check that initial price is approximately equal (within small rounding tolerance)
            assertApproxEqRel(currentPrice, expectedInitialPrice, 1e15, "Initial price should be ~33.33 tokens");
            assertEq(isActive, true, "Option should be active");
            totalPrice += currentPrice;
        }
        
        console2.log("Total price sum:", totalPrice);
        console2.log("Should equal PAYOUT_PER_SHARE:", PAYOUT_PER_SHARE);
        
        // Test that total prices sum to PAYOUT_PER_SHARE (within tolerance)
        assertApproxEqAbs(totalPrice, PAYOUT_PER_SHARE, PROB_EPS, "Total prices should sum to PAYOUT_PER_SHARE");
    }

    function test_PriceSumInvariantAfterTrades() public {
        // Buy shares in option 0 to change prices
        vm.prank(user1);
        market.buyShares(marketId, 0, 10 ether, type(uint256).max, 0);
        
        uint256 totalPrice = 0;
        uint256[] memory prices = new uint256[](3);
        
        for (uint256 i = 0; i < 3; i++) {
            (,,,, uint256 currentPrice,) = market.getMarketOption(marketId, i);
            prices[i] = currentPrice;
            totalPrice += currentPrice;
            console2.log("Option", i, "price after trade:", currentPrice);
        }
        
        console2.log("Total price sum after trade:", totalPrice);
        
        // Verify prices still sum to PAYOUT_PER_SHARE
        assertApproxEqAbs(totalPrice, PAYOUT_PER_SHARE, PROB_EPS, "Prices should still sum to PAYOUT_PER_SHARE after trade");
        
        // Option 0 should have higher price after buying
        assertGt(prices[0], PAYOUT_PER_SHARE / 3, "Option 0 price should increase after buying");
        
        // Other options should have lower prices
        assertLt(prices[1], PAYOUT_PER_SHARE / 3, "Option 1 price should decrease");
        assertLt(prices[2], PAYOUT_PER_SHARE / 3, "Option 2 price should decrease");
    }

    function test_PriceMovementDirection() public {
        // Record initial prices
        uint256[] memory initialPrices = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            (,,,, uint256 currentPrice,) = market.getMarketOption(marketId, i);
            initialPrices[i] = currentPrice;
        }
        
        // Buy shares in option 1
        vm.prank(user1);
        market.buyShares(marketId, 1, 5 ether, type(uint256).max, 0);
        
        // Check price changes
        for (uint256 i = 0; i < 3; i++) {
            (,,,, uint256 currentPrice,) = market.getMarketOption(marketId, i);
            
            if (i == 1) {
                assertGt(currentPrice, initialPrices[i], "Bought option should have higher price");
                console2.log("Option 1 price increased from");
            console2.log("From:", initialPrices[i]);
            console2.log("To:", currentPrice);
            } else {
                assertLt(currentPrice, initialPrices[i], "Other options should have lower prices");
                console2.log("Option", i);
            console2.log("Price decreased from", initialPrices[i]);
            console2.log("Price decreased to", currentPrice);
            }
        }
    }

    function test_ExtremePriceScenario() public {
        // Buy a lot of shares in option 0 to drive up price significantly
        vm.prank(user1);
        market.buyShares(marketId, 0, 100 ether, type(uint256).max, 0);
        
        uint256 totalPrice = 0;
        uint256[] memory prices = new uint256[](3);
        
        for (uint256 i = 0; i < 3; i++) {
            (,,,, uint256 currentPrice,) = market.getMarketOption(marketId, i);
            prices[i] = currentPrice;
            totalPrice += currentPrice;
            console2.log("Option", i, "price after large buy:", currentPrice);
        }
        
        console2.log("Total price sum after large trade:", totalPrice);
        
        // Verify invariants still hold
        assertApproxEqAbs(totalPrice, PAYOUT_PER_SHARE, PROB_EPS, "Prices should still sum to PAYOUT_PER_SHARE");
        
        // Option 0 should dominate
        assertGt(prices[0], PAYOUT_PER_SHARE / 2, "Heavily bought option should have >50% probability");
        
        // No price should exceed PAYOUT_PER_SHARE
        for (uint256 i = 0; i < 3; i++) {
            assertLe(prices[i], PAYOUT_PER_SHARE, "No option price should exceed PAYOUT_PER_SHARE");
        }
    }

    function test_BuyAndSellRoundTrip() public {
        // Record initial state
        uint256[] memory initialPrices = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            (,,,, uint256 currentPrice,) = market.getMarketOption(marketId, i);
            initialPrices[i] = currentPrice;
        }
        
        // Buy shares
        uint256 shareAmount = 5 ether;
        vm.prank(user1);
        market.buyShares(marketId, 0, shareAmount, type(uint256).max, 0);
        
        // Check shares were purchased
        uint256 userShares = market.getMarketOptionUserShares(marketId, 0, user1);
        assertEq(userShares, shareAmount, "User should own the shares purchased");
        
        // Sell all shares back
        vm.prank(user1);
        market.sellShares(marketId, 0, shareAmount, 0, 0);
        
        // Check shares were sold
        userShares = market.getMarketOptionUserShares(marketId, 0, user1);
        assertEq(userShares, 0, "User should have no shares after selling");
        
        // Check prices returned close to initial (within small tolerance due to fees)
        for (uint256 i = 0; i < 3; i++) {
            (,,,, uint256 currentPrice,) = market.getMarketOption(marketId, i);
            console2.log("Option", i);
            console2.log("Initial price:", initialPrices[i]);
            console2.log("Final price:", currentPrice);
            
            // Prices should be close to initial (allowing for fees and rounding)
            assertApproxEqRel(currentPrice, initialPrices[i], 5e16, "Prices should return close to initial after round trip");
        }
    }

    function test_PriceCalculationConsistency() public {
        // Test that calculateSellPrice gives consistent results
        
        // Buy some shares first
        vm.prank(user1);
        market.buyShares(marketId, 1, 10 ether, type(uint256).max, 0);
        
        uint256 userShares = market.getMarketOptionUserShares(marketId, 1, user1);
        assertEq(userShares, 10 ether, "User should own 10 shares");
        
        // Calculate sell price for partial amount
        uint256 sellAmount = 3 ether;
        uint256 expectedPrice = market.calculateSellPrice(marketId, 1, sellAmount);
        console2.log("Expected sell price for shares:");
        console2.log("Sell amount:", sellAmount);
        console2.log("Expected price:", expectedPrice);
        
        // Record balance before sell
        uint256 balanceBefore = token.balanceOf(user1);
        
        // Actually sell the shares
        vm.prank(user1);
        market.sellShares(marketId, 1, sellAmount, 0, 0);
        
        uint256 balanceAfter = token.balanceOf(user1);
        uint256 actualReceived = balanceAfter - balanceBefore;
        
        console2.log("Actually received:", actualReceived);
        
        // Should match (within small rounding tolerance)
        assertApproxEqRel(actualReceived, expectedPrice, 1e12, "Actual sell proceeds should match calculated price");
    }

    function test_PriceValidationBounds() public {
        // Test that individual prices never exceed PAYOUT_PER_SHARE
        // and sum always equals PAYOUT_PER_SHARE
        
        // Perform multiple random trades
        for (uint256 round = 0; round < 10; round++) {
            // Choose random option and amount
            uint256 optionId = round % 3;
            uint256 amount = (round + 1) * 1 ether;
            
            vm.prank(user1);
            market.buyShares(marketId, optionId, amount, type(uint256).max, 0);
            
            // Validate prices after each trade
            uint256 totalPrice = 0;
            for (uint256 i = 0; i < 3; i++) {
                (,,,, uint256 currentPrice,) = market.getMarketOption(marketId, i);
                
                // Individual price should not exceed PAYOUT_PER_SHARE
                assertLe(currentPrice, PAYOUT_PER_SHARE, "Individual price should not exceed PAYOUT_PER_SHARE");
                
                // Price should be positive
                assertGt(currentPrice, 0, "Price should be positive");
                
                totalPrice += currentPrice;
            }
            
            // Total should equal PAYOUT_PER_SHARE
            assertApproxEqAbs(totalPrice, PAYOUT_PER_SHARE, PROB_EPS, "Total prices should sum to PAYOUT_PER_SHARE");
        }
    }

    function test_InitialPriceExactCalculation() public view {
        // Test exact calculation of initial prices
        uint256 expectedPrice = PAYOUT_PER_SHARE / 3; // Should be 33333333333333333333
        
        console2.log("PAYOUT_PER_SHARE:", PAYOUT_PER_SHARE);
        console2.log("Number of options: 3");
        console2.log("Expected price per option:", expectedPrice);
        console2.log("Expected price in human terms:");
        console2.log("Price per token:", expectedPrice / 1e18);
        
        // Check remainder to understand rounding
        uint256 remainder = PAYOUT_PER_SHARE % 3;
        console2.log("Remainder when dividing PAYOUT_PER_SHARE by 3:", remainder);
        
        // The actual prices should handle the remainder appropriately
        uint256 totalActualPrices = 0;
        for (uint256 i = 0; i < 3; i++) {
            (,,,, uint256 actualPrice,) = market.getMarketOption(marketId, i);
            totalActualPrices += actualPrice;
            console2.log("Option", i, "actual price:", actualPrice);
        }
        
        console2.log("Total actual prices:", totalActualPrices);
        assertEq(totalActualPrices, PAYOUT_PER_SHARE, "Total actual prices should exactly equal PAYOUT_PER_SHARE");
    }

    function test_BuySameOptionTwice() public {
        // Record initial state
        uint256[] memory initialPrices = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            (,,,, uint256 currentPrice,) = market.getMarketOption(marketId, i);
            initialPrices[i] = currentPrice;
            console2.log("Initial Option", i, "price:", currentPrice);
        }
        
        uint256 buyAmount = 5 ether;
        
        // First buy
        console2.log("\n=== FIRST BUY ===");
        uint256 balanceBefore1 = token.balanceOf(user1);
        
        vm.prank(user1);
        market.buyShares(marketId, 1, buyAmount, type(uint256).max, 0);
        
        uint256 balanceAfter1 = token.balanceOf(user1);
        uint256 cost1 = balanceBefore1 - balanceAfter1;
        console2.log("First buy cost:", cost1);
        
        // Check prices after first buy
        uint256[] memory pricesAfterFirst = new uint256[](3);
        uint256 totalAfterFirst = 0;
        for (uint256 i = 0; i < 3; i++) {
            (,,,, uint256 currentPrice,) = market.getMarketOption(marketId, i);
            pricesAfterFirst[i] = currentPrice;
            totalAfterFirst += currentPrice;
            console2.log("After first buy - Option", i, "price:", currentPrice);
        }
        console2.log("Total price sum after first buy:", totalAfterFirst);
        
        // Check shares after first buy
        uint256 sharesAfterFirst = market.getMarketOptionUserShares(marketId, 1, user1);
        console2.log("User shares after first buy:", sharesAfterFirst);
        assertEq(sharesAfterFirst, buyAmount, "Should have bought correct amount of shares");
        
        // Second buy - same option, same amount
        console2.log("\n=== SECOND BUY ===");
        uint256 balanceBefore2 = token.balanceOf(user1);
        
        vm.prank(user1);
        market.buyShares(marketId, 1, buyAmount, type(uint256).max, 0);
        
        uint256 balanceAfter2 = token.balanceOf(user1);
        uint256 cost2 = balanceBefore2 - balanceAfter2;
        console2.log("Second buy cost:", cost2);
        
        // Check prices after second buy
        uint256[] memory pricesAfterSecond = new uint256[](3);
        uint256 totalAfterSecond = 0;
        for (uint256 i = 0; i < 3; i++) {
            (,,,, uint256 currentPrice,) = market.getMarketOption(marketId, i);
            pricesAfterSecond[i] = currentPrice;
            totalAfterSecond += currentPrice;
            console2.log("After second buy - Option", i, "price:", currentPrice);
        }
        console2.log("Total price sum after second buy:", totalAfterSecond);
        
        // Check shares after second buy
        uint256 sharesAfterSecond = market.getMarketOptionUserShares(marketId, 1, user1);
        console2.log("User shares after second buy:", sharesAfterSecond);
        assertEq(sharesAfterSecond, buyAmount * 2, "Should have double the shares");
        
        // Analysis
        console2.log("\n=== ANALYSIS ===");
        console2.log("Cost comparison:");
        console2.log("First buy cost:", cost1);
        console2.log("Second buy cost:", cost2);
        console2.log("Cost difference:", cost2 > cost1 ? cost2 - cost1 : cost1 - cost2);
        console2.log("Second buy more expensive?", cost2 > cost1);
        
        // Price movement analysis
        console2.log("\nPrice movement analysis:");
        for (uint256 i = 0; i < 3; i++) {
            console2.log("Option", i, ":");
            console2.log("  Initial:", initialPrices[i]);
            console2.log("  After 1st buy:", pricesAfterFirst[i]);
            console2.log("  After 2nd buy:", pricesAfterSecond[i]);
        }
        
        // Assertions
        assertGt(cost2, cost1, "Second buy should be more expensive due to price impact");
        assertGt(pricesAfterSecond[1], pricesAfterFirst[1], "Option 1 price should keep increasing");
        assertLt(pricesAfterSecond[0], pricesAfterFirst[0], "Other options should decrease further");
        assertLt(pricesAfterSecond[2], pricesAfterFirst[2], "Other options should decrease further");
        
        // Total price invariant should hold
        assertApproxEqAbs(totalAfterFirst, PAYOUT_PER_SHARE, PROB_EPS, "Total should equal PAYOUT_PER_SHARE after first buy");
        assertApproxEqAbs(totalAfterSecond, PAYOUT_PER_SHARE, PROB_EPS, "Total should equal PAYOUT_PER_SHARE after second buy");
    }

    function test_MultipleBuysOnSameOption() public {
        uint256 buyAmount = 2 ether;
        uint256 totalCost = 0;
        uint256[] memory costs = new uint256[](5);
        
        console2.log("=== BUYING SAME OPTION 5 TIMES ===");
        
        for (uint256 round = 0; round < 5; round++) {
            uint256 balanceBefore = token.balanceOf(user1);
            
            vm.prank(user1);
            market.buyShares(marketId, 0, buyAmount, type(uint256).max, 0);
            
            uint256 balanceAfter = token.balanceOf(user1);
            costs[round] = balanceBefore - balanceAfter;
            totalCost += costs[round];
            
            console2.log("Round", round + 1, "cost:", costs[round]);
            
            // Check current price of option 0
            (,,,, uint256 currentPrice,) = market.getMarketOption(marketId, 0);
            console2.log("Option 0 price after round", round + 1, ":", currentPrice);
            
            // Check total shares owned
            uint256 totalShares = market.getMarketOptionUserShares(marketId, 0, user1);
            console2.log("Total shares owned:", totalShares);
            
            console2.log("---");
        }
        
        console2.log("\n=== COST ANALYSIS ===");
        console2.log("Total cost for", buyAmount * 5 / 1e18, "shares:", totalCost);
        console2.log("Average cost per round:", totalCost / 5);
        
        for (uint256 i = 1; i < 5; i++) {
            console2.log(string(abi.encodePacked("Round ", vm.toString(i + 1), " vs Round ", vm.toString(i), " cost increase: ", vm.toString(costs[i] - costs[i-1]))));
            assertGt(costs[i], costs[i-1], "Each subsequent buy should be more expensive");
        }
        
        // Final price check
        uint256 totalPriceSum = 0;
        for (uint256 i = 0; i < 3; i++) {
            (,,,, uint256 currentPrice,) = market.getMarketOption(marketId, i);
            totalPriceSum += currentPrice;
            console2.log("Final Option", i, "price:", currentPrice);
        }
        console2.log("Final total price sum:", totalPriceSum);
        
        // Option 0 should dominate
        (,,,, uint256 option0Price,) = market.getMarketOption(marketId, 0);
        assertGt(option0Price, PAYOUT_PER_SHARE / 2, "Heavily bought option should have >50% probability");
        
        // Invariant should still hold
        assertApproxEqAbs(totalPriceSum, PAYOUT_PER_SHARE, PROB_EPS, "Total prices should still sum to PAYOUT_PER_SHARE");
    }

    function test_SimpleDoubleBuy() public {
        console2.log("=== SIMPLE DOUBLE BUY TEST ===");
        
        // Record initial prices
        (,,,, uint256 initialPrice1,) = market.getMarketOption(marketId, 1);
        console2.log("Initial Option 1 price:", initialPrice1);
        
        // Buy 1 share
        vm.prank(user1);
        market.buyShares(marketId, 1, 1 ether, type(uint256).max, 0);
        
        (,,,, uint256 priceAfter1Share,) = market.getMarketOption(marketId, 1);
        console2.log("Price after buying 1 share:", priceAfter1Share);
        
        // Buy 1 more share
        vm.prank(user1);
        market.buyShares(marketId, 1, 1 ether, type(uint256).max, 0);
        
        (,,,, uint256 priceAfter2Shares,) = market.getMarketOption(marketId, 1);
        console2.log("Price after buying 2nd share:", priceAfter2Shares);
        
        // Check total shares
        uint256 totalShares = market.getMarketOptionUserShares(marketId, 1, user1);
        console2.log("Total shares owned:", totalShares);
        
        // This should be true: price should increase with more demand
        assertGt(priceAfter1Share, initialPrice1, "Price should increase after first buy");
        // This is failing in the main test - let's see what happens here
        console2.log("Does price increase after second buy?", priceAfter2Shares > priceAfter1Share);
        
        // Let's check the total shares in each option to understand LMSR behavior
        console2.log("\n=== LMSR DEBUG INFO ===");
        for (uint256 i = 0; i < 3; i++) {
            (, , uint256 optionTotalShares, , uint256 currentPrice,) = market.getMarketOption(marketId, i);
            console2.log("Option", i);
            console2.log("  Total shares:", optionTotalShares);
            console2.log("  Price:", currentPrice);
        }
    }

    function test_PricingLogicAnalysis() public {
        console2.log("=== PRICING LOGIC ANALYSIS ===");
        
        // Check initial state
        (,,,, uint256 initialPrice,) = market.getMarketOption(marketId, 1);
        console2.log("Initial Option 1 price:", initialPrice);
        console2.log("Initial price in tokens:", initialPrice / 1e18);
        console2.log("Expected initial price should be ~33.33 tokens");
        
        uint256 sharesToBuy = 1 ether; // 1 share
        console2.log("Buying", sharesToBuy / 1e18, "shares");
        
        // Calculate expected cost based on current price
        uint256 expectedCostBasedOnPrice = (initialPrice * sharesToBuy) / 1e18;
        console2.log("Expected cost based on price:", expectedCostBasedOnPrice / 1e18, "tokens");
        
        // Record balance before purchase
        uint256 balanceBefore = token.balanceOf(user1);
        console2.log("Balance before:", balanceBefore / 1e18, "tokens");
        
        // Make the purchase
        vm.prank(user1);
        market.buyShares(marketId, 1, sharesToBuy, type(uint256).max, 0);
        
        // Record balance after purchase
        uint256 balanceAfter = token.balanceOf(user1);
        uint256 actualCost = balanceBefore - balanceAfter;
        console2.log("Balance after:", balanceAfter / 1e18, "tokens");
        console2.log("Actual cost:", actualCost / 1e18, "tokens");
        
        // Check shares received
        uint256 sharesReceived = market.getMarketOptionUserShares(marketId, 1, user1);
        console2.log("Shares received:", sharesReceived / 1e18);
        
        // Analyze the discrepancy
        console2.log("\n=== ANALYSIS ===");
        console2.log("Expected cost based on price:", expectedCostBasedOnPrice / 1e18, "tokens");
        console2.log("Actual cost paid:", actualCost / 1e18, "tokens");
        
        if (actualCost < expectedCostBasedOnPrice) {
            console2.log("ISSUE: Actual cost is LESS than expected!");
            console2.log("Difference:", (expectedCostBasedOnPrice - actualCost) / 1e18, "tokens");
        } else {
            console2.log("Actual cost is higher than simple price calculation");
            console2.log("This could be due to LMSR price impact");
        }
        
        // Check new price after purchase
        (,,,, uint256 newPrice,) = market.getMarketOption(marketId, 1);
        console2.log("New price after purchase:", newPrice / 1e18, "tokens");
        console2.log("Price increased by:", (newPrice - initialPrice) / 1e18, "tokens");
        
        // This is the key assertion - if initial price is 33.33 tokens,
        // buying 1 share should cost approximately that much (plus fees and price impact)
        console2.log("\n=== KEY ISSUE IDENTIFIED ===");
        console2.log("If price shows ~33.33 tokens per share, buying 1 share should cost close to that");
        console2.log("But actual cost is much lower, suggesting price display vs actual cost mismatch");
    }

    function test_DeepDiveIntoLMSRCalculations() public {
        console2.log("=== DEEP DIVE INTO LMSR CALCULATIONS ===");
        
        // Get initial market state
        uint256 lmsrB = market.getMarketLMSRB(marketId);
        console2.log("Market LMSR B parameter:", lmsrB / 1e18);
        console2.log("Market LMSR B parameter (wei):", lmsrB);
        
        // Check initial shares (should all be 0)
        console2.log("\n=== INITIAL SHARES ===");
        for (uint256 i = 0; i < 3; i++) {
            (, , uint256 totalShares, , uint256 currentPrice,) = market.getMarketOption(marketId, i);
            console2.log("Option", i);
            console2.log("  Shares:", totalShares / 1e18);
            console2.log("  Price:", currentPrice / 1e18);
        }
        
        // Calculate initial LMSR cost (should be close to 0 for all 0 shares)
        console2.log("\n=== INITIAL LMSR COST ===");
        // We can't directly call internal functions, so let's examine what happens during first trade
        
        console2.log("Simulating cost calculation for buying 1 share of option 1");
        
        // Check balance and make trade
        uint256 balanceBefore = token.balanceOf(user1);
        console2.log("Balance before trade:", balanceBefore / 1e18);
        
        // Buy 1 share
        vm.prank(user1);
        market.buyShares(marketId, 1, 1 ether, type(uint256).max, 0);
        
        uint256 balanceAfter = token.balanceOf(user1);
        uint256 actualCost = balanceBefore - balanceAfter;
        console2.log("Actual cost paid:", actualCost / 1e18, "tokens");
        
        console2.log("\n=== TESTING LARGER TRADE ===");
        console2.log("Simulating cost for buying 10 shares of option 0");
        
        balanceBefore = token.balanceOf(user1);
        console2.log("Balance before larger trade:", balanceBefore / 1e18);
        
        vm.prank(user1);
        market.buyShares(marketId, 0, 10 ether, type(uint256).max, 0);
        
        balanceAfter = token.balanceOf(user1);
        actualCost = balanceBefore - balanceAfter;
        console2.log("Actual cost for 10 shares:", actualCost / 1e18, "tokens");
        console2.log("Average cost per share:", actualCost / (10 ether), "tokens");
        
        // Check new state after trade
        console2.log("\n=== AFTER FIRST TRADE ===");
        for (uint256 i = 0; i < 3; i++) {
            (, , uint256 totalShares, , uint256 currentPrice,) = market.getMarketOption(marketId, i);
            console2.log("Option", i);
            console2.log("  Shares:", totalShares / 1e18);
            console2.log("  Price:", currentPrice / 1e18);
        }
        
        // Key insight: Check if the issue is in initial setup or LMSR calculation
        console2.log("\n=== ANALYSIS ===");
        console2.log("LMSR B parameter:", lmsrB / 1e18, "tokens");
        console2.log("Initial liquidity was: 1000 tokens");
        console2.log("Expected B parameter relationship to initial liquidity");
        
        // Try to understand the LMSR cost calculation
        // LMSR cost = b * ln(sum(exp(q_i/b))) where q_i are share quantities
        // For initial state: all q_i = 0, so cost = b * ln(3) ≈ b * 1.099
        
        uint256 expectedInitialCost = (lmsrB * 1099) / 1000; // approximation of b * ln(3)
        console2.log("Expected initial LMSR cost (b * ln(3)):", expectedInitialCost / 1e18);
        
        // The cost of buying 1 share should be the marginal cost at q=[0,1,0]
        // vs cost at q=[0,0,0]
        
        console2.log("\n=== KEY INSIGHT ===");
        console2.log("Cost to buy 1 share:", actualCost / 1e18, "tokens");
        console2.log("But displayed price was ~33 tokens");
        console2.log("This suggests the 'price' and 'marginal cost' are different concepts");
        console2.log("Price might be probability * PAYOUT_PER_SHARE, not actual trading cost");
    }
}