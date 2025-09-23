// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {PolicastViews} from "src/PolicastViews.sol";
import {MockERC20} from "test/MockERC20.sol";

contract PriceBuyTest is Test {
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

        token.transfer(USER, 5_000_000e18);
        token.transfer(OWNER, 5_000_000e18); // Transfer liquidity to the market creator
        
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
            "Test price monotonicity",
            "test",
            options,
            descriptions,
            block.timestamp + 172800, // 2 days
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

    function testPriceShouldIncreaseOnConsecutiveBuys() public {
        uint256 marketId = 0;
        uint256 optionId = 0;

        (, , , , uint256 initialPrice, ) = views.getMarketOption(marketId, optionId);
        console.log("Initial price:", initialPrice);

        vm.startPrank(USER);

        // 1. Buy 50 shares
        market.buyShares(marketId, optionId, 50e18, type(uint256).max, 0);
        (, , , , uint256 priceAfter50, ) = views.getMarketOption(marketId, optionId);
        console.log("Price after 50 shares:", priceAfter50);
        assertGt(priceAfter50, initialPrice, "Price should increase after buying 50 shares");

        // 2. Buy 1 share
        market.buyShares(marketId, optionId, 1e18, type(uint256).max, 0);
        (, , , , uint256 priceAfter51, ) = views.getMarketOption(marketId, optionId);
        console.log("Price after 51 shares:", priceAfter51);
        assertGt(priceAfter51, priceAfter50, "Price should increase after buying 1 more share");

        // 3. Buy 5 shares
        market.buyShares(marketId, optionId, 5e18, type(uint256).max, 0);
        (, , , , uint256 priceAfter56, ) = views.getMarketOption(marketId, optionId);
        console.log("Price after 56 shares:", priceAfter56);
        assertGt(priceAfter56, priceAfter51, "Price should increase after buying 5 more shares");

        vm.stopPrank();
    }
}
