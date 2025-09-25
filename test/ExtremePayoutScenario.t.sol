// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Policast.sol";
import "../src/PolicastViews.sol";
import "./MockERC20.sol";

contract ExtremePayoutScenarioTest is Test {
    PolicastMarketV3 public policast;
    PolicastViews public policastViews;
    MockERC20 public token;

    address constant CREATOR = 0x1234567890123456789012345678901234567890;
    address constant USER1 = 0x1111111111111111111111111111111111111111;
    address constant USER2 = 0x2222222222222222222222222222222222222222;
    address constant USER3 = 0x3333333333333333333333333333333333333333;
    address constant USER4 = 0x4444444444444444444444444444444444444444;
    address constant USER5 = 0x5555555555555555555555555555555555555555;

    function setUp() public {
        // Deploy token with sufficient supply for everyone
        token = new MockERC20(10_000_000 * 1e18); // 10M tokens

        // Deploy contracts with proper constructor arguments
        policast = new PolicastMarketV3(address(token));
        policastViews = new PolicastViews(address(policast));

        // Grant necessary roles to creator
        policast.grantQuestionCreatorRole(CREATOR);
        policast.grantMarketValidatorRole(CREATOR);
        policast.grantQuestionResolveRole(CREATOR);

        // Transfer tokens to all users
        token.transfer(USER1, 100_000 * 1e18);
        token.transfer(USER2, 100_000 * 1e18);
        token.transfer(USER3, 100_000 * 1e18);
        token.transfer(USER4, 100_000 * 1e18);
        token.transfer(USER5, 100_000 * 1e18);
        token.transfer(CREATOR, 1_000_000 * 1e18);

        // Approve spending for all users
        vm.prank(USER1);
        token.approve(address(policast), type(uint256).max);
        vm.prank(USER2);
        token.approve(address(policast), type(uint256).max);
        vm.prank(USER3);
        token.approve(address(policast), type(uint256).max);
        vm.prank(USER4);
        token.approve(address(policast), type(uint256).max);
        vm.prank(USER5);
        token.approve(address(policast), type(uint256).max);
        vm.prank(CREATOR);
        token.approve(address(policast), type(uint256).max);
    }

    function testExtremePayoutScenario() public {
        // Create market with MINIMAL initial liquidity (just enough to pass validation)
        vm.prank(CREATOR);
        string[] memory options = new string[](2);
        options[0] = "Low Volume Option";
        options[1] = "High Volume Option";

        string[] memory symbols = new string[](2);
        symbols[0] = "LOW";
        symbols[1] = "HIGH";

        uint256 marketId = policast.createMarket(
            "Extreme payout scenario test?",
            "Testing when winners vastly outnumber losers",
            options,
            symbols,
            7 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            50_000 * 1e18, // 50k liquidity - enough to start but will be stretched
            false
        );

        vm.prank(CREATOR);
        policast.validateMarket(marketId);

        uint256 initialBalance = token.balanceOf(address(policast));
        console.log("=== EXTREME PAYOUT SCENARIO ===");
        console.log("Initial liquidity:", initialBalance / 1e18);

        // SCENARIO: Very few people buy losing shares (LOW)
        // Many people buy winning shares (HIGH)

        // Only ONE person buys the losing option with small amount
        vm.prank(USER1);
        policast.buyShares(marketId, 0, 1 * 1e18, type(uint256).max, 0); // 1 LOW share

        uint256 balanceAfterLosingBuy = token.balanceOf(address(policast));
        console.log("Balance after 1 losing share bought:", balanceAfterLosingBuy / 1e18);

        // MANY people buy the winning option with large amounts
        vm.prank(USER2);
        policast.buyShares(marketId, 1, 50 * 1e18, type(uint256).max, 0); // 50 HIGH shares

        vm.prank(USER3);
        policast.buyShares(marketId, 1, 30 * 1e18, type(uint256).max, 0); // 30 HIGH shares

        vm.prank(USER4);
        policast.buyShares(marketId, 1, 40 * 1e18, type(uint256).max, 0); // 40 HIGH shares

        vm.prank(USER5);
        policast.buyShares(marketId, 1, 35 * 1e18, type(uint256).max, 0); // 35 HIGH shares

        uint256 balanceAfterAllTrading = token.balanceOf(address(policast));
        console.log("Balance after all trading:", balanceAfterAllTrading / 1e18);

        // Count shares before resolution
        uint256 totalHighShares = 0;
        totalHighShares += policast.getMarketOptionUserShares(marketId, 1, USER2); // 50
        totalHighShares += policast.getMarketOptionUserShares(marketId, 1, USER3); // 30
        totalHighShares += policast.getMarketOptionUserShares(marketId, 1, USER4); // 40
        totalHighShares += policast.getMarketOptionUserShares(marketId, 1, USER5); // 35
        // Total: 155 winning shares!

        uint256 totalLowShares = policast.getMarketOptionUserShares(marketId, 0, USER1); // 1

        console.log("Losing shares (LOW):", totalLowShares / 1e18);
        console.log("Winning shares (HIGH):", totalHighShares / 1e18);
        console.log("Required payout:", (totalHighShares / 1e18) * 100, "tokens");

        // Resolve to HIGH (option 1) - the option with MANY holders
        vm.warp(block.timestamp + 8 days);
        vm.prank(CREATOR);
        policast.resolveMarket(marketId, 1);

        uint256 balanceAfterResolution = token.balanceOf(address(policast));
        console.log("Balance after resolution:", balanceAfterResolution / 1e18);

        // Calculate if we have enough to pay all winners
        uint256 requiredPayout = (totalHighShares / 1e18) * 100;
        console.log("Can we pay all winners?", balanceAfterResolution >= (requiredPayout * 1e18) ? "YES" : "NO");

        if (balanceAfterResolution < (requiredPayout * 1e18)) {
            uint256 shortfall = (requiredPayout * 1e18) - balanceAfterResolution;
            console.log("SHORTFALL:", shortfall / 1e18, "tokens");
            console.log(
                "Initial liquidity covers:", (balanceAfterResolution * 100) / (requiredPayout * 1e18), "% of payouts"
            );
        }

        // Try to claim winnings - this should work if we have enough balance
        vm.prank(USER2);
        if (balanceAfterResolution >= 5000 * 1e18) {
            // USER2 needs 50 * 100 = 5000 tokens
            policast.claimWinnings(marketId);
            console.log("USER2 successfully claimed 5000 tokens");
        } else {
            console.log("USER2 cannot claim - insufficient contract balance");
        }

        uint256 finalBalance = token.balanceOf(address(policast));
        console.log("Final balance after first claim:", finalBalance / 1e18);

        console.log("\n=== SCENARIO ANALYSIS ===");
        console.log("This shows when initial liquidity must cover payouts:");
        console.log("- Few losers: minimal funds from losing bets");
        console.log("- Many winners: large total payout required");
        console.log("- Result: Initial liquidity bears the burden");
    }

    function testBalancedScenario() public {
        // Create the same market setup
        vm.prank(CREATOR);
        string[] memory options = new string[](2);
        options[0] = "Balanced Low";
        options[1] = "Balanced High";

        string[] memory symbols = new string[](2);
        symbols[0] = "BLOW";
        symbols[1] = "BHIGH";

        uint256 marketId = policast.createMarket(
            "Balanced scenario test?",
            "Testing balanced win/loss scenario",
            options,
            symbols,
            7 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            50_000 * 1e18, // Same 50k liquidity
            false
        );

        vm.prank(CREATOR);
        policast.validateMarket(marketId);

        console.log("\n=== BALANCED SCENARIO COMPARISON ===");
        uint256 initialBalance = token.balanceOf(address(policast));
        console.log("Initial liquidity:", initialBalance / 1e18);

        // BALANCED: Equal amounts on both sides
        vm.prank(USER1);
        policast.buyShares(marketId, 0, 25 * 1e18, type(uint256).max, 0); // 25 LOW shares

        vm.prank(USER2);
        policast.buyShares(marketId, 0, 30 * 1e18, type(uint256).max, 0); // 30 LOW shares

        vm.prank(USER3);
        policast.buyShares(marketId, 1, 25 * 1e18, type(uint256).max, 0); // 25 HIGH shares

        vm.prank(USER4);
        policast.buyShares(marketId, 1, 30 * 1e18, type(uint256).max, 0); // 30 HIGH shares

        uint256 balanceAfterTrading = token.balanceOf(address(policast));
        console.log("Balance after balanced trading:", balanceAfterTrading / 1e18);

        // Count shares
        uint256 totalHighShares = policast.getMarketOptionUserShares(marketId, 1, USER3)
            + policast.getMarketOptionUserShares(marketId, 1, USER4); // 55 total
        uint256 totalLowShares = policast.getMarketOptionUserShares(marketId, 0, USER1)
            + policast.getMarketOptionUserShares(marketId, 0, USER2); // 55 total

        console.log("Losing shares:", totalLowShares / 1e18);
        console.log("Winning shares:", totalHighShares / 1e18);
        console.log("Required payout:", (totalHighShares / 1e18) * 100);

        // Resolve to HIGH
        vm.warp(block.timestamp + 8 days);
        vm.prank(CREATOR);
        policast.resolveMarket(marketId, 1);

        uint256 finalBalance = token.balanceOf(address(policast));
        console.log("Final balance:", finalBalance / 1e18);
        console.log("Balanced markets are more self-sustaining!");
    }
}
