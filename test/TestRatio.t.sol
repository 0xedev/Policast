// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {PolicastMarketV3} from "../src/Policast.sol";
import {PolicastViews} from "../src/PolicastViews.sol";
import "./MockERC20.sol";

contract TestRatioTest is Test {
    PolicastMarketV3 public market;
    PolicastViews public views;
    MockERC20 public token;
    address public admin = address(0x123);
    address public user1 = address(0x456);

    function setUp() public {
        token = new MockERC20(10_000_000 ether);
        vm.prank(admin);
        market = new PolicastMarketV3(address(token));
        views = new PolicastViews(address(market));
        
        // Transfer tokens to users (constructor mints to test contract)
        token.transfer(admin, 2_000_000 ether);
        token.transfer(user1, 1_000_000 ether);
        
        // Setup approvals
        vm.prank(admin);
        token.approve(address(market), type(uint256).max);
        vm.prank(user1);
        token.approve(address(market), type(uint256).max);
        
        // Setup admin role (admin is already owner from constructor)
        vm.startPrank(admin);
        market.grantQuestionCreatorRole(admin);
        market.grantQuestionResolveRole(admin);
        market.grantMarketValidatorRole(admin);
        vm.stopPrank();
    }

    function testTokenCostsWith100xRatio() public {
        // Create a simple 2-option market
        vm.startPrank(admin);
        string[] memory names = new string[](2);
        names[0] = "A";
        names[1] = "B";
        string[] memory descs = new string[](2);  
        descs[0] = "Option A";
        descs[1] = "Option B";
        
        uint256 marketId = market.createMarket(
            "Test Question",
            "Test Description",
            names,
            descs,
            block.timestamp + 1 hours,
            PolicastMarketV3.MarketCategory.SPORTS,
            PolicastMarketV3.MarketType.PAID,
            50_000 ether, // initial liquidity (matching other tests)
            false
        );
        market.validateMarket(marketId);
        vm.stopPrank();

        // Check initial prices (should be 50% each = 0.5 * 1e18)
        uint256 priceA = views.calculateCurrentPrice(marketId, 0);
        uint256 priceB = views.calculateCurrentPrice(marketId, 1);
        console.log("Initial Price A:", priceA);
        console.log("Initial Price B:", priceB);

        // User buys 1 share (1e18 in contract terms) of Option A
        vm.startPrank(user1);
        
        uint256 balanceBefore = token.balanceOf(user1);
        console.log("User balance before:", balanceBefore / 1e18);
        
        market.buyShares(marketId, 0, 1e18, type(uint256).max, 0);
        
        uint256 balanceAfter = token.balanceOf(user1);
        console.log("User balance after:", balanceAfter / 1e18);
        
        uint256 tokensCost = balanceBefore - balanceAfter;
        console.log("Tokens cost for 1 share:", tokensCost / 1e18);
        
        // With 1:100 ratio and 50% initial price, buying 1 share should cost ~50 tokens
        // (50% probability * 100x ratio = 50 tokens per share)
        assertTrue(tokensCost >= 40 * 1e18 && tokensCost <= 60 * 1e18, "Cost should be around 50 tokens");
        
        vm.stopPrank();
    }
}