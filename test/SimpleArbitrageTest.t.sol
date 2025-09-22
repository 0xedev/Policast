// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/Policast.sol";
import "../src/PolicastViews.sol";
import "./MockERC20.sol";

contract SimpleArbitrageTest is Test {
    PolicastMarketV3 public policast;
    PolicastViews public policastViews;
    MockERC20 public token;
    
    address public constant CREATOR = address(0x1);
    address public constant LIQUIDITY_PROVIDER = address(0x2);
    address public constant ARBITRAGEUR = address(0x3);
    
    uint256 public marketId;
    
    function setUp() public {
        token = new MockERC20(10_000_000 * 1e18);
        policast = new PolicastMarketV3(address(token));
        policastViews = new PolicastViews(address(policast));
        
        // Grant necessary roles
        policast.grantQuestionCreatorRole(CREATOR);
        policast.grantMarketValidatorRole(CREATOR);
        policast.grantQuestionResolveRole(CREATOR);
        
        // Setup accounts - transfer tokens from initial supply
        token.transfer(CREATOR, 1_000_000 * 1e18);
        token.transfer(LIQUIDITY_PROVIDER, 1_000_000 * 1e18);
        token.transfer(ARBITRAGEUR, 1_000_000 * 1e18);
        
        // Approve spending
        vm.prank(CREATOR);
        token.approve(address(policast), type(uint256).max);
        
        vm.prank(LIQUIDITY_PROVIDER);
        token.approve(address(policast), type(uint256).max);
        
        vm.prank(ARBITRAGEUR);
        token.approve(address(policast), type(uint256).max);
        
        // Create market
        vm.prank(CREATOR);
        string[] memory options = new string[](2);
        options[0] = "YES";
        options[1] = "NO";
        
        string[] memory symbols = new string[](2);
        symbols[0] = "Y";
        symbols[1] = "N";
        
        marketId = policast.createMarket(
            "Test binary market for arbitrage testing",
            "Will arbitrage be prevented?",
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
    
    function testBasicArbitrageAttempt() public {
        console.log("=== BASIC ARBITRAGE ATTEMPT TEST ===");
        
        // Check initial prices using the views contract
        uint256 initialYesPrice = policastViews.calculateCurrentPrice(marketId, 0);
        uint256 initialNoPrice = policastViews.calculateCurrentPrice(marketId, 1);
        
        console.log("Initial YES price (probability):", initialYesPrice / 1e15); // Show as basis points
        console.log("Initial NO price (probability):", initialNoPrice / 1e15);
        
        console.log("Testing if buying both sides guarantees profit...");
        
        // Try to buy shares of each option to test arbitrage prevention
        uint256 shareAmount = 10 * 1e18; // 10 shares
        
        vm.startPrank(ARBITRAGEUR);
        
        uint256 initialBalance = token.balanceOf(ARBITRAGEUR);
        console.log("Arbitrageur initial balance:", initialBalance / 1e18);
        
        // Buy YES shares
        uint256 yesBalanceBefore = token.balanceOf(ARBITRAGEUR);
        policast.buyShares(marketId, 0, shareAmount, type(uint256).max, 0);
        uint256 yesCost = yesBalanceBefore - token.balanceOf(ARBITRAGEUR);
        
        // Buy NO shares  
        uint256 noBalanceBefore = token.balanceOf(ARBITRAGEUR);
        policast.buyShares(marketId, 1, shareAmount, type(uint256).max, 0);
        uint256 noCost = noBalanceBefore - token.balanceOf(ARBITRAGEUR);
        
        uint256 totalCost = yesCost + noCost;
        uint256 guaranteedPayout = (shareAmount / 1e18) * 100; // 100 tokens per winning share
        
        vm.stopPrank();
        
        console.log("YES shares cost:", yesCost / 1e18, "tokens");
        console.log("NO shares cost:", noCost / 1e18, "tokens");
        console.log("Total cost:", totalCost / 1e18, "tokens");
        console.log("Guaranteed payout:", guaranteedPayout, "tokens");
        
        if (totalCost > (guaranteedPayout * 1e18)) {
            console.log("PASS: Arbitrage prevented - cost exceeds guaranteed payout");
        } else {
            console.log("FAIL: Arbitrage possible - cost less than payout!");
        }
        
        // Verify arbitrage is prevented
        assertGt(totalCost, guaranteedPayout * 1e18, "LMSR should prevent guaranteed arbitrage");
    }
    
    function testRapidTradingArbitrage() public {
        console.log("=== RAPID TRADING ARBITRAGE TEST ===");
        
        vm.startPrank(ARBITRAGEUR);
        uint256 initialBalance = token.balanceOf(ARBITRAGEUR);
        console.log("Initial balance:", initialBalance / 1e18);
        
        // Buy shares
        uint256 shareAmount = 100 * 1e18; // 100 shares
        uint256 balanceBeforeBuy = token.balanceOf(ARBITRAGEUR);
        policast.buyShares(marketId, 0, shareAmount, type(uint256).max, 0);
        uint256 buyCost = balanceBeforeBuy - token.balanceOf(ARBITRAGEUR);
        
        // Check shares owned
        uint256 sharesOwned = policast.getMarketOptionUserShares(marketId, 0, ARBITRAGEUR);
        console.log("Shares owned:", sharesOwned / 1e18);
        
        // Immediately sell them back
        uint256 balanceBeforeSell = token.balanceOf(ARBITRAGEUR);
        policast.sellShares(marketId, 0, sharesOwned, 0, 0);
        uint256 sellProceeds = token.balanceOf(ARBITRAGEUR) - balanceBeforeSell;
        
        uint256 finalBalance = token.balanceOf(ARBITRAGEUR);
        int256 netResult = int256(finalBalance) - int256(initialBalance);
        
        vm.stopPrank();
        
        console.log("Buy cost:", buyCost / 1e18);
        console.log("Sell proceeds:", sellProceeds / 1e18);
        console.log("Net result:", netResult / int256(1e18));
        
        if (finalBalance <= initialBalance) {
            console.log("PASS: Rapid trading arbitrage prevented by fees/slippage");
        } else {
            console.log("FAIL: Rapid trading arbitrage profitable!");
        }
        
        // Verify rapid trading doesn't create profit
        assertLe(finalBalance, initialBalance, "Rapid trading should not be profitable due to fees");
    }
    
    function testPriceConsistency() public {
        console.log("=== PRICE CONSISTENCY TEST ===");
        
        // Check that prices always sum to close to 100% by calculating costs for small amounts
        vm.startPrank(ARBITRAGEUR);
        
        uint256 testAmount = 1 * 1e18; // 1 share
        
        // Get YES price by checking balance before/after small buy
        uint256 yesBalanceBefore = token.balanceOf(ARBITRAGEUR);
        policast.buyShares(marketId, 0, testAmount, type(uint256).max, 0);
        uint256 yesCost = yesBalanceBefore - token.balanceOf(ARBITRAGEUR);
        
        // Reset by selling back
        uint256 yesShares = policast.getMarketOptionUserShares(marketId, 0, ARBITRAGEUR);
        policast.sellShares(marketId, 0, yesShares, 0, 0);
        
        // Get NO price by checking balance before/after small buy
        uint256 noBalanceBefore = token.balanceOf(ARBITRAGEUR);
        policast.buyShares(marketId, 1, testAmount, type(uint256).max, 0);
        uint256 noCost = noBalanceBefore - token.balanceOf(ARBITRAGEUR);
        
        vm.stopPrank();
        
        uint256 totalCost = yesCost + noCost;
        
        console.log("YES cost for 1 share:", yesCost / 1e18);
        console.log("NO cost for 1 share:", noCost / 1e18);
        console.log("Total cost:", totalCost / 1e18);
        
        // In a fair market, total cost should be > 100 tokens (due to fees)
        // but not excessively higher
        bool validPricing = totalCost >= 100 * 1e18 && totalCost <= 120 * 1e18;
        
        if (validPricing) {
            console.log("PASS: Pricing maintains consistency with fees");
        } else {
            console.log("FAIL: Price consistency violated");
        }
        
        assertTrue(validPricing, "Combined price should be reasonable with fees");
    }
    
    function testLMSRArbitrageResistance() public {
        console.log("=== LMSR ARBITRAGE RESISTANCE TEST ===");
        
        // Test that LMSR prevents guaranteed profit
        // by making buying all options cost more than guaranteed payout
        
        vm.startPrank(ARBITRAGEUR);
        
        // Calculate cost of buying enough shares to guarantee win by simulating purchases
        uint256[] memory costs = new uint256[](2);
        uint256 shareAmount = 1000 * 1e18; // 1000 shares
        
        // Simulate buying YES shares to get cost
        uint256 balanceBefore = token.balanceOf(ARBITRAGEUR);
        policast.buyShares(marketId, 0, shareAmount, type(uint256).max, 0);
        costs[0] = balanceBefore - token.balanceOf(ARBITRAGEUR);
        
        // Reset by selling back
        uint256 yesShares = policast.getMarketOptionUserShares(marketId, 0, ARBITRAGEUR);
        policast.sellShares(marketId, 0, yesShares, 0, 0);
        
        // Simulate buying NO shares to get cost
        balanceBefore = token.balanceOf(ARBITRAGEUR);
        policast.buyShares(marketId, 1, shareAmount, type(uint256).max, 0);
        costs[1] = balanceBefore - token.balanceOf(ARBITRAGEUR);
        
        // Reset by selling back
        uint256 noShares = policast.getMarketOptionUserShares(marketId, 1, ARBITRAGEUR);
        policast.sellShares(marketId, 1, noShares, 0, 0);
        
        uint256 totalCost = costs[0] + costs[1];
        uint256 guaranteedReturn = 1000 * 100; // 1000 shares * 100 tokens per share
        
        vm.stopPrank();
        
        console.log("Total cost for both options (tokens):", totalCost / 1e18);
        console.log("Guaranteed return (tokens):", guaranteedReturn);
        
        bool arbitragePrevented = totalCost > (guaranteedReturn * 1e18);
        
        if (arbitragePrevented) {
            console.log("PASS: LMSR prevents guaranteed arbitrage");
        } else {
            console.log("FAIL: LMSR allows guaranteed profit");
        }
        
        assertTrue(arbitragePrevented, "LMSR should prevent guaranteed arbitrage");
        
        console.log("=== ARBITRAGE PREVENTION VALIDATION COMPLETE ===");
        console.log("All arbitrage prevention mechanisms working correctly");
    }
}