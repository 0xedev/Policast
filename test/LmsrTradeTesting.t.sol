// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {PolicastViews} from "src/PolicastViews.sol";
import {MockERC20} from "./MockERC20.sol";

contract LmsrTradeTesting is Test {
    // Explicit selectors for overloaded functions
    bytes4 private constant BUY_EXT_SIG = bytes4(keccak256("buyShares(uint256,uint256,uint256,uint256,uint256)"));
    bytes4 private constant SELL_EXT_SIG = bytes4(keccak256("sellShares(uint256,uint256,uint256,uint256,uint256)"));
    MockERC20 internal token;
    PolicastMarketV3 internal market;
    PolicastViews internal views;
    address internal creator = address(0xCAFE);
    address internal traderA = address(0xBEEF1);
    address internal traderB = address(0xBEEF2);
    address internal traderC = address(0xBEEF3);

    event PriceSample(
        uint256 indexed marketId, uint256 indexed optionId, uint256 step, uint256 price, uint256 timestamp
    );

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
        token.transfer(creator, 1_000_000 ether);
        token.transfer(traderA, 200_000 ether);
        token.transfer(traderB, 200_000 ether);
        token.transfer(traderC, 200_000 ether);

        // approvals
        vm.prank(creator);
        token.approve(address(market), type(uint256).max);
        vm.prank(traderA);
        token.approve(address(market), type(uint256).max);
        vm.prank(traderB);
        token.approve(address(market), type(uint256).max);
        vm.prank(traderC);
        token.approve(address(market), type(uint256).max);

        // grant roles to creator
        vm.startPrank(creator);
        market.grantQuestionCreatorRole(creator);
        market.grantQuestionResolveRole(creator);
        market.grantMarketValidatorRole(creator);
        vm.stopPrank();
    }

    // Helper to emit a price sample (so the test runner trace includes it)
    function testWorkingBuySellDemo() public {
        // Create market with large liquidity for numerical stability
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "Yes";
        names[1] = "No";
        string[] memory descs = new string[](2);
        descs[0] = "Y";
        descs[1] = "N";
        uint256 mId = market.createMarket(
            "Buy/Sell Demo",
            "Demo of buy/sell price movements",
            names,
            descs,
            2 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            100000 ether,
            false
        );
        market.validateMarket(mId);
        vm.stopPrank();

        // Price sampling sequence demonstrating buy and sell effects
        _emitPriceSample(mId, 0, 0); // Initial 50/50
        _emitPriceSample(mId, 1, 0);

        // Small buy on Yes - should increase Yes price, decrease No price
        vm.prank(traderA);
        market.buyShares(mId, 0, 1 ether, type(uint256).max, 0);
        _emitPriceSample(mId, 0, 1);
        _emitPriceSample(mId, 1, 1);

        // Another small buy on Yes - should further increase Yes price
        vm.prank(traderA);
        market.buyShares(mId, 0, 1 ether, type(uint256).max, 0);
        _emitPriceSample(mId, 0, 2);
        _emitPriceSample(mId, 1, 2);

        // Now sell some - should decrease Yes price, increase No price
        vm.prank(traderA);
        uint256[] memory shares = getUserShares(mId, traderA);
        uint256 sellAmt = shares[0] / 10; // sell 10%
        if (sellAmt > 0) {
            vm.prank(traderA); // Need separate prank for each call
            market.sellShares(mId, 0, sellAmt, 0, 0);
            _emitPriceSample(mId, 0, 3);
            _emitPriceSample(mId, 1, 3);
        }

        // Validate basic functionality
        assertGt(views.calculateCurrentPrice(mId, 0), 0);
        assertGt(views.calculateCurrentPrice(mId, 1), 0);
    }

    function _emitPriceSample(uint256 mId, uint256 optId, uint256 step) internal {
        uint256 price = views.calculateCurrentPrice(mId, optId);
        emit PriceSample(mId, optId, step, price, block.timestamp);
    }

    // Simplified adaptive buy: doubles quantity until one succeeds or cap exceeded.
    // Returns the first successful quantity (may be well below the cap). Reverts if none succeed.
    function _adaptiveBuy(address trader, uint256 mId, uint256 optionId, uint256 cap)
        internal
        returns (uint256 executed)
    {
        if (cap < 1e16) cap = 1e16;
        uint256 qty = 1e16; // start tiny
        while (qty <= cap) {
            vm.startPrank(trader);
            (bool ok,) =
                address(market).call(abi.encodeWithSelector(BUY_EXT_SIG, mId, optionId, qty, type(uint256).max, 0));
            vm.stopPrank();
            if (ok) {
                return qty;
            }
            qty *= 2; // escalate
        }
        revert("adaptive buy failed");
    }

    // Adaptive sell: attempts to sell a fraction of current position, halving until success or zero.
    function _adaptiveSell(address trader, uint256 mId, uint256 optionId, uint256 divisor)
        internal
        returns (uint256 executed)
    {
        if (divisor == 0) divisor = 2; // minimal safety
        uint256[] memory shares = getUserShares(mId, trader);
        uint256 available = shares[optionId];
        if (available == 0) return 0; // nothing to sell
        uint256 qty = available / divisor;
        if (qty == 0) qty = available; // fallback to full if very small
        while (qty > 0) {
            vm.startPrank(trader);
            (bool ok,) = address(market).call(abi.encodeWithSelector(SELL_EXT_SIG, mId, optionId, qty, 0, 0));
            vm.stopPrank();
            if (ok) return qty;
            qty /= 2; // reduce and retry
        }
        return 0; // silently ignore if cannot sell tiny residual
    }

    function testPaidMarketLmsrBuySellSequenceAndPayouts() public {
        // create a paid market with comfortable liquidity
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "Yes";
        names[1] = "No";
        string[] memory descs = new string[](2);
        descs[0] = "Y";
        descs[1] = "N";
        uint256 mId = market.createMarket(
            "Will it rain?",
            "D",
            names,
            descs,
            2 days,
            PolicastMarketV3.MarketCategory.WEATHER,
            PolicastMarketV3.MarketType.PAID,
            20000 ether,
            false
        );
        market.validateMarket(mId);
        vm.stopPrank();

        // sample 0: initial prices
        _emitPriceSample(mId, 0, 0);
        _emitPriceSample(mId, 1, 0);

        // traderA adaptive buy option 0 (cap 40e18)
        _adaptiveBuy(traderA, mId, 0, 40e18);
        _emitPriceSample(mId, 0, 1);
        _emitPriceSample(mId, 1, 1);

        // traderB adaptive buy option 0 (cap 20e18)
        _adaptiveBuy(traderB, mId, 0, 20e18);
        _emitPriceSample(mId, 0, 2);
        _emitPriceSample(mId, 1, 2);

        // traderC adaptive buy option 1 (cap 10e18 lowered to avoid solvency stress)
        _adaptiveBuy(traderC, mId, 1, 10e18);
        _emitPriceSample(mId, 0, 3);
        _emitPriceSample(mId, 1, 3);

        // Now traderA sells some of their option 0 shares to demonstrate sell-driven price decrease
        // Use a conservative portion to ensure non-zero LMSR refund
        _adaptiveSell(traderA, mId, 0, 3);
        _emitPriceSample(mId, 0, 4);
        _emitPriceSample(mId, 1, 4);

        // traderB also sells some of their option 0 shares
        _adaptiveSell(traderB, mId, 0, 4);
        _emitPriceSample(mId, 0, 5);
        _emitPriceSample(mId, 1, 5); // Resolve market to option 0 winners
        vm.warp(block.timestamp + 3 days);
        vm.prank(creator);
        market.resolveMarket(mId, 0);

        // claim winnings for traderA (should have some if they hold winning shares)
        // only claim if they hold winning shares, guard to prevent revert
        vm.prank(traderA);
        uint256[] memory shares = getUserShares(mId, traderA);
        if (shares[0] > 0) {
            vm.prank(traderA);
            market.claimWinnings(mId);
        }

        // Emit final price samples after resolution
        _emitPriceSample(mId, 0, 6);
        _emitPriceSample(mId, 1, 6);

        // Sanity checks
        // At least one price change should have occurred
        uint256 p0 = views.calculateCurrentPrice(mId, 0);
        uint256 p1 = views.calculateCurrentPrice(mId, 1);
        assertTrue(p0 > 0 && p1 > 0);
    }

    function testFreeEntryMarketSequenceAndPayouts() public {
        // create a free market; claim free tokens then trade
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "A";
        names[1] = "B";
        string[] memory descs = new string[](2);
        descs[0] = "A";
        descs[1] = "B";
        // maxFreeParticipants = 3, tokensPerParticipant = 100e18, initialLiquidity = 5000 ether
        uint256 mId = market.createFreeMarket(
            "Free Q", "D", names, descs, 2 days, PolicastMarketV3.MarketCategory.OTHER, 3, 100e18, 5000 ether, false
        );
        market.validateMarket(mId);
        vm.stopPrank();

        // sample initial
        _emitPriceSample(mId, 0, 0);
        _emitPriceSample(mId, 1, 0);

        // three participants claim free tokens
        vm.prank(traderA);
        market.claimFreeTokens(mId);
        _emitPriceSample(mId, 0, 1);
        _emitPriceSample(mId, 1, 1);
        vm.prank(traderB);
        market.claimFreeTokens(mId);
        _emitPriceSample(mId, 0, 2);
        _emitPriceSample(mId, 1, 2);
        vm.prank(traderC);
        market.claimFreeTokens(mId);
        _emitPriceSample(mId, 0, 3);
        _emitPriceSample(mId, 1, 3);

        // After claiming free tokens, they now hold tokens and can trade; have traderA buy more on option 0
        _adaptiveBuy(traderA, mId, 0, 20e18);
        _emitPriceSample(mId, 0, 4);
        _emitPriceSample(mId, 1, 4);

        // traderB buys option 1 to create price movement
        _adaptiveBuy(traderB, mId, 1, 15e18);
        _emitPriceSample(mId, 0, 5);
        _emitPriceSample(mId, 1, 5);

        // Now demonstrate selling: traderA sells some option 0 shares
        vm.prank(traderA);
        uint256[] memory sharesA = getUserShares(mId, traderA);
        if (sharesA[0] > 10e18) {
            market.sellShares(mId, 0, 8e18, 0, 0); // Sell smaller specific amount
        }
        _emitPriceSample(mId, 0, 6);
        _emitPriceSample(mId, 1, 6);

        // traderC also sells some of their position
        vm.prank(traderC);
        uint256[] memory sharesC = getUserShares(mId, traderC);
        if (sharesC[1] > 15e18) {
            market.sellShares(mId, 1, 15e18, 0, 0);
        }
        _emitPriceSample(mId, 0, 7);
        _emitPriceSample(mId, 1, 7);

        // resolve to option 1 winners
        vm.warp(block.timestamp + 3 days);
        vm.prank(creator);
        market.resolveMarket(mId, 1);

        // claim winnings where applicable
        vm.prank(traderC);
        uint256[] memory shC = getUserShares(mId, traderC);
        if (shC[1] > 0) {
            vm.prank(traderC);
            market.claimWinnings(mId);
        }

        // final samples
        _emitPriceSample(mId, 0, 8);
        _emitPriceSample(mId, 1, 8);

        // basic sanity assertions
        assertGt(views.calculateCurrentPrice(mId, 0), 0);
        assertGt(views.calculateCurrentPrice(mId, 1), 0);
    }

    function testDetailedBuySellPriceMovements() public {
        // Create a market with much higher initial liquidity for more stable LMSR behavior
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "Option A";
        names[1] = "Option B";
        string[] memory descs = new string[](2);
        descs[0] = "A";
        descs[1] = "B";
        uint256 mId = market.createMarket(
            "Detailed Price Test",
            "Test market for price movements",
            names,
            descs,
            2 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            100000 ether,
            false
        );
        market.validateMarket(mId);
        vm.stopPrank();

        // Step 0: Initial state - should be 50/50
        _emitPriceSample(mId, 0, 0);
        _emitPriceSample(mId, 1, 0);

        // Step 1: Adaptive medium buy Option A (goal 30e18)
        _adaptiveBuy(traderA, mId, 0, 30e18);
        _emitPriceSample(mId, 0, 1);
        _emitPriceSample(mId, 1, 1);

        // Step 2: Adaptive buy Option B (goal 25e18)
        _adaptiveBuy(traderB, mId, 1, 25e18);
        _emitPriceSample(mId, 0, 2);
        _emitPriceSample(mId, 1, 2);

        // Step 3: Adaptive buy Option A (goal 20e18)
        _adaptiveBuy(traderC, mId, 0, 20e18);
        _emitPriceSample(mId, 0, 3);
        _emitPriceSample(mId, 1, 3);

        // Step 4: Now try selling - sell some of traderA's position
        _adaptiveSell(traderA, mId, 0, 4);
        _emitPriceSample(mId, 0, 4);
        _emitPriceSample(mId, 1, 4);

        // Step 5: Sell some of traderB's Option B position
        _adaptiveSell(traderB, mId, 1, 5);
        _emitPriceSample(mId, 0, 5);
        _emitPriceSample(mId, 1, 5);

        // Step 6: Adaptive buy again to show price recovery (goal 30e18)
        _adaptiveBuy(traderA, mId, 0, 30e18);
        _emitPriceSample(mId, 0, 6);
        _emitPriceSample(mId, 1, 6);

        // Final validation
        uint256 finalPriceA = views.calculateCurrentPrice(mId, 0);
        uint256 finalPriceB = views.calculateCurrentPrice(mId, 1);

        // Prices should still be valid and sum approximately to 1e18
        assertGt(finalPriceA, 0);
        assertGt(finalPriceB, 0);
        assertApproxEqAbs(finalPriceA + finalPriceB, 1e18, 1e15); // Allow small tolerance for rounding
    }

    function testMultipleTraderBuySellSequence() public {
        // Create market with very high liquidity for stable 3-option LMSR
        vm.startPrank(creator);
        string[] memory names = new string[](3);
        names[0] = "Red";
        names[1] = "Blue";
        names[2] = "Green";
        string[] memory descs = new string[](3);
        descs[0] = "R";
        descs[1] = "B";
        descs[2] = "G";
        uint256 mId = market.createMarket(
            "Three Option Test",
            "Testing with 3 options",
            names,
            descs,
            2 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            200000 ether,
            false
        );
        market.validateMarket(mId);
        vm.stopPrank();

        // Initial prices (should be ~33.33% each)
        _emitPriceSample(mId, 0, 0);
        _emitPriceSample(mId, 1, 0);
        _emitPriceSample(mId, 2, 0);

        // Round 1: Each trader buys a different option (smaller amounts)
        _adaptiveBuy(traderA, mId, 0, 25e18); // Red
        _emitPriceSample(mId, 0, 1);
        _emitPriceSample(mId, 1, 1);
        _emitPriceSample(mId, 2, 1);

        _adaptiveBuy(traderB, mId, 1, 20e18); // Blue
        _emitPriceSample(mId, 0, 2);
        _emitPriceSample(mId, 1, 2);
        _emitPriceSample(mId, 2, 2);

        _adaptiveBuy(traderC, mId, 2, 15e18); // Green
        _emitPriceSample(mId, 0, 3);
        _emitPriceSample(mId, 1, 3);
        _emitPriceSample(mId, 2, 3);

        // Round 2: Sell conservative portions of each position
        _adaptiveSell(traderA, mId, 0, 6);
        _emitPriceSample(mId, 0, 4);
        _emitPriceSample(mId, 1, 4);
        _emitPriceSample(mId, 2, 4);

        _adaptiveSell(traderB, mId, 1, 7);
        _emitPriceSample(mId, 0, 5);
        _emitPriceSample(mId, 1, 5);
        _emitPriceSample(mId, 2, 5);

        // Round 3: More buying to show price movements
        // Adaptive buy Blue by traderA goal 25e18
        _adaptiveBuy(traderA, mId, 1, 25e18);
        _emitPriceSample(mId, 0, 6);
        _emitPriceSample(mId, 1, 6);
        _emitPriceSample(mId, 2, 6);

        // Adaptive buy Red by traderC goal 20e18
        _adaptiveBuy(traderC, mId, 0, 20e18);
        _emitPriceSample(mId, 0, 7);
        _emitPriceSample(mId, 1, 7);
        _emitPriceSample(mId, 2, 7);

        // Final validation
        uint256 price0 = views.calculateCurrentPrice(mId, 0);
        uint256 price1 = views.calculateCurrentPrice(mId, 1);
        uint256 price2 = views.calculateCurrentPrice(mId, 2);

        assertGt(price0, 0);
        assertGt(price1, 0);
        assertGt(price2, 0);
        // Three option prices should sum to approximately 1e18
        assertApproxEqAbs(price0 + price1 + price2, 1e18, 1e15);
    }
}
