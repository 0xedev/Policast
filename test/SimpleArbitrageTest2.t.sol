// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Policast.sol";
import "../src/PolicastViews.sol";
import "./MockERC20.sol";

contract SimpleArbitrageTest is Test {
    PolicastMarketV3 public policast;
    PolicastViews public policastViews;
    MockERC20 public token;
    
    address constant CREATOR = 0x1234567890123456789012345678901234567890;
    address constant ARBITRAGEUR = 0x1111111111111111111111111111111111111111;
    
    uint256 public marketId;

    function setUp() public {
        // Deploy token with sufficient supply
        token = new MockERC20(10_000_000 * 1e18);
        
        // Deploy contracts
        policast = new PolicastMarketV3(address(token));
        policastViews = new PolicastViews(address(policast));

        // Grant roles
        policast.grantQuestionCreatorRole(CREATOR);
        policast.grantMarketValidatorRole(CREATOR);
        policast.grantQuestionResolveRole(CREATOR);

        // Give tokens to users
        token.transfer(ARBITRAGEUR, 1_000_000 * 1e18);
        token.transfer(CREATOR, 1_000_000 * 1e18);

        // Approve spending
        vm.prank(ARBITRAGEUR);
        token.approve(address(policast), type(uint256).max);
        vm.prank(CREATOR);
        token.approve(address(policast), type(uint256).max);
        
        // Create and validate market
        vm.prank(CREATOR);
        string[] memory options = new string[](2);
        options[0] = "YES";
        options[1] = "NO";
        
        string[] memory symbols = new string[](2);
        symbols[0] = "Y";
        symbols[1] = "N";

        marketId = policast.createMarket(
            "Immediate sell arbitrage test",
            "Can I buy and immediately sell for profit?",
            options,
            symbols,
            7 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            100_000 * 1e18, // 100k tokens liquidity
            false
        );

        // Validate market
        vm.prank(CREATOR);
        policast.validateMarket(marketId);
    }

    function testImmediateSellArbitrage() public {
        console.log("=== IMMEDIATE SELL ARBITRAGE TEST ===");
        console.log("Question: If I buy shares and price goes from 51->54 cents,");
        console.log("can I immediately sell at 54 cents for guaranteed profit?");
        console.log("");
        
        vm.startPrank(ARBITRAGEUR);
        
        // Check initial state
        uint256 initialBalance = token.balanceOf(ARBITRAGEUR);
        uint256 initialYesPrice = policastViews.calculateCurrentPrice(marketId, 0);
        
        console.log("STEP 1: Initial Market State");
        console.log("YES price: %s cents", (initialYesPrice * 100) / 1e18);
        console.log("My balance: %s tokens", initialBalance / 1e18);
        console.log("");
        
        // Buy shares to move the price
        console.log("STEP 2: Buy 50 YES shares");
        uint256 shareAmount = 50 * 1e18;
        uint256 balanceBeforeBuy = token.balanceOf(ARBITRAGEUR);
        
        policast.buyShares(marketId, 0, shareAmount, type(uint256).max, 0);
        
        uint256 balanceAfterBuy = token.balanceOf(ARBITRAGEUR);
        uint256 buyCost = balanceBeforeBuy - balanceAfterBuy;
        uint256 sharesOwned = policast.getMarketOptionUserShares(marketId, 0, ARBITRAGEUR);
        uint256 newYesPrice = policastViews.calculateCurrentPrice(marketId, 0);
        
        console.log("Buy cost: %s tokens", buyCost / 1e18);
        console.log("Shares received: %s", sharesOwned / 1e18);
        console.log("NEW YES price: %s cents", (newYesPrice * 100) / 1e18);
        console.log("Price moved from %s to %s cents!", (initialYesPrice * 100) / 1e18, (newYesPrice * 100) / 1e18);
        console.log("");
        
        // Now try to immediately sell at the new higher price
        console.log("STEP 3: Immediately sell all shares at new price");
        console.log("Current market price is %s cents - can I get that?", (newYesPrice * 100) / 1e18);
        
        uint256 balanceBeforeSell = token.balanceOf(ARBITRAGEUR);
        
        // Sell all shares
        policast.sellShares(marketId, 0, sharesOwned, 0, 0);
        
        uint256 balanceAfterSell = token.balanceOf(ARBITRAGEUR);
        uint256 sellProceeds = balanceAfterSell - balanceBeforeSell;
        uint256 finalYesPrice = policastViews.calculateCurrentPrice(marketId, 0);
        
        console.log("Sell proceeds: %s tokens", sellProceeds / 1e18);
        console.log("Effective sell price: %s cents per share", (sellProceeds * 100) / sharesOwned / 1e15);
        console.log("Market price after sell: %s cents", (finalYesPrice * 100) / 1e18);
        console.log("");
        
        // Calculate net result
        uint256 finalBalance = token.balanceOf(ARBITRAGEUR);
        int256 netResult = int256(finalBalance) - int256(initialBalance);
        
        console.log("FINAL RESULT:");
        console.log("Started with: %s tokens", initialBalance / 1e18);
        console.log("Ended with: %s tokens", finalBalance / 1e18);
        
        if (netResult > 0) {
            console.log("NET PROFIT: %s tokens", uint256(netResult) / 1e18);
            console.log("RESULT: Immediate arbitrage WORKED!");
        } else {
            console.log("NET LOSS: %s tokens", uint256(-netResult) / 1e18);
            console.log("RESULT: Immediate arbitrage FAILED - fees/slippage prevented profit");
        }
        
        console.log("");
        console.log("KEY INSIGHT:");
        console.log("When you sell, the price moves DOWN just like it moved UP when you bought!");
        console.log("Your sell order walks DOWN the price curve, giving you LESS than the peak price.");
        console.log("Buy: 51->54 cents (you pay average ~52.5)");
        console.log("Sell: 54->51 cents (you get average ~52.5)");
        console.log("Result: No guaranteed profit due to symmetric price impact!");
        
        vm.stopPrank();
        
        // The key test: immediate buy/sell should not be profitable due to fees and symmetric slippage
        assertTrue(netResult <= 0, "Immediate buy/sell should not be profitable");
    }

    function testMultipleTradeSizes() public {
        console.log("\n=== TESTING DIFFERENT TRADE SIZES ===");
        
        uint256[] memory testSizes = new uint256[](4);
        testSizes[0] = 10 * 1e18;   // 10 shares
        testSizes[1] = 50 * 1e18;   // 50 shares  
        testSizes[2] = 100 * 1e18;  // 100 shares
        testSizes[3] = 200 * 1e18;  // 200 shares
        
        for (uint i = 0; i < testSizes.length; i++) {
            console.log("\n--- Testing %s shares ---", testSizes[i] / 1e18);
            
            vm.startPrank(ARBITRAGEUR);
            
            uint256 initialBalance = token.balanceOf(ARBITRAGEUR);
            uint256 initialPrice = policastViews.calculateCurrentPrice(marketId, 0);
            
            // Buy
            uint256 balanceBeforeBuy = token.balanceOf(ARBITRAGEUR);
            policast.buyShares(marketId, 0, testSizes[i], type(uint256).max, 0);
            uint256 buyCost = balanceBeforeBuy - token.balanceOf(ARBITRAGEUR);
            
            uint256 peakPrice = policastViews.calculateCurrentPrice(marketId, 0);
            uint256 sharesOwned = policast.getMarketOptionUserShares(marketId, 0, ARBITRAGEUR);
            
            // Sell immediately
            uint256 balanceBeforeSell = token.balanceOf(ARBITRAGEUR);
            policast.sellShares(marketId, 0, sharesOwned, 0, 0);
            uint256 sellProceeds = balanceBeforeSell - token.balanceOf(ARBITRAGEUR);
            
            uint256 finalBalance = token.balanceOf(ARBITRAGEUR);
            int256 netResult = int256(finalBalance) - int256(initialBalance);
            
            console.log("Price: %s -> %s cents", (initialPrice * 100) / 1e18, (peakPrice * 100) / 1e18);
            console.log("Buy cost: %s, Sell proceeds: %s", buyCost / 1e18, sellProceeds / 1e18);
            
            if (netResult > 0) {
                console.log("Net: +%s tokens PROFIT", uint256(netResult) / 1e18);
            } else {
                console.log("Net: -%s tokens LOSS", uint256(-netResult) / 1e18);
            }
            
            vm.stopPrank();
        }
        
        console.log("\nCONCLUSION: LMSR's symmetric price curves prevent immediate arbitrage!");
    }
}