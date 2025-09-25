// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Policast.sol";
import "../src/PolicastViews.sol";
import "./MockERC20.sol";

contract CheckRemainingLiquidityTest is Test {
    PolicastMarketV3 public policast;
    PolicastViews public policastViews;
    MockERC20 public token;

    address constant CREATOR = 0x1234567890123456789012345678901234567890;
    address constant USER1 = 0x1111111111111111111111111111111111111111;
    address constant USER2 = 0x2222222222222222222222222222222222222222;
    address constant USER3 = 0x3333333333333333333333333333333333333333;
    address constant USER4 = 0x4444444444444444444444444444444444444444;
    address constant USER5 = 0x5555555555555555555555555555555555555555;
    address constant USER6 = 0x6666666666666666666666666666666666666666;
    address constant USER7 = 0x7777777777777777777777777777777777777777;
    address constant USER8 = 0x8888888888888888888888888888888888888888;
    address constant USER9 = 0x9999999999999999999999999999999999999999;
    address constant USER10 = 0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa;

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

        // Transfer tokens to all users (using the deployer's initial supply)
        token.transfer(USER1, 100_000 * 1e18);
        token.transfer(USER2, 100_000 * 1e18);
        token.transfer(USER3, 100_000 * 1e18);
        token.transfer(USER4, 100_000 * 1e18);
        token.transfer(USER5, 100_000 * 1e18);
        token.transfer(USER6, 100_000 * 1e18);
        token.transfer(USER7, 100_000 * 1e18);
        token.transfer(USER8, 100_000 * 1e18);
        token.transfer(USER9, 100_000 * 1e18);
        token.transfer(USER10, 100_000 * 1e18);
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
        vm.prank(USER6);
        token.approve(address(policast), type(uint256).max);
        vm.prank(USER7);
        token.approve(address(policast), type(uint256).max);
        vm.prank(USER8);
        token.approve(address(policast), type(uint256).max);
        vm.prank(USER9);
        token.approve(address(policast), type(uint256).max);
        vm.prank(USER10);
        token.approve(address(policast), type(uint256).max);
        vm.prank(CREATOR);
        token.approve(address(policast), type(uint256).max);
    }

    function testCheckRemainingLiquidityAfterClaims() public {
        // Create market with 200k initial liquidity
        vm.prank(CREATOR);
        string[] memory options = new string[](3);
        options[0] = "Bitcoin (BTC)";
        options[1] = "Ethereum (ETH)";
        options[2] = "Solana (SOL)";

        string[] memory symbols = new string[](3);
        symbols[0] = "BTC";
        symbols[1] = "ETH";
        symbols[2] = "SOL";

        uint256 marketId = policast.createMarket(
            "Which crypto will perform best this quarter?",
            "A comprehensive prediction market testing the 1:100 ratio",
            options,
            symbols,
            7 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            200_000 * 1e18, // 200k initial liquidity
            false // not early resolution
        );

        // Validate the market
        vm.prank(CREATOR);
        policast.validateMarket(marketId);

        token.balanceOf(address(policast));

        // Simulate the exact same trades as in the full lifecycle test
        // These trades result in 16 total ETH shares being held by winners

        // Phase 1
        vm.prank(USER1);
        policast.buyShares(marketId, 0, 5 * 1e18, type(uint256).max, 0); // 5 BTC
        vm.prank(USER2);
        policast.buyShares(marketId, 1, 3 * 1e18, type(uint256).max, 0); // 3 ETH
        vm.prank(USER3);
        policast.buyShares(marketId, 2, 4 * 1e18, type(uint256).max, 0); // 4 SOL
        vm.prank(USER4);
        policast.buyShares(marketId, 0, 2 * 1e18, type(uint256).max, 0); // 2 BTC
        vm.prank(USER5);
        policast.buyShares(marketId, 1, 6 * 1e18, type(uint256).max, 0); // 6 ETH

        // Phase 2
        vm.prank(USER1);
        policast.sellShares(marketId, 0, 2 * 1e18, 0, 0); // Sell 2 BTC (now has 3)
        vm.prank(USER2);
        policast.buyShares(marketId, 1, 2 * 1e18, type(uint256).max, 0); // +2 ETH (now has 5)
        vm.prank(USER6);
        policast.buyShares(marketId, 2, 3 * 1e18, type(uint256).max, 0); // 3 SOL
        vm.prank(USER3);
        policast.sellShares(marketId, 2, 2 * 1e18, 0, 0); // Sell 2 SOL (now has 2)

        // Phase 3
        vm.prank(USER7);
        policast.buyShares(marketId, 0, 1 * 1e18, type(uint256).max, 0); // 1 BTC
        vm.prank(USER8);
        policast.buyShares(marketId, 1, 2 * 1e18, type(uint256).max, 0); // 2 ETH
        vm.prank(USER9);
        policast.buyShares(marketId, 2, 1 * 1e18, type(uint256).max, 0); // 1 SOL
        vm.prank(USER10);
        policast.buyShares(marketId, 1, 4 * 1e18, type(uint256).max, 0); // 4 ETH
        vm.prank(USER5);
        policast.sellShares(marketId, 1, 1 * 1e18, 0, 0); // Sell 1 ETH (now has 5)
        vm.prank(USER4);
        policast.buyShares(marketId, 0, 1 * 1e18, type(uint256).max, 0); // +1 BTC (now has 3)

        uint256 balanceAfterTrading = token.balanceOf(address(policast));

        // Resolve to ETH
        vm.warp(block.timestamp + 8 days);
        vm.prank(CREATOR);
        policast.resolveMarket(marketId, 1);

        uint256 balanceAfterResolution = token.balanceOf(address(policast));

        // Count total ETH shares (winners)
        uint256 totalETHShares = 0;
        totalETHShares += policast.getMarketOptionUserShares(marketId, 1, USER2); // 5
        totalETHShares += policast.getMarketOptionUserShares(marketId, 1, USER5); // 5
        totalETHShares += policast.getMarketOptionUserShares(marketId, 1, USER8); // 2
        totalETHShares += policast.getMarketOptionUserShares(marketId, 1, USER10); // 4
        // Total should be 16 ETH shares

        // All winners claim
        vm.prank(USER2);
        policast.claimWinnings(marketId);
        vm.prank(USER5);
        policast.claimWinnings(marketId);
        vm.prank(USER8);
        policast.claimWinnings(marketId);
        vm.prank(USER10);
        policast.claimWinnings(marketId);

        uint256 finalBalance = token.balanceOf(address(policast));
        uint256 totalPayout = (totalETHShares / 1e18) * 100; // 100 tokens per share

        // Results
        console.log("=== REMAINING LIQUIDITY ANALYSIS ===");
        console.log("Initial liquidity: 200,000 tokens");
        console.log("Balance after trading:", balanceAfterTrading / 1e18);
        console.log("Balance after resolution:", balanceAfterResolution / 1e18);
        console.log("Total ETH shares:", totalETHShares / 1e18);
        console.log("Total payout:", totalPayout);
        console.log("Final remaining balance:", finalBalance / 1e18);
        console.log("Remaining percentage:", (finalBalance * 100) / (200_000 * 1e18));

        // The remaining should be initial + fees - payouts
        assertTrue(finalBalance > 0, "Contract should have remaining funds");
    }
}
