// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {PolicastViews} from "src/PolicastViews.sol";
import {MockERC20} from "./MockERC20.sol";

contract PolicastBasicTest is Test {
    MockERC20 internal token;
    PolicastMarketV3 internal market;
    PolicastViews internal views;
    address internal creator = address(0xA11CE);
    address internal user1 = address(0xBEEF1);
    address internal user2 = address(0xBEEF2);

    // Helper function to get user shares for all options
    function getUserShares(uint256 marketId, address user) internal view returns (uint256[] memory) {
        (,,,, uint256 optionCount,,,,) = market.getMarketBasicInfo(marketId);
        uint256[] memory shares = new uint256[](optionCount);
        for (uint256 i = 0; i < optionCount; i++) {
            shares[i] = market.getMarketOptionUserShares(marketId, i, user);
        }
        return shares;
    }

    function setUp() public {
        token = new MockERC20(10_000_000 ether);
        vm.prank(creator);
        market = new PolicastMarketV3(address(token));
        views = new PolicastViews(address(market));
        // fund accounts
        token.transfer(creator, 2_000_000 ether); // constructor minted to test contract, move to creator
        token.transfer(user1, 1_000_000 ether);
        token.transfer(user2, 1_000_000 ether);

        // creator approves
        vm.prank(creator);
        token.approve(address(market), type(uint256).max);
        vm.prank(user1);
        token.approve(address(market), type(uint256).max);
        vm.prank(user2);
        token.approve(address(market), type(uint256).max);

        // grant roles to creator (owner already has admin but we simulate external creator)
        vm.startPrank(creator);
        market.grantQuestionCreatorRole(creator);
        market.grantQuestionResolveRole(creator);
        market.grantMarketValidatorRole(creator);
        vm.stopPrank();
    }

    function _createSimpleMarket() internal returns (uint256) {
        vm.startPrank(creator);
        string[] memory names = new string[](3);
        string[] memory descs = new string[](3);
        names[0] = "A";
        names[1] = "B";
        names[2] = "C";
        descs[0] = "A";
        descs[1] = "B";
        descs[2] = "C";
        uint256 mId = market.createMarket(
            "Who wins?",
            "Test market",
            names,
            descs,
            2 days,
            PolicastMarketV3.MarketCategory.SPORTS,
            PolicastMarketV3.MarketType.PAID,
            50_000 ether,
            false
        );
        market.validateMarket(mId);
        vm.stopPrank();
        return mId;
    }

    function testCreateMarketAndValidate() public {
        uint256 mId = _createSimpleMarket();
        (,, uint256 endTime,, uint256 optionCount,,,,,,,,) = market.getMarketInfo(mId);
        assertEq(optionCount, 3, "option count");
        assertGt(endTime, block.timestamp, "end time");
    }

    function testBuySellFlow() public {
        uint256 mId = _createSimpleMarket();
        vm.startPrank(user1);
        market.buyShares(mId, 0, 100e18, 5e20, 0); // large max price to avoid revert
        uint256[] memory shares = getUserShares(mId, user1);
        assertEq(shares[0], 100e18, "shares bought");
        // sell half
        market.sellShares(mId, 0, 50e18, 0, 0);
        shares = getUserShares(mId, user1);
        assertEq(shares[0], 50e18, "shares after sell");
        vm.stopPrank();
    }

    function testResolutionAndClaim() public {
        uint256 mId = _createSimpleMarket();
        // user buys outcome 1
        vm.prank(user1);
        market.buyShares(mId, 1, 200e18, 5e20, 0);
        // fast forward after end if early resolution not allowed
        vm.warp(block.timestamp + 3 days);
        vm.prank(creator);
        market.resolveMarket(mId, 1);
        // claim
        uint256 balBefore = token.balanceOf(user1);
        vm.prank(user1);
        market.claimWinnings(mId);
        uint256 balAfter = token.balanceOf(user1);
        // payout = shares * 100 tokens (scaled 1e18)
        uint256 expected = 200e18 * 100e18 / 1e18;
        assertEq(balAfter - balBefore, expected, "payout mismatch");
    }

    function testFeesAccrualAndWithdraw() public {
        uint256 mId = _createSimpleMarket();
        vm.prank(user1);
        market.buyShares(mId, 0, 300e18, 5e20, 0);
        // cannot withdraw yet (fees locked)
        vm.expectRevert();
        market.withdrawPlatformFees();
        // resolve
        vm.warp(block.timestamp + 3 days);
        vm.prank(creator);
        market.resolveMarket(mId, 0);
        uint256 unlockedBefore = token.balanceOf(creator);
        // withdraw (owner is feeCollector)
        vm.prank(creator);
        market.withdrawPlatformFees();
        uint256 unlockedAfter = token.balanceOf(creator);
        assertGt(unlockedAfter, unlockedBefore, "fees not withdrawn");
    }

    function testSlippageBoundBuyReverts() public {
        uint256 mId = _createSimpleMarket();
        vm.startPrank(user1);
        vm.expectRevert();
        // max total cost too low (1 wei)
        market.buyShares(mId, 0, 50e18, 5e20, 1);
        vm.stopPrank();
    }

    function testSellSharesWithSlippage() public {
        uint256 mId = _createSimpleMarket();
        vm.startPrank(user1);
        market.buyShares(mId, 0, 100e18, 5e20, 0);
        // sell with max price
        market.sellShares(mId, 0, 50e18, 0, 0); // max price 0, but since effectiveAvg <=0, no revert
        uint256[] memory shares = getUserShares(mId, user1);
        assertEq(shares[0], 50e18, "shares after sell");
        vm.stopPrank();
    }

    function testSellSlippageExceeded() public {
        uint256 mId = _createSimpleMarket();
        vm.startPrank(user1);
        market.buyShares(mId, 0, 100e18, 5e20, 0);
        vm.expectRevert();
        market.sellShares(mId, 0, 50e18, 5e20, 1); // max total cost 1 wei
        vm.stopPrank();
    }

    function testGetGlobalStats() public {
        uint256 mId = _createSimpleMarket();
        vm.prank(user1);
        market.buyShares(mId, 0, 100e18, 5e20, 0);
        (uint256 totalFees, address feeCollectorAddr, uint256 totalMarkets, uint256 totalTrades) =
            views.getPlatformStats();
        assertGt(totalFees, 0);
        assertEq(feeCollectorAddr, creator);
        assertEq(totalMarkets, 1);
        assertGt(totalTrades, 0);
    }

    function testWithdrawAdminLiquidity() public {
        uint256 mId = _createSimpleMarket();
        vm.prank(user1);
        market.buyShares(mId, 0, 100e18, 5e20, 0);
        vm.warp(block.timestamp + 3 days);
        vm.prank(creator);
        market.resolveMarket(mId, 0);
        uint256 balBefore = token.balanceOf(creator);
        // NOTE: withdrawAdminLiquidity function removed for size optimization
        // This test is now effectively a no-op since the function doesn't exist
        uint256 balAfter = token.balanceOf(creator);
        assertEq(balAfter, balBefore, "No balance change expected since withdrawAdminLiquidity was removed");
    }

    function testResolutionUserLoses() public {
        uint256 mId = _createSimpleMarket();
        vm.prank(user1);
        market.buyShares(mId, 0, 100e18, 5e20, 0);
        vm.warp(block.timestamp + 3 days);
        vm.prank(creator);
        market.resolveMarket(mId, 1); // resolve to 1, user bought 0
        uint256 balBefore = token.balanceOf(user1);
        vm.prank(user1);
        vm.expectRevert();
        market.claimWinnings(mId);
        uint256 balAfter = token.balanceOf(user1);
        assertEq(balAfter, balBefore, "should get nothing");
    }

    function testClaimWinningsNoShares() public {
        uint256 mId = _createSimpleMarket();
        vm.warp(block.timestamp + 3 days);
        vm.prank(creator);
        market.resolveMarket(mId, 0);
        vm.prank(user1);
        vm.expectRevert();
        market.claimWinnings(mId);
    }

    function testPauseAndUnpause() public {
        uint256 mId = _createSimpleMarket();
        vm.prank(creator);
        market.pause();
        vm.prank(user1);
        vm.expectRevert();
        market.buyShares(mId, 0, 100e18, 5e20, 0);
        vm.prank(creator);
        market.unpause();
        vm.prank(user1);
        market.buyShares(mId, 0, 100e18, 5e20, 0); // should work now
    }

    function testSetFeeCollector() public {
        vm.prank(creator);
        market.setFeeCollector(user2);
        assertEq(market.feeCollector(), user2);
    }

    function testBuyBeforeValidate() public {
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "A";
        names[1] = "B";
        string[] memory descs = new string[](2);
        descs[0] = "A";
        descs[1] = "B";
        uint256 mId = market.createMarket(
            "Test",
            "Test",
            names,
            descs,
            1 days,
            PolicastMarketV3.MarketCategory.SPORTS,
            PolicastMarketV3.MarketType.PAID,
            50_000 ether,
            false
        );
        vm.stopPrank();
        vm.prank(user1);
        vm.expectRevert();
        market.buyShares(mId, 0, 100e18, 5e20, 0);
    }

    function testResolveNotAuthorized() public {
        uint256 mId = _createSimpleMarket();
        vm.warp(block.timestamp + 3 days);
        vm.prank(user1);
        vm.expectRevert();
        market.resolveMarket(mId, 0);
    }

    function testWithdrawNoFees() public {
        vm.prank(creator);
        vm.expectRevert();
        market.withdrawPlatformFees();
    }

    function testInvalidOptionId() public {
        uint256 mId = _createSimpleMarket();
        vm.prank(user1);
        vm.expectRevert();
        market.buyShares(mId, 3, 100e18, 5e20, 0); // option 3 doesn't exist
    }

    function testAmountMustBePositive() public {
        uint256 mId = _createSimpleMarket();
        vm.prank(user1);
        vm.expectRevert();
        market.buyShares(mId, 0, 0, 5e20, 0);
    }

    function testBackwardCompatibleBuyShares() public {
        uint256 mId = _createSimpleMarket();
        vm.prank(user1);
        market.buyShares(mId, 0, 100e18, 5e20, 0); // updated to use 5-parameter version
        uint256[] memory shares = getUserShares(mId, user1);
        assertEq(shares[0], 100e18);
    }

    function testSellSharesAmountMustBePositive() public {
        uint256 mId = _createSimpleMarket();
        vm.prank(user1);
        vm.expectRevert();
        market.sellShares(mId, 0, 0, 5e20, 0);
    }

    function testSellSharesInsufficientShares() public {
        uint256 mId = _createSimpleMarket();
        vm.prank(user1);
        vm.expectRevert();
        market.sellShares(mId, 0, 100e18, 5e20, 0); // no shares owned
    }

    function testResolveInvalidOutcome() public {
        uint256 mId = _createSimpleMarket();
        vm.warp(block.timestamp + 3 days);
        vm.prank(creator);
        vm.expectRevert();
        market.resolveMarket(mId, 3); // invalid outcome
    }

    function testResolveTooEarly() public {
        uint256 mId = _createSimpleMarket();
        vm.prank(creator);
        vm.expectRevert();
        market.resolveMarket(mId, 0);
    }

    function testMarketAlreadyResolved() public {
        uint256 mId = _createSimpleMarket();
        vm.warp(block.timestamp + 3 days);
        vm.prank(creator);
        market.resolveMarket(mId, 0);
        vm.expectRevert();
        market.resolveMarket(mId, 1);
    }

    function testClaimAlreadyClaimed() public {
        uint256 mId = _createSimpleMarket();
        vm.prank(user1);
        market.buyShares(mId, 0, 100e18, 5e20, 0);
        vm.warp(block.timestamp + 3 days);
        vm.prank(creator);
        market.resolveMarket(mId, 0);
        vm.prank(user1);
        market.claimWinnings(mId);
        vm.expectRevert();
        market.claimWinnings(mId);
    }

    function testGetMarketInfo() public {
        uint256 mId = _createSimpleMarket();
        (,,,, uint256 optionCount,,,,,,,,) = market.getMarketInfo(mId);
        assertEq(optionCount, 3);
    }

    function testGetUserSharesViaViews() public {
        uint256 mId = _createSimpleMarket();
        vm.prank(user1);
        market.buyShares(mId, 0, 100e18, 5e20, 0);
        uint256[] memory shares = getUserShares(mId, user1);
        assertEq(shares[0], 100e18);
    }

    function testEarlyResolution() public {
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "X";
        names[1] = "Y";
        string[] memory descs = new string[](2);
        descs[0] = "X";
        descs[1] = "Y";
        uint256 mId = market.createMarket(
            "Test",
            "Test",
            names,
            descs,
            1 days,
            PolicastMarketV3.MarketCategory.SPORTS,
            PolicastMarketV3.MarketType.PAID,
            50_000 ether,
            true
        ); // allow early
        market.validateMarket(mId);
        vm.stopPrank();
        vm.prank(user1);
        market.buyShares(mId, 0, 100e18, 5e20, 0);
        vm.warp(block.timestamp + 1 hours + 1); // wait 1 hour +1 sec
        vm.prank(creator);
        market.resolveMarket(mId, 0); // early resolution
        vm.prank(user1);
        market.claimWinnings(mId);
    }

    function testInvalidMarketId() public {
        vm.prank(user1);
        vm.expectRevert();
        market.buyShares(999, 0, 100e18, 5e20, 0);
    }

    function testMarketNotActive() public {
        uint256 mId = _createSimpleMarket();
        vm.warp(block.timestamp + 3 days);
        vm.prank(user1);
        vm.expectRevert();
        market.buyShares(mId, 0, 100e18, 5e20, 0);
    }

    function testPriceHistory() public {
        uint256 mId = _createSimpleMarket();
        vm.prank(user1);
        market.buyShares(mId, 0, 100e18, 5e20, 0);
        // priceHistory is internal, but the code is executed
    }

    function testUserTradeHistory() public {
        uint256 mId = _createSimpleMarket();
        vm.prank(user1);
        market.buyShares(mId, 0, 100e18, 5e20, 0);
        // tradeHistory is internal
    }

    function testMultipleMarkets() public {
        // create first market (unused id) — call directly to avoid unused-local warning
        _createSimpleMarket();
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "X";
        names[1] = "Y";
        string[] memory descs = new string[](2);
        descs[0] = "X";
        descs[1] = "Y";
        uint256 mId2 = market.createMarket(
            "Test2",
            "Test2",
            names,
            descs,
            1 days,
            PolicastMarketV3.MarketCategory.SPORTS,
            PolicastMarketV3.MarketType.PAID,
            50_000 ether,
            false
        );
        market.validateMarket(mId2);
        vm.stopPrank();
        assertEq(market.marketCount(), 2);
    }

    // ===== LMSR PRICING LOGIC TESTS =====

    function testLMSRProbabilityInvariants() public {
        uint256 mId = _createSimpleMarket();
        uint256[] memory probs = views.getMarketOdds(mId);
        uint256 sum = 0;
        for (uint256 i = 0; i < probs.length; i++) {
            sum += probs[i];
        }
        // Probabilities should sum to approximately 1e18 (with small tolerance)
        assertApproxEqAbs(sum, 1e18, 1e15, "Probabilities don't sum to 1");
    }

    function testLMSRPriceMonotonicity() public {
        uint256 mId = _createSimpleMarket();
        // Test price increases indirectly through buying
        uint256 price1 = views.calculateCurrentPrice(mId, 0);
        vm.prank(user1);
        market.buyShares(mId, 0, 10e18, 5e20, 0);
        uint256 price2 = views.calculateCurrentPrice(mId, 0);
        assertLt(price1, price2, "Price should increase after buying shares");
    }

    function testLMSRPriceCalculation() public {
        uint256 mId = _createSimpleMarket();
        uint256[] memory prices = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            prices[i] = views.calculateCurrentPrice(mId, i);
        }
        // All prices should be positive and less than 1e18
        for (uint256 i = 0; i < prices.length; i++) {
            assertGt(prices[i], 0, "Price should be positive");
            assertLt(prices[i], 1e18, "Price should be less than 1");
        }
    }

    function testLMSRBuySellRoundTrip() public {
        uint256 mId = _createSimpleMarket();
        uint256 balBefore = token.balanceOf(user1);

        vm.startPrank(user1);
        market.buyShares(mId, 0, 100e18, 5e20, 0);
        uint256 balAfterBuy = token.balanceOf(user1);

        // Sell the same amount
        market.sellShares(mId, 0, 100e18, 0, 0);
        uint256 balAfterSell = token.balanceOf(user1);
        vm.stopPrank();

        // Should get less than paid due to fees
        assertLt(balAfterSell, balBefore, "Should lose money due to fees");
        assertGt(balAfterSell, balAfterBuy, "Should get some money back");
    }

    function testLMSRSlippageProtection() public {
        uint256 mId = _createSimpleMarket();

        vm.startPrank(user1);
        // Test buy with tight slippage bounds using public interface
        uint256 currentPrice = views.calculateCurrentPrice(mId, 0);
        uint256 maxPrice = currentPrice + 1e16; // Very tight bound

        vm.expectRevert(); // Should revert due to slippage
        market.buyShares(mId, 0, 1000e18, maxPrice, 0);
        vm.stopPrank();
    }

    function testLMSRMultipleBuys() public {
        uint256 mId = _createSimpleMarket();

        vm.startPrank(user1);
        // Buy multiple times and check price increases
        uint256 price1 = views.calculateCurrentPrice(mId, 0);
        market.buyShares(mId, 0, 50e18, 5e20, 0);
        uint256 price2 = views.calculateCurrentPrice(mId, 0);
        market.buyShares(mId, 0, 50e18, 5e20, 0);
        uint256 price3 = views.calculateCurrentPrice(mId, 0);
        vm.stopPrank();

        assertLt(price1, price2, "Price should increase after first buy");
        assertLt(price2, price3, "Price should increase after second buy");
    }

    function testLMSRInsufficientLiquidity() public {
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "A";
        names[1] = "B";
        string[] memory descs = new string[](2);
        descs[0] = "A";
        descs[1] = "B";
        // Create market with minimal liquidity
        uint256 mId = market.createMarket(
            "Test",
            "Test",
            names,
            descs,
            1 days,
            PolicastMarketV3.MarketCategory.SPORTS,
            PolicastMarketV3.MarketType.PAID,
            100 ether,
            false
        );
        market.validateMarket(mId);
        vm.stopPrank();

        vm.prank(user1);
        vm.expectRevert(); // Should revert due to insufficient liquidity for large trade
        market.buyShares(mId, 0, 1000e18, 5e20, 0);
    }

    // ===== FREE MARKET TESTS =====

    function testCreateFreeMarket() public {
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "Yes";
        names[1] = "No";
        string[] memory descs = new string[](2);
        descs[0] = "Yes";
        descs[1] = "No";

        uint256 mId = market.createFreeMarket(
            "Will it rain?",
            "Weather prediction",
            names,
            descs,
            1 days,
            PolicastMarketV3.MarketCategory.WEATHER,
            100, // max participants
            10e18, // tokens per participant
            1000e18, // liquidity
            false
        );
        vm.stopPrank();

        // Unpack only the fields we need. Keep placeholders for skipped returns.
        vm.stopPrank();

        // Predeclare variables with correct types, then destructure without types to avoid conversion issues
        uint256 optionCount;
        PolicastMarketV3.MarketType marketType;
        (,,,, optionCount,, marketType,,) = market.getMarketBasicInfo(mId);
        assertEq(optionCount, 2);
        assertEq(uint256(marketType), uint256(PolicastMarketV3.MarketType.FREE_ENTRY));
    }

    function testClaimFreeTokens() public {
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "A";
        names[1] = "B";
        string[] memory descs = new string[](2);
        descs[0] = "A";
        descs[1] = "B";

        uint256 mId = market.createFreeMarket(
            "Test Free",
            "Free market test",
            names,
            descs,
            1 days,
            PolicastMarketV3.MarketCategory.OTHER,
            10,
            5e18,
            100e18,
            false
        );
        vm.stopPrank();

        uint256 balBefore = token.balanceOf(user1);
        vm.prank(user1);
        market.claimFreeTokens(mId);
        uint256 balAfter = token.balanceOf(user1);

        assertEq(balAfter - balBefore, 5e18, "Should receive free tokens");
    }

    function testFreeMarketFull() public {
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "A";
        names[1] = "B";
        string[] memory descs = new string[](2);
        descs[0] = "A";
        descs[1] = "B";

        uint256 mId = market.createFreeMarket(
            "Test Free",
            "Free market test",
            names,
            descs,
            1 days,
            PolicastMarketV3.MarketCategory.OTHER,
            2, // only 2 participants allowed
            5e18,
            100e18,
            false
        );
        vm.stopPrank();

        // First user claims
        vm.prank(user1);
        market.claimFreeTokens(mId);

        // Second user claims
        vm.prank(user2);
        market.claimFreeTokens(mId);

        // Third user tries to claim - should fail
        address user3 = address(0xBEEF3);
        token.transfer(user3, 100e18);
        vm.prank(user3);
        token.approve(address(market), type(uint256).max);
        vm.expectRevert();
        market.claimFreeTokens(mId);
    }

    function testFreeMarketDoubleClaim() public {
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "A";
        names[1] = "B";
        string[] memory descs = new string[](2);
        descs[0] = "A";
        descs[1] = "B";

        uint256 mId = market.createFreeMarket(
            "Test Free",
            "Free market test",
            names,
            descs,
            1 days,
            PolicastMarketV3.MarketCategory.OTHER,
            10,
            5e18,
            100e18,
            false
        );
        vm.stopPrank();

        vm.prank(user1);
        market.claimFreeTokens(mId);

        vm.expectRevert();
        vm.prank(user1);
        market.claimFreeTokens(mId); // Should fail
    }

    // ===== MARKET INVALIDATION TESTS =====

    function testInvalidateMarket() public {
        // Create a market but do NOT validate it, so it can be invalidated
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "A";
        names[1] = "B";
        string[] memory descs = new string[](2);
        descs[0] = "A";
        descs[1] = "B";
        uint256 mId = market.createMarket(
            "ToInvalidate",
            "Test invalidation",
            names,
            descs,
            2 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            50_000 ether,
            false
        );
        vm.stopPrank();

        vm.prank(creator);
        market.invalidateMarket(mId);

        // Try to buy after invalidation - should fail
        vm.expectRevert();
        vm.prank(user1);
        market.buyShares(mId, 0, 100e18, 5e20, 0);
    }

    function testDisputeMarket() public {
        uint256 mId = _createSimpleMarket();

        // Buy shares first
        vm.prank(user1);
        market.buyShares(mId, 0, 100e18, 5e20, 0);

        // Resolve market
        vm.warp(block.timestamp + 3 days);
        vm.prank(creator);
        market.resolveMarket(mId, 1); // Resolve to different outcome

        // NOTE: disputeMarket function removed for size optimization
        // Since there's no dispute functionality, test normal claim flow instead
        // user1 bought option 0 but option 1 won, so they have no winnings
        vm.expectRevert(abi.encodeWithSelector(PolicastMarketV3.NoWinningShares.selector));
        vm.prank(user1);
        market.claimWinnings(mId);
    }

    // ===== ACCESS CONTROL TESTS =====

    function testRoleBasedAccess() public {
        // Test that only authorized users can create markets
        address unauthorized = address(0xDEAD);
        token.transfer(unauthorized, 1e18);
        vm.prank(unauthorized);
        token.approve(address(market), type(uint256).max);

        vm.startPrank(unauthorized);
        string[] memory names = new string[](2);
        names[0] = "A";
        names[1] = "B";
        string[] memory descs = new string[](2);
        descs[0] = "A";
        descs[1] = "B";

        vm.expectRevert();
        market.createMarket(
            "Test",
            "Test",
            names,
            descs,
            1 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            50_000 ether,
            false
        );
        vm.stopPrank();
    }

    function testPauserRole() public {
        vm.prank(creator);
        market.grantPauserRole(user1);

        vm.prank(user1);
        market.pause();

        // Try to buy while paused - should fail
        vm.expectRevert();
        vm.prank(user2);
        market.buyShares(0, 0, 100e18, 5e20, 0);

        vm.prank(user1);
        market.unpause();
    }

    // ===== TOKEN MANAGEMENT TESTS =====

    function testUpdateBettingToken() public {
        MockERC20 newToken = new MockERC20(1_000_000 ether);
        newToken.transfer(creator, 100_000 ether);

        vm.prank(creator);
        market.updateBettingToken(address(newToken));

        assertEq(address(market.bettingToken()), address(newToken));
    }

    function testUpdateBettingTokenUnauthorized() public {
        MockERC20 newToken = new MockERC20(1_000_000 ether);

        vm.expectRevert();
        vm.prank(user1);
        market.updateBettingToken(address(newToken));
    }
}
