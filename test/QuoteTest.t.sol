// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {PolicastViews} from "src/PolicastViews.sol";
import {MockERC20} from "test/MockERC20.sol";

contract QuoteTest is Test {
    MockERC20 internal token;
    PolicastMarketV3 internal market;
    PolicastViews internal views;

    address internal OWNER = address(0xA11CE);
    address internal USER = address(0xFACE);

    function setUp() public {
        token = new MockERC20(10_000_000e18);

        vm.startPrank(OWNER);
        market = new PolicastMarketV3(address(token));
        views = new PolicastViews(address(market));
        vm.stopPrank();

        // Fund user and owner
        token.transfer(USER, 5_000_000e18);
        token.transfer(OWNER, 5_000_000e18);

        vm.startPrank(OWNER);
        token.approve(address(market), type(uint256).max);

        // Create a 3-option market
        string[] memory options = new string[](3);
        options[0] = "Option A";
        options[1] = "Option B";
        options[2] = "Option C";

        string[] memory descriptions = new string[](3);
        descriptions[0] = "";
        descriptions[1] = "";
        descriptions[2] = "";

        uint256 marketId = market.createMarket(
            "Quote validation",
            "test",
            options,
            descriptions,
            block.timestamp + 7 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            10000e18, // initial liquidity
            false // is free
        );

        market.validateMarket(marketId);
        vm.stopPrank();

        vm.startPrank(USER);
        token.approve(address(market), type(uint256).max);
        vm.stopPrank();
    }

    function testQuoteMatchesBuyExecution() public {
        uint256 marketId = 0;
        uint256 optionId = 0;
        uint256 qty = 10e18; // 10 shares

        // Get on-chain quote
        (uint256 rawCost,, uint256 totalCost, uint256 avgPricePerShare) = views.quoteBuy(marketId, optionId, qty);
        assertGt(rawCost, 0, "rawCost should be > 0");
        assertGt(totalCost, rawCost, "totalCost should include fee");
        assertGt(avgPricePerShare, 0, "avg price should be > 0");

        // Execute buy and compare token movements
        vm.startPrank(USER);
        uint256 balBeforeUser = token.balanceOf(USER);
        uint256 balBeforeMarket = token.balanceOf(address(market));

        // Use tight slippage bounds based on quote
        market.buyShares(marketId, optionId, qty, avgPricePerShare, totalCost);

        uint256 balAfterUser = token.balanceOf(USER);
        uint256 balAfterMarket = token.balanceOf(address(market));
        vm.stopPrank();

        // User spent exactly totalCost
        assertEq(balBeforeUser - balAfterUser, totalCost, "user spend should equal quoted totalCost");
        // Market received exactly totalCost
        assertEq(balAfterMarket - balBeforeMarket, totalCost, "market receive should equal quoted totalCost");
    }

    function testQuoteMatchesSellExecution() public {
        uint256 marketId = 0;
        uint256 optionId = 0;

        // First, buy some shares to be able to sell later
        vm.startPrank(USER);
        // Buy 20 shares
        (,, uint256 totalCostBuy, uint256 avgPrice) = views.quoteBuy(marketId, optionId, 20e18);
        market.buyShares(marketId, optionId, 20e18, avgPrice, totalCostBuy);
        vm.stopPrank();

        // Now, sell 7 shares
        uint256 sellQty = 7e18;
        (uint256 rawRefund,, uint256 netRefund, uint256 avgPricePerShare) = views.quoteSell(marketId, optionId, sellQty);
        assertGt(rawRefund, 0, "rawRefund should be > 0");
        assertGt(netRefund, 0, "netRefund should be > 0");
        assertGt(avgPricePerShare, 0, "avg price should be > 0");

        vm.startPrank(USER);
        uint256 balBeforeUser = token.balanceOf(USER);
        uint256 balBeforeMarket = token.balanceOf(address(market));

        // Use tight slippage bounds based on quote (min average and min total proceeds)
        market.sellShares(marketId, optionId, sellQty, avgPricePerShare, netRefund);

        uint256 balAfterUser = token.balanceOf(USER);
        uint256 balAfterMarket = token.balanceOf(address(market));
        vm.stopPrank();

        // User received exactly netRefund
        assertEq(balAfterUser - balBeforeUser, netRefund, "user proceeds should equal quoted netRefund");
        // Market paid exactly netRefund
        assertEq(balBeforeMarket - balAfterMarket, netRefund, "market outflow should equal quoted netRefund");
    }
}
