// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {PolicastViews} from "src/PolicastViews.sol";
import {MockERC20} from "test/MockERC20.sol";

contract FullMarketCycleNewTest is Test {
    MockERC20 internal token;
    PolicastMarketV3 internal market;
    PolicastViews internal views;

    address internal OWNER = address(0xA11CE);
    address internal ALICE = address(0xB0B);
    address internal BOB = address(0xC0C);

    uint256 internal constant ONE = 1e18;
    uint256 internal constant PAYOUT_PER_SHARE = 100 * 1e18;

    function setUp() public {
        // MockERC20 constructor mints total supply to msg.sender (this test contract)
        token = new MockERC20(3_000_000e18);

        // Deploy market contract as OWNER so it becomes Ownable owner
        vm.startPrank(OWNER);
        market = new PolicastMarketV3(address(token));
        views = new PolicastViews(address(market));
        vm.stopPrank();

        // Distribute tokens to participants
        token.transfer(OWNER, 1_000_000e18);
        token.transfer(ALICE, 1_000_000e18);
        token.transfer(BOB, 1_000_000e18);
    }

    function testFullCycle_TwoOptions() public {
        // OWNER approves initial liquidity and creates market
        vm.startPrank(OWNER);
        token.approve(address(market), type(uint256).max);

        string[] memory names = new string[](2);
        names[0] = "YES";
        names[1] = "NO";
        string[] memory desc = new string[](2);
        desc[0] = "";
        desc[1] = "";

        uint256 initialLiquidity = 10_000e18; // >= 1000e18
        uint256 marketId = market.createMarket(
            "Will it happen?",
            "",
            names,
            desc,
            2 days,
            PolicastMarketV3.MarketCategory(0),
            PolicastMarketV3.MarketType(0),
            initialLiquidity,
            false
        );

        // Validate market
        market.validateMarket(marketId);
        vm.stopPrank();

        // Check initial prices: 0.5 prob -> 50 tokens per share
        (,,,, uint256 currentPrice0,) = market.getMarketOption(marketId, 0);
        (,,,, uint256 currentPrice1,) = market.getMarketOption(marketId, 1);
        assertEq(currentPrice0, 5e17, "init prob 0");
        assertEq(currentPrice1, 5e17, "init prob 1");
        uint256 tokenPrice0 = views.getOptionPriceInTokens(marketId, 0);
        uint256 tokenPrice1 = views.getOptionPriceInTokens(marketId, 1);
        assertEq(tokenPrice0, 50e18, "init tokens 0");
        assertEq(tokenPrice1, 50e18, "init tokens 1");

        // ALICE buys YES shares
        vm.startPrank(ALICE);
        token.approve(address(market), type(uint256).max);
        uint256 qtyAlice = 100e18; // 100 shares
        uint256 maxPps = type(uint256).max; // generous slippage
        market.buyShares(marketId, 0, qtyAlice, maxPps, 0);
        vm.stopPrank();

        // BOB buys NO shares
        vm.startPrank(BOB);
        token.approve(address(market), type(uint256).max);
        uint256 qtyBob = 50e18; // 50 shares
        market.buyShares(marketId, 1, qtyBob, maxPps, 0);
        vm.stopPrank();

        // Move time forward to end
        vm.warp(block.timestamp + 3 days);

        // Resolve YES wins
        vm.prank(OWNER);
        market.resolveMarket(marketId, 0);

        // ALICE claims winnings
        uint256 balBefore = token.balanceOf(ALICE);
        vm.prank(ALICE);
        market.claimWinnings(marketId);
        uint256 balAfter = token.balanceOf(ALICE);
        // Winnings = shares * payout
        assertEq(balAfter - balBefore, (qtyAlice * PAYOUT_PER_SHARE) / ONE, "alice winnings");

        // BOB has 0 winnings on NO
        vm.expectRevert();
        vm.prank(BOB);
        market.claimWinnings(marketId);

        // Fees are unlocked at resolution; detailed accounting checked in other tests
    }
}
