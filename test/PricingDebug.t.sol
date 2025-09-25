// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
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
            1_000_000e18, // initial liquidity - INCREASED from 10k to 1M for deeper market
            false // is free
        );

        market.validateMarket(marketId);
        vm.stopPrank();
    }

    function testPricingScaling() public view {
        uint256 marketId = 0;

        // Check initial prices for all options
        for (uint256 i = 0; i < 3; i++) {
            (,,,, uint256 currentPriceData,) = market.getMarketOption(marketId, i);
            uint256 tokenPrice = views.getOptionPriceInTokens(marketId, i);
            uint256 calculatedTokenPrice = views.calculateCurrentPriceInTokens(marketId, i);

            console.log("=== Option", i, "===");
            console.log("Current price (probability):", currentPriceData);
            console.log("Token price from getOptionPriceInTokens:", tokenPrice);
            console.log("Token price from calculateCurrentPriceInTokens:", calculatedTokenPrice);
            console.log("");

            // For 3 options, initial probability should be 1/3 ≈ 0.333 in 1e18 scale
            assertApproxEqRel(
                currentPriceData, 333333333333333333, 1e15, "Initial probability should be ~0.333 (33.33%)"
            );

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

        (,,,, uint256 optionCurrentPrice,) = market.getMarketOption(marketId, optionId);
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
    }

    function testActualBuyAndSellCost() public {
        uint256 marketId = 0;
        uint256 optionId = 0;
        uint256 quantity = 1000e18; // 1000 shares
        address buyer = address(0xB0B);

        // Fund the buyer and approve the market contract
        token.transfer(buyer, 500_000e18); // increase funding to avoid balance reverts
        vm.startPrank(buyer);
        token.approve(address(market), type(uint256).max);

    // 1. Get the expected cost from the view function (ΔC + fee)
    (uint256 rawCost, uint256 fee, uint256 totalCost, uint256 avgPricePerShare) = views.quoteBuy(marketId, optionId, quantity);

    // Basic sanity checks on raw cost & fee
    assertGt(rawCost, 0, "Raw cost zero");
    uint256 expectedFee = (rawCost * 200) / 10000; // 2%
    uint256 feeDiff = fee > expectedFee ? fee - expectedFee : expectedFee - fee;
    assertLt(feeDiff, 2, "Fee mismatch");

    // Compute linear (no-slippage) reference cost
    (,,,, uint256 optionCurrentPrice,) = market.getMarketOption(marketId, optionId);
    uint256 probTimesQty = (optionCurrentPrice * quantity) / 1e18; // 1e18-scaled shares * price
    uint256 linearRaw = (probTimesQty * 100e18) / 1e18; // tokens without fee
    uint256 linearFee = (linearRaw * 200) / 10000;
    uint256 linearTotal = linearRaw + linearFee;

    // Slippage ratio (scaled 1e18). Expect small positive slippage.
    uint256 slippageNumerator = totalCost > linearTotal ? totalCost - linearTotal : 0;
    uint256 slippageRatio = (slippageNumerator * 1e18) / linearTotal; // 1e18 scaled
    // Require <5% slippage for this trade size given large B
    assertLt(slippageRatio, 5e16, "Buy slippage >5% unexpected");
    // Prevent runaway cost
    assertLt(totalCost, linearTotal * 2, "Quoted buy cost >2x linear");

        console.log("=== Actual Buy Execution Test ===");
        console.log("Buyer starting balance:", token.balanceOf(buyer));
        console.log("Quoted Total Cost for 1000 shares:", totalCost);

        // 2. Record balance before the trade
        uint256 balanceBeforeBuy = token.balanceOf(buyer);

        // 3. Execute the buy order
        // We use the quoted totalCost as the slippage limit for a precise check.
        market.buyShares(marketId, optionId, quantity, avgPricePerShare, totalCost);

        // 4. Record balance after the trade
        uint256 balanceAfterBuy = token.balanceOf(buyer);

        // 5. Verify the cost
        uint256 actualCost = balanceBeforeBuy - balanceAfterBuy;

        console.log("Buyer balance after buy:", balanceAfterBuy);
        console.log("Actual cost deducted:", actualCost);

    // The actual cost deducted must exactly match the total cost from the quote
    assertEq(actualCost, totalCost, "Actual cost deducted does not match quoted total cost");

    // Realized slippage should match quoted slippage within tolerance
    uint256 realizedSlippage = totalCost > linearTotal ? ((totalCost - linearTotal) * 1e18) / linearTotal : 0;
    uint256 slipDiff = realizedSlippage > slippageRatio ? realizedSlippage - slippageRatio : slippageRatio - realizedSlippage;
    assertLt(slipDiff, 5e12, "Realized vs quoted slippage drift");

    console.log("SUCCESS: Actual buy cost matches quote. Slippage (bps):", slippageRatio / 1e14);

        console.log("\n=== Actual Sell Execution Test ===");

        // Now, sell the shares back
        // 1. Get the expected return from the view function
        (,, uint256 totalReturn, uint256 avgSellPricePerShare) = views.quoteSell(marketId, optionId, quantity);

        console.log("Quoted Total Return for 1000 shares:", totalReturn);

        // 2. Record balance before the sell
        uint256 balanceBeforeSell = token.balanceOf(buyer);

        // 3. Execute the sell order
        market.sellShares(marketId, optionId, quantity, avgSellPricePerShare, totalReturn);

        // 4. Record balance after the sell
        uint256 balanceAfterSell = token.balanceOf(buyer);
        vm.stopPrank();

        // 5. Verify the return
        uint256 actualReturn = balanceAfterSell - balanceBeforeSell;

        console.log("Buyer balance after sell:", balanceAfterSell);
        console.log("Actual return received:", actualReturn);

        // The actual return received must exactly match the total return from the quote
        assertEq(actualReturn, totalReturn, "Actual return received does not match quoted total return");

        // Round-trip sanity: net loss mostly fees (2% each side) + small slippage
        uint256 netLoss = actualCost > actualReturn ? actualCost - actualReturn : 0;
        // Expect between ~1x and ~3x single-side fee (raw linear fee) for this size
        uint256 linearFeeMin = linearFee / 2; // allow a bit lower if pricing moved favorably
        uint256 linearFeeMax = linearFee * 3; // cap excessive loss
        assertGt(netLoss, linearFeeMin, "Net loss too small - fee not applied?");
        assertLt(netLoss, linearFeeMax, "Net loss too large - excessive slippage?");

        console.log("SUCCESS: Round-trip consistent. Net loss tokens:", netLoss);
    }
}
