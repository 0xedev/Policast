// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Policast.sol";
import "../src/PolicastViews.sol";
import "./MockERC20.sol";

contract ArbitrageFeeAnalysis is Test {
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
            "Test binary market for fee analysis",
            "Will platform fees prevent arbitrage?",
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

    function testSmallArbitrageWithFees() public {
        console.log("=== SMALL ARBITRAGE ANALYSIS (10 shares) ===");

        uint256 shareAmount = 10 * 1e18; // 10 shares
        uint256 guaranteedPayout = 10 * 100; // 10 shares × 100 tokens per winning share = 1000 tokens

        vm.startPrank(ARBITRAGEUR);
        uint256 initialBalance = token.balanceOf(ARBITRAGEUR);
        console.log("Initial balance:", initialBalance / 1e18, "tokens");

        // Buy YES shares
        uint256 balanceBeforeYes = token.balanceOf(ARBITRAGEUR);
        policast.buyShares(marketId, 0, shareAmount, type(uint256).max, 0);
        uint256 yesCost = balanceBeforeYes - token.balanceOf(ARBITRAGEUR);
        console.log("YES cost (including fees):", yesCost / 1e18, "tokens");

        // Buy NO shares
        uint256 balanceBeforeNo = token.balanceOf(ARBITRAGEUR);
        policast.buyShares(marketId, 1, shareAmount, type(uint256).max, 0);
        uint256 noCost = balanceBeforeNo - token.balanceOf(ARBITRAGEUR);
        console.log("NO cost (including fees):", noCost / 1e18, "tokens");

        uint256 totalCost = yesCost + noCost;
        console.log("Total cost for both options:", totalCost / 1e18, "tokens");
        console.log("Guaranteed payout:", guaranteedPayout, "tokens");

        // Calculate theoretical profit/loss before resolution
        int256 theoreticalResult = int256(guaranteedPayout * 1e18) - int256(totalCost);
        console.log("Theoretical result:");
        if (theoreticalResult > 0) {
            console.log("  PROFIT:", uint256(theoreticalResult) / 1e18, "tokens");
        } else {
            console.log("  LOSS:", uint256(-theoreticalResult) / 1e18, "tokens");
        }

        vm.stopPrank();

        // Resolve market (YES wins)
        vm.warp(block.timestamp + 8 days);
        vm.prank(CREATOR);
        policast.resolveMarket(marketId, 0);

        // Claim winnings
        vm.prank(ARBITRAGEUR);
        uint256 balanceBeforeClaim = token.balanceOf(ARBITRAGEUR);
        policast.claimWinnings(marketId);
        uint256 claimAmount = token.balanceOf(ARBITRAGEUR) - balanceBeforeClaim;

        uint256 finalBalance = token.balanceOf(ARBITRAGEUR);
        int256 actualProfit = int256(finalBalance) - int256(initialBalance);

        console.log("\n=== FINAL RESULTS ===");
        console.log("Claimed winnings:", claimAmount / 1e18, "tokens");
        console.log("Actual net result:");
        if (actualProfit > 0) {
            console.log("  PROFIT:", uint256(actualProfit) / 1e18, "tokens");
            console.log("  RESULT: ARBITRAGE STILL POSSIBLE!");
        } else {
            console.log("  LOSS:", uint256(-actualProfit) / 1e18, "tokens");
            console.log("  RESULT: Arbitrage prevented by fees");
        }

        // Test assertion
        assertTrue(actualProfit <= 0, "Platform fees should prevent guaranteed arbitrage");
    }

    function testMediumArbitrageWithFees() public {
        console.log("\n=== MEDIUM ARBITRAGE ANALYSIS (100 shares) ===");

        uint256 shareAmount = 100 * 1e18; // 100 shares
        uint256 guaranteedPayout = 100 * 100; // 100 shares × 100 tokens per winning share = 10,000 tokens

        vm.startPrank(ARBITRAGEUR);
        uint256 initialBalance = token.balanceOf(ARBITRAGEUR);
        console.log("Initial balance:", initialBalance / 1e18, "tokens");

        // Buy YES shares
        uint256 balanceBeforeYes = token.balanceOf(ARBITRAGEUR);
        policast.buyShares(marketId, 0, shareAmount, type(uint256).max, 0);
        uint256 yesCost = balanceBeforeYes - token.balanceOf(ARBITRAGEUR);
        console.log("YES cost (including fees):", yesCost / 1e18, "tokens");

        // Buy NO shares
        uint256 balanceBeforeNo = token.balanceOf(ARBITRAGEUR);
        policast.buyShares(marketId, 1, shareAmount, type(uint256).max, 0);
        uint256 noCost = balanceBeforeNo - token.balanceOf(ARBITRAGEUR);
        console.log("NO cost (including fees):", noCost / 1e18, "tokens");

        uint256 totalCost = yesCost + noCost;
        console.log("Total cost for both options:", totalCost / 1e18, "tokens");
        console.log("Guaranteed payout:", guaranteedPayout, "tokens");

        // Calculate theoretical profit/loss
        int256 theoreticalResult = int256(guaranteedPayout * 1e18) - int256(totalCost);
        console.log("Theoretical result:");
        if (theoreticalResult > 0) {
            console.log("  PROFIT:", uint256(theoreticalResult) / 1e18, "tokens");
        } else {
            console.log("  LOSS:", uint256(-theoreticalResult) / 1e18, "tokens");
        }

        vm.stopPrank();

        // Resolve market (YES wins)
        vm.warp(block.timestamp + 8 days);
        vm.prank(CREATOR);
        policast.resolveMarket(marketId, 0);

        // Claim winnings
        vm.prank(ARBITRAGEUR);
        uint256 balanceBeforeClaim = token.balanceOf(ARBITRAGEUR);
        policast.claimWinnings(marketId);
        uint256 claimAmount = token.balanceOf(ARBITRAGEUR) - balanceBeforeClaim;

        uint256 finalBalance = token.balanceOf(ARBITRAGEUR);
        int256 actualProfit = int256(finalBalance) - int256(initialBalance);

        console.log("\n=== FINAL RESULTS ===");
        console.log("Claimed winnings:", claimAmount / 1e18, "tokens");
        console.log("Actual net result:");
        if (actualProfit > 0) {
            console.log("  PROFIT:", uint256(actualProfit) / 1e18, "tokens");
            console.log("  RESULT: ARBITRAGE STILL POSSIBLE!");
        } else {
            console.log("  LOSS:", uint256(-actualProfit) / 1e18, "tokens");
            console.log("  RESULT: Arbitrage prevented by fees");
        }

        assertTrue(actualProfit <= 0, "Platform fees should prevent guaranteed arbitrage");
    }

    function testThreeWayArbitrageWithFees() public {
        console.log("\n=== THREE-WAY ARBITRAGE ANALYSIS (50 shares each) ===");

        // Create 3-option market
        vm.prank(CREATOR);
        string[] memory options = new string[](3);
        options[0] = "A";
        options[1] = "B";
        options[2] = "C";

        string[] memory symbols = new string[](3);
        symbols[0] = "A";
        symbols[1] = "B";
        symbols[2] = "C";

        uint256 threeWayMarketId = policast.createMarket(
            "Three-way test market",
            "Which option will win?",
            options,
            symbols,
            7 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            150_000 * 1e18,
            false
        );

        vm.prank(CREATOR);
        policast.validateMarket(threeWayMarketId);

        uint256 shareAmount = 50 * 1e18; // 50 shares each
        uint256 guaranteedPayout = 50 * 100; // 50 shares × 100 tokens per winning share = 5,000 tokens

        vm.startPrank(ARBITRAGEUR);
        uint256 initialBalance = token.balanceOf(ARBITRAGEUR);
        console.log("Initial balance:", initialBalance / 1e18, "tokens");

        // Buy A shares
        uint256 balanceBeforeA = token.balanceOf(ARBITRAGEUR);
        policast.buyShares(threeWayMarketId, 0, shareAmount, type(uint256).max, 0);
        uint256 aCost = balanceBeforeA - token.balanceOf(ARBITRAGEUR);
        console.log("A cost (including fees):", aCost / 1e18, "tokens");

        // Buy B shares
        uint256 balanceBeforeB = token.balanceOf(ARBITRAGEUR);
        policast.buyShares(threeWayMarketId, 1, shareAmount, type(uint256).max, 0);
        uint256 bCost = balanceBeforeB - token.balanceOf(ARBITRAGEUR);
        console.log("B cost (including fees):", bCost / 1e18, "tokens");

        // Buy C shares
        uint256 balanceBeforeC = token.balanceOf(ARBITRAGEUR);
        policast.buyShares(threeWayMarketId, 2, shareAmount, type(uint256).max, 0);
        uint256 cCost = balanceBeforeC - token.balanceOf(ARBITRAGEUR);
        console.log("C cost (including fees):", cCost / 1e18, "tokens");

        uint256 totalCost = aCost + bCost + cCost;
        console.log("Total cost for all three options:", totalCost / 1e18, "tokens");
        console.log("Guaranteed payout:", guaranteedPayout, "tokens");

        // Calculate theoretical profit/loss
        int256 theoreticalResult = int256(guaranteedPayout * 1e18) - int256(totalCost);
        console.log("Theoretical result:");
        if (theoreticalResult > 0) {
            console.log("  PROFIT:", uint256(theoreticalResult) / 1e18, "tokens");
        } else {
            console.log("  LOSS:", uint256(-theoreticalResult) / 1e18, "tokens");
        }

        vm.stopPrank();

        // Resolve market (A wins)
        vm.warp(block.timestamp + 8 days);
        vm.prank(CREATOR);
        policast.resolveMarket(threeWayMarketId, 0);

        // Claim winnings
        vm.prank(ARBITRAGEUR);
        uint256 balanceBeforeClaim = token.balanceOf(ARBITRAGEUR);
        policast.claimWinnings(threeWayMarketId);
        uint256 claimAmount = token.balanceOf(ARBITRAGEUR) - balanceBeforeClaim;

        uint256 finalBalance = token.balanceOf(ARBITRAGEUR);
        int256 actualProfit = int256(finalBalance) - int256(initialBalance);

        console.log("\n=== FINAL RESULTS ===");
        console.log("Claimed winnings:", claimAmount / 1e18, "tokens");
        console.log("Actual net result:");
        if (actualProfit > 0) {
            console.log("  PROFIT:", uint256(actualProfit) / 1e18, "tokens");
            console.log("  RESULT: ARBITRAGE STILL POSSIBLE!");
        } else {
            console.log("  LOSS:", uint256(-actualProfit) / 1e18, "tokens");
            console.log("  RESULT: Arbitrage prevented by fees");
        }

        assertTrue(actualProfit <= 0, "Platform fees should prevent guaranteed arbitrage");
    }
}
