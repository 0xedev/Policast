// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Policast.sol";
import "../src/PolicastViews.sol";
import "./MockERC20.sol";

contract LosersPayWinnerTest is Test {
    PolicastMarketV3 public policast;
    PolicastViews public policastViews;
    MockERC20 public token;

    address constant CREATOR = 0x1234567890123456789012345678901234567890;
    address constant WINNER = 0x1111111111111111111111111111111111111111;
    address constant LOSER1 = 0x2222222222222222222222222222222222222222;
    address constant LOSER2 = 0x3333333333333333333333333333333333333333;
    address constant LOSER3 = 0x4444444444444444444444444444444444444444;
    address constant LOSER4 = 0x5555555555555555555555555555555555555555;

    function setUp() public {
        // Deploy token with sufficient supply
        token = new MockERC20(10_000_000 * 1e18);

        // Deploy contracts
        policast = new PolicastMarketV3(address(token));
        policastViews = new PolicastViews(address(policast));

        // Grant necessary roles to creator
        policast.grantQuestionCreatorRole(CREATOR);
        policast.grantMarketValidatorRole(CREATOR);
        policast.grantQuestionResolveRole(CREATOR);

        // Transfer tokens to all users
        token.transfer(WINNER, 100_000 * 1e18);
        token.transfer(LOSER1, 100_000 * 1e18);
        token.transfer(LOSER2, 100_000 * 1e18);
        token.transfer(LOSER3, 100_000 * 1e18);
        token.transfer(LOSER4, 100_000 * 1e18);
        token.transfer(CREATOR, 1_000_000 * 1e18);

        // Approve spending
        vm.prank(WINNER);
        token.approve(address(policast), type(uint256).max);
        vm.prank(LOSER1);
        token.approve(address(policast), type(uint256).max);
        vm.prank(LOSER2);
        token.approve(address(policast), type(uint256).max);
        vm.prank(LOSER3);
        token.approve(address(policast), type(uint256).max);
        vm.prank(LOSER4);
        token.approve(address(policast), type(uint256).max);
        vm.prank(CREATOR);
        token.approve(address(policast), type(uint256).max);
    }

    function testLosersPayWinnerScenario() public {
        console.log("=== 4 LOSERS PAY 1 WINNER SCENARIO ===");

        // Create market with minimal initial liquidity
        vm.prank(CREATOR);
        string[] memory options = new string[](2);
        options[0] = "Winning Option";
        options[1] = "Losing Option";

        string[] memory symbols = new string[](2);
        symbols[0] = "WIN";
        symbols[1] = "LOSE";

        uint256 marketId = policast.createMarket(
            "Will losers fund the winner?",
            "Testing scenario where many losers fund one winner",
            options,
            symbols,
            7 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            50_000 * 1e18, // 50k initial liquidity
            false
        );

        vm.prank(CREATOR);
        policast.validateMarket(marketId);

        uint256 initialBalance = token.balanceOf(address(policast));
        console.log("Initial contract balance:", initialBalance / 1e18, "tokens");

        // Track balances before trading
        uint256 winnerBalanceBefore = token.balanceOf(WINNER);
        uint256 loser1BalanceBefore = token.balanceOf(LOSER1);
        uint256 loser2BalanceBefore = token.balanceOf(LOSER2);
        uint256 loser3BalanceBefore = token.balanceOf(LOSER3);
        uint256 loser4BalanceBefore = token.balanceOf(LOSER4);

        // ONE winner buys winning shares (small amount)
        vm.prank(WINNER);
        policast.buyShares(marketId, 0, 10 * 1e18, type(uint256).max, 0); // 10 WIN shares

        uint256 winnerCost = winnerBalanceBefore - token.balanceOf(WINNER);
        console.log("Winner bought 10 shares for:", winnerCost / 1e18, "tokens");

        // FOUR losers buy losing shares (MASSIVE amounts each)
        vm.prank(LOSER1);
        policast.buyShares(marketId, 1, 200 * 1e18, type(uint256).max, 0); // 200 LOSE shares
        uint256 loser1Cost = loser1BalanceBefore - token.balanceOf(LOSER1);

        vm.prank(LOSER2);
        policast.buyShares(marketId, 1, 180 * 1e18, type(uint256).max, 0); // 180 LOSE shares
        uint256 loser2Cost = loser2BalanceBefore - token.balanceOf(LOSER2);

        vm.prank(LOSER3);
        policast.buyShares(marketId, 1, 220 * 1e18, type(uint256).max, 0); // 220 LOSE shares
        uint256 loser3Cost = loser3BalanceBefore - token.balanceOf(LOSER3);

        vm.prank(LOSER4);
        policast.buyShares(marketId, 1, 150 * 1e18, type(uint256).max, 0); // 150 LOSE shares
        uint256 loser4Cost = loser4BalanceBefore - token.balanceOf(LOSER4);

        uint256 totalLoserInvestment = loser1Cost + loser2Cost + loser3Cost + loser4Cost;

        console.log("Loser1 bought 200 shares for:", loser1Cost / 1e18, "tokens");
        console.log("Loser2 bought 180 shares for:", loser2Cost / 1e18, "tokens");
        console.log("Loser3 bought 220 shares for:", loser3Cost / 1e18, "tokens");
        console.log("Loser4 bought 150 shares for:", loser4Cost / 1e18, "tokens");
        console.log("Total loser investment:", totalLoserInvestment / 1e18, "tokens");

        uint256 balanceAfterTrading = token.balanceOf(address(policast));
        uint256 tradingProfit = balanceAfterTrading - initialBalance;
        console.log("Contract balance after trading:", balanceAfterTrading / 1e18, "tokens");
        console.log("Trading profit from fees:", tradingProfit / 1e18, "tokens");

        // Check shares
        uint256 winnerShares = policast.getMarketOptionUserShares(marketId, 0, WINNER);
        uint256 totalLosingShares = policast.getMarketOptionUserShares(marketId, 1, LOSER1)
            + policast.getMarketOptionUserShares(marketId, 1, LOSER2)
            + policast.getMarketOptionUserShares(marketId, 1, LOSER3)
            + policast.getMarketOptionUserShares(marketId, 1, LOSER4);

        console.log("Winner holds:", winnerShares / 1e18, "winning shares");
        console.log("Losers hold total:", totalLosingShares / 1e18, "losing shares");

        uint256 expectedPayout = (winnerShares / 1e18) * 100;
        console.log("Expected winner payout:", expectedPayout, "tokens");

        // Check math: Did trading bring in enough to cover payout?
        console.log(
            "Will losers fund winner?",
            tradingProfit >= expectedPayout * 1e18 ? "YES - Trading profit covers it!" : "NO - Initial liquidity needed"
        );

        // Resolve to WIN (option 0) - the winner wins!
        vm.warp(block.timestamp + 8 days);
        vm.prank(CREATOR);
        policast.resolveMarket(marketId, 0);

        uint256 balanceAfterResolution = token.balanceOf(address(policast));
        console.log("Contract balance after resolution:", balanceAfterResolution / 1e18, "tokens");

        // Winner claims
        vm.prank(WINNER);
        policast.claimWinnings(marketId);

        uint256 winnerBalanceAfter = token.balanceOf(WINNER);
        uint256 winnerPayout = winnerBalanceAfter - (winnerBalanceBefore - winnerCost);
        console.log("Winner received:", winnerPayout / 1e18, "tokens");

        uint256 finalContractBalance = token.balanceOf(address(policast));
        console.log("Final contract balance:", finalContractBalance / 1e18, "tokens");

        // Analysis
        console.log("\n=== ECONOMIC ANALYSIS ===");
        console.log("Winner invested:", winnerCost / 1e18, "tokens");
        console.log("Winner received:", winnerPayout / 1e18, "tokens");
        console.log("Winner net profit:", (winnerPayout - winnerCost) / 1e18, "tokens");
        console.log("");
        console.log("Losers invested:", totalLoserInvestment / 1e18, "tokens");
        console.log("Losers received: 0 tokens (they lost)");
        console.log("Losers net loss:", totalLoserInvestment / 1e18, "tokens");
        console.log("");
        console.log(
            "Initial liquidity used for payout:",
            (initialBalance + tradingProfit - finalContractBalance) / 1e18,
            "tokens"
        );

        // The key insight: trading profit comes from losers!
        console.log("Trading profit (from losers):", tradingProfit / 1e18, "tokens");
        console.log("Winner payout:", winnerPayout / 1e18, "tokens");

        if (tradingProfit >= winnerPayout) {
            console.log("PROOF: Losers funded the entire winner payout!");
            console.log("Excess from losers after paying winner:", (tradingProfit - winnerPayout) / 1e18, "tokens");
        } else {
            uint256 shortfall = winnerPayout - tradingProfit;
            console.log("Initial liquidity needed:", shortfall / 1e18, "tokens");
        }

        console.log("\nCONCLUSION: Losers' money flows to winners through the market mechanism!");
    }
}
