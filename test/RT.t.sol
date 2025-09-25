// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "forge-std/Test.sol";
import "../src/RT.sol";
import "./MockERC20.sol";

contract RTTest is Test {
    LMSRPredictionMarket public market;
    MockERC20 public token;

    address public owner = address(0x1);
    address public trader1 = address(0x2);
    address public trader2 = address(0x3);

    uint256 public constant INITIAL_BALANCE = 1000 * 1e18;
    uint256 public marketId;

    function setUp() public {
        // Create MockERC20 with initial supply to this contract
        token = new MockERC20(INITIAL_BALANCE * 10);

        vm.startPrank(owner);
        market = new LMSRPredictionMarket(address(token));

        // Create a market with b = 50 tokens
        marketId = market.createMarket(
            "Will Bitcoin reach $100k by 2025?",
            "Yes",
            "No",
            7 days,
            50 * 1e18 // b parameter = 50 tokens
        );
        vm.stopPrank();

        // Transfer tokens to traders (since we minted to this contract)
        token.transfer(trader1, INITIAL_BALANCE);
        token.transfer(trader2, INITIAL_BALANCE);

        // Approve spending
        vm.prank(trader1);
        token.approve(address(market), INITIAL_BALANCE);

        vm.prank(trader2);
        token.approve(address(market), INITIAL_BALANCE);
    }

    function testSimpleBuyAndSellWithPrices() public {
        console.log("=== RT.sol LMSR Market Test ===");
        console.log("");

        // Initial state
        (,,,,, uint256 totalA, uint256 totalB,, uint256 propA, uint256 propB) = market.getMarketInfo(marketId);
        console.log("Initial State:");
        console.log("Total Option A shares:", totalA);
        console.log("Total Option B shares:", totalB);
        console.log("Option A probability:", propA * 100 / 1e18, "%");
        console.log("Option B probability:", propB * 100 / 1e18, "%");
        console.log("");

        // Check price for buying 10 shares of Option A
        uint256 priceFor10A = market.getPriceForShares(marketId, true, 10 * 1e18);
        console.log("Price to buy 10 Option A shares:", priceFor10A / 1e18, "tokens");

        // Check price for buying 10 shares of Option B
        uint256 priceFor10B = market.getPriceForShares(marketId, false, 10 * 1e18);
        console.log("Price to buy 10 Option B shares:", priceFor10B / 1e18, "tokens");
        console.log("");

        // Trader1 buys 10 shares of Option A
        console.log("Trader1 buys 10 Option A shares...");
        vm.prank(trader1);
        market.buyShares(marketId, true, 10 * 1e18);

        // Check new state
        (,,,,, totalA, totalB,, propA, propB) = market.getMarketInfo(marketId);
        console.log("After Trader1 buy:");
        console.log("Total Option A shares:", totalA / 1e18);
        console.log("Total Option B shares:", totalB / 1e18);
        console.log("Option A probability:", propA * 100 / 1e18, "%");
        console.log("Option B probability:", propB * 100 / 1e18, "%");
        console.log("");

        // Check new prices
        priceFor10A = market.getPriceForShares(marketId, true, 10 * 1e18);
        priceFor10B = market.getPriceForShares(marketId, false, 10 * 1e18);
        console.log("Price to buy another 10 Option A shares:", priceFor10A / 1e18, "tokens");
        console.log("Price to buy 10 Option B shares:", priceFor10B / 1e18, "tokens");
        console.log("");

        // Trader2 buys 20 shares of Option B
        console.log("Trader2 buys 20 Option B shares...");
        vm.prank(trader2);
        market.buyShares(marketId, false, 20 * 1e18);

        // Check final state
        (,,,,, totalA, totalB,, propA, propB) = market.getMarketInfo(marketId);
        console.log("After Trader2 buy:");
        console.log("Total Option A shares:", totalA / 1e18);
        console.log("Total Option B shares:", totalB / 1e18);
        console.log("Option A probability:", propA * 100 / 1e18, "%");
        console.log("Option B probability:", propB * 100 / 1e18, "%");
        console.log("");

        // Final prices
        priceFor10A = market.getPriceForShares(marketId, true, 10 * 1e18);
        priceFor10B = market.getPriceForShares(marketId, false, 10 * 1e18);
        console.log("Final price for 10 Option A shares:", priceFor10A / 1e18, "tokens");
        console.log("Final price for 10 Option B shares:", priceFor10B / 1e18, "tokens");
        console.log("");

        // Check trader balances
        (uint256 trader1A, uint256 trader1B) = market.getSharesBalance(marketId, trader1);
        (uint256 trader2A, uint256 trader2B) = market.getSharesBalance(marketId, trader2);
        console.log("Trader1 shares - A:", trader1A / 1e18, ", B:", trader1B / 1e18);
        console.log("Trader2 shares - A:", trader2A / 1e18, ", B:", trader2B / 1e18);
    }

    function testPriceMovementWithDifferentSizes() public {
        console.log("=== Price Movement Test ===");
        console.log("b parameter:", 50, "tokens");
        console.log("");

        // Test different purchase sizes
        console.log("Price for different share amounts:");
        console.log("1 share A:", market.getPriceForShares(marketId, true, 1 * 1e18) / 1e18, "tokens");
        console.log("5 shares A:", market.getPriceForShares(marketId, true, 5 * 1e18) / 1e18, "tokens");
        console.log("10 shares A:", market.getPriceForShares(marketId, true, 10 * 1e18) / 1e18, "tokens");
        console.log("25 shares A:", market.getPriceForShares(marketId, true, 25 * 1e18) / 1e18, "tokens");
        console.log("50 shares A:", market.getPriceForShares(marketId, true, 50 * 1e18) / 1e18, "tokens");
        console.log("");

        // Buy progressively larger amounts
        console.log("Buying 5 shares A...");
        vm.prank(trader1);
        market.buyShares(marketId, true, 5 * 1e18);

        (,,,,, uint256 totalA, uint256 totalB,, uint256 propA, uint256 propB) = market.getMarketInfo(marketId);
        console.log("After 5 shares: A prob =", propA * 100 / 1e18);
        console.log("%, B prob =", propB * 100 / 1e18, "%");
        console.log("Next 5 shares A would cost:", market.getPriceForShares(marketId, true, 5 * 1e18) / 1e18, "tokens");
        console.log("");

        console.log("Buying another 10 shares A...");
        vm.prank(trader1);
        market.buyShares(marketId, true, 10 * 1e18);

        (,,,,, totalA, totalB,, propA, propB) = market.getMarketInfo(marketId);
        console.log("After 15 total shares: A prob =", propA * 100 / 1e18);
        console.log("%, B prob =", propB * 100 / 1e18, "%");
        console.log(
            "Next 10 shares A would cost:", market.getPriceForShares(marketId, true, 10 * 1e18) / 1e18, "tokens"
        );
        console.log("");

        // Show the exponential nature
        console.log("Large purchase prices:");
        console.log("25 more shares A:", market.getPriceForShares(marketId, true, 25 * 1e18) / 1e18, "tokens");
        console.log("50 more shares A:", market.getPriceForShares(marketId, true, 50 * 1e18) / 1e18, "tokens");
    }
}
