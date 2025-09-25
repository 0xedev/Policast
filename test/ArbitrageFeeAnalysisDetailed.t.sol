// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Policast.sol";
import "../src/PolicastViews.sol";
import "./MockERC20.sol";

contract ArbitrageFeeAnalysisDetailed is Test {
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

    function testSmallArbitrageDetailedAnalysis() public {
        console.log("=== DETAILED SMALL ARBITRAGE ANALYSIS (10 shares) ===");

        uint256 shareAmount = 10 * 1e18; // 10 shares

        vm.startPrank(ARBITRAGEUR);
        uint256 initialBalance = token.balanceOf(ARBITRAGEUR);
        console.log("Initial balance:", initialBalance / 1e18, "tokens");

        // Check initial shares
        uint256 yesSharesBefore = policast.getMarketOptionUserShares(marketId, 0, ARBITRAGEUR);
        uint256 noSharesBefore = policast.getMarketOptionUserShares(marketId, 1, ARBITRAGEUR);
        console.log("Initial YES shares:", yesSharesBefore / 1e18);
        console.log("Initial NO shares:", noSharesBefore / 1e18);

        // Buy YES shares
        uint256 balanceBeforeYes = token.balanceOf(ARBITRAGEUR);
        policast.buyShares(marketId, 0, shareAmount, type(uint256).max, 0);
        uint256 yesCost = balanceBeforeYes - token.balanceOf(ARBITRAGEUR);

        uint256 yesSharesAfter = policast.getMarketOptionUserShares(marketId, 0, ARBITRAGEUR);
        console.log("After YES purchase:");
        console.log("  Cost:", yesCost / 1e18, "tokens");
        console.log("  YES shares:", yesSharesAfter / 1e18);

        // Buy NO shares
        uint256 balanceBeforeNo = token.balanceOf(ARBITRAGEUR);
        policast.buyShares(marketId, 1, shareAmount, type(uint256).max, 0);
        uint256 noCost = balanceBeforeNo - token.balanceOf(ARBITRAGEUR);

        uint256 noSharesAfter = policast.getMarketOptionUserShares(marketId, 1, ARBITRAGEUR);
        console.log("After NO purchase:");
        console.log("  Cost:", noCost / 1e18, "tokens");
        console.log("  NO shares:", noSharesAfter / 1e18);

        uint256 totalCost = yesCost + noCost;
        console.log("\n=== COST BREAKDOWN ===");
        console.log("Total cost:", totalCost / 1e18, "tokens");
        console.log("Expected guaranteed payout:", shareAmount / 1e18 * 100, "tokens");

        // Calculate theoretical profit before claiming
        uint256 guaranteedPayout = (shareAmount / 1e18) * 100 * 1e18; // Convert to wei
        int256 theoreticalProfit = int256(guaranteedPayout) - int256(totalCost);

        if (theoreticalProfit > 0) {
            console.log("Theoretical PROFIT:", uint256(theoreticalProfit) / 1e18, "tokens");
        } else {
            console.log("Theoretical LOSS:", uint256(-theoreticalProfit) / 1e18, "tokens");
        }

        vm.stopPrank();

        // Resolve market (YES wins)
        vm.warp(block.timestamp + 8 days);
        vm.prank(CREATOR);
        policast.resolveMarket(marketId, 0); // YES wins

        console.log("\n=== AFTER MARKET RESOLUTION (YES WINS) ===");
        console.log("Final YES shares:", policast.getMarketOptionUserShares(marketId, 0, ARBITRAGEUR) / 1e18);
        console.log("Final NO shares:", policast.getMarketOptionUserShares(marketId, 1, ARBITRAGEUR) / 1e18);

        // Try to claim winnings
        vm.prank(ARBITRAGEUR);
        uint256 balanceBeforeClaim = token.balanceOf(ARBITRAGEUR);

    // Ensure msg.sender context is ARBITRAGEUR for the claim call
    vm.prank(ARBITRAGEUR);
    try policast.claimWinnings(marketId) {
            uint256 balanceAfterClaim = token.balanceOf(ARBITRAGEUR);
            uint256 claimAmount = balanceAfterClaim - balanceBeforeClaim;

            console.log("Successfully claimed:", claimAmount / 1e18, "tokens");

            // Final analysis
            uint256 finalBalance = token.balanceOf(ARBITRAGEUR);
            int256 actualProfit = int256(finalBalance) - int256(initialBalance);

            console.log("\n=== FINAL ARBITRAGE RESULT ===");
            if (actualProfit > 0) {
                console.log("NET PROFIT:", uint256(actualProfit) / 1e18, "tokens");
                console.log("RESULT: ARBITRAGE STILL POSSIBLE!");
            } else {
                console.log("NET LOSS:", uint256(-actualProfit) / 1e18, "tokens");
                console.log("RESULT: Arbitrage prevented by fees");
            }
        } catch Error(string memory reason) {
            console.log("Failed to claim winnings:", reason);
        }
    }

    function testFeeRateCalculations() public view {
        console.log("=== PLATFORM FEE ANALYSIS ===");

        uint256 platformFeeRate = policast.platformFeeRate();
        console.log("Platform fee rate (basis points):", platformFeeRate);
        console.log("Platform fee percentage:", platformFeeRate * 100 / 10000, "%");

        // Calculate theoretical fees for different amounts
        uint256[] memory testAmounts = new uint256[](4);
        testAmounts[0] = 1000 * 1e18; // 1000 tokens
        testAmounts[1] = 5000 * 1e18; // 5000 tokens
        testAmounts[2] = 10000 * 1e18; // 10000 tokens
        testAmounts[3] = 50000 * 1e18; // 50000 tokens

        for (uint256 i = 0; i < testAmounts.length; i++) {
            uint256 fee = (testAmounts[i] * platformFeeRate) / 10000;
            console.log("Amount:", testAmounts[i] / 1e18, "tokens");
            console.log("Fee:", fee / 1e18, "tokens");
        }
    }
}
