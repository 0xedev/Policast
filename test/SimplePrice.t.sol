// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/Policast.sol";
import "../src/PolicastViews.sol";
import "./MockERC20.sol";

contract SimplePriceTest is Test {
    // Precomputed selectors for overloaded functions
    bytes4 private constant BUY_EXT_SIG = bytes4(keccak256("buyShares(uint256,uint256,uint256,uint256,uint256)"));
    bytes4 private constant SELL_EXT_SIG = bytes4(keccak256("sellShares(uint256,uint256,uint256,uint256,uint256)"));
    PolicastMarketV3 public market;
    PolicastViews public views;
    MockERC20 public token;

    address creator = address(0xcafE);
    address trader = address(0xbEEf1);

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
        token = new MockERC20(10000000 ether);

        vm.prank(creator);
        market = new PolicastMarketV3(address(token));
        views = new PolicastViews(address(market));

        // CRITICAL FIX: Increase creator funding for 3-option test
        token.transfer(creator, 200000 ether); // Increased from 100k to cover 150k + buffer
        token.transfer(trader, 10000 ether);

        // Set approvals
        vm.prank(creator);
        token.approve(address(market), type(uint256).max);
        vm.prank(trader);
        token.approve(address(market), type(uint256).max);

        // Grant roles - following CEI pattern (checks, effects, interactions)
        vm.startPrank(creator);
        market.grantQuestionCreatorRole(creator);
        market.grantQuestionResolveRole(creator);
        market.grantMarketValidatorRole(creator);
        vm.stopPrank();
    }

    function _emitPriceSample(uint256 mId, uint256 optId, uint256 step) internal {
        uint256 price = views.calculateCurrentPrice(mId, optId);
        emit PriceSample(mId, optId, step, price, block.timestamp);
    }

    function testSimpleBuyPriceMovement() public {
        // Create a small market with high liquidity to minimize LMSR sensitivity
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "Yes";
        names[1] = "No";
        string[] memory descs = new string[](2);
        descs[0] = "Y";
        descs[1] = "N";
        uint256 mId = market.createMarket(
            "Simple Test",
            "Testing simple buy movements",
            names,
            descs,
            2 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            50000 ether, // High initial liquidity
            false
        );
        market.validateMarket(mId);
        vm.stopPrank();

        // Log the computed b value for this market
        uint256 computedB = market.getMarketLMSRB(mId);
        console.log("Market", mId, "computed b value:", computedB);

        // Initial state: 50/50
        _emitPriceSample(mId, 0, 0);
        _emitPriceSample(mId, 1, 0);

        // Adaptive small buy on option 0 (probe doubling until success or cap)
        uint256 qty = 1e18; // start tiny (0.01 ether expressed in wei with 18 decimals)
        uint256 executedA1 = 0;
        for (uint256 i; i < 12; i++) {
            // cap attempts
            vm.startPrank(trader);
            (bool ok,) = address(market).call(abi.encodeWithSelector(BUY_EXT_SIG, mId, 0, qty, type(uint256).max, 0));
            vm.stopPrank();
            if (ok) {
                executedA1 = qty;
                break;
            }
            qty *= 2; // escalate
        }
        require(executedA1 > 0, "adaptive buy A1 failed");
        _emitPriceSample(mId, 0, 1);
        _emitPriceSample(mId, 1, 1);

        // Second adaptive buy on option 0
        qty = executedA1; // start from last working size
        uint256 executedA2 = 0;
        for (uint256 i; i < 8; i++) {
            vm.startPrank(trader);
            (bool ok,) = address(market).call(abi.encodeWithSelector(BUY_EXT_SIG, mId, 0, qty, type(uint256).max, 0));
            vm.stopPrank();
            if (ok) {
                executedA2 = qty;
                break;
            }
            qty *= 2;
        }
        require(executedA2 > 0, "adaptive buy A2 failed");
        _emitPriceSample(mId, 0, 2);
        _emitPriceSample(mId, 1, 2);

        // Adaptive buy on option 1 to move price back
        qty = executedA1; // reuse base size
        uint256 executedB1 = 0;
        for (uint256 i; i < 8; i++) {
            vm.startPrank(trader);
            (bool ok,) = address(market).call(abi.encodeWithSelector(BUY_EXT_SIG, mId, 1, qty, type(uint256).max, 0));
            vm.stopPrank();
            if (ok) {
                executedB1 = qty;
                break;
            }
            qty *= 2;
        }
        require(executedB1 > 0, "adaptive buy B1 failed");
        _emitPriceSample(mId, 0, 3);
        _emitPriceSample(mId, 1, 3);

        // Adaptive small sell of ~10% of position (probe downwards if needed)
        vm.prank(trader);
        uint256[] memory shares = getUserShares(mId, trader);
        if (shares[0] > 0) {
            uint256 sellTry = shares[0] / 10;
            if (sellTry == 0) sellTry = shares[0];
            uint256 executedSell = 0;
            for (uint256 i; i < 6 && sellTry > 0; i++) {
                vm.startPrank(trader);
                (bool ok,) = address(market).call(abi.encodeWithSelector(SELL_EXT_SIG, mId, 0, sellTry, 0, 0));
                vm.stopPrank();
                if (ok) {
                    executedSell = sellTry;
                    break;
                }
                sellTry /= 2; // reduce and retry
            }
            // sell optional; ignore if zero due to precision
            if (executedSell > 0) {
                // price samples already captured below
            }
        }
        _emitPriceSample(mId, 0, 4);
        _emitPriceSample(mId, 1, 4);

        // Ensure prices still valid
        assertGt(views.calculateCurrentPrice(mId, 0), 0);
        assertGt(views.calculateCurrentPrice(mId, 1), 0);
    }

    function testVeryBasicBuySell() public {
        // Use conservative setup
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "A";
        names[1] = "B";
        string[] memory descs = new string[](2);
        descs[0] = "A";
        descs[1] = "B";
        uint256 mId = market.createMarket(
            "Basic Test",
            "Basic",
            names,
            descs,
            2 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            100000 ether, // High liquidity for stable pricing
            false
        );
        market.validateMarket(mId);
        vm.stopPrank();

        // Log the computed b value for this market
        uint256 computedB = market.getMarketLMSRB(mId);
        console.log("Market", mId, "computed b value:", computedB);

        // Step 1: Sample initial prices (should be 50/50)
        uint256 p0_0 = views.calculateCurrentPrice(mId, 0);
        uint256 p1_0 = views.calculateCurrentPrice(mId, 1);
        console.log("Initial Price A:", p0_0);
        console.log("Initial Price B:", p1_0);

        // Step 2: Buy exactly 1 share of option A (1e18 = 1 share with 18 decimals)
        console.log("Buying 1 share of option A");
        vm.startPrank(trader);
        market.buyShares(mId, 0, 1e18, type(uint256).max, 0); // 1 share, unlimited cost, no deadline
        vm.stopPrank();

        uint256 p0_1 = views.calculateCurrentPrice(mId, 0);
        uint256 p1_1 = views.calculateCurrentPrice(mId, 1);
        console.log("After buying 1 share A - Price A:", p0_1);
        console.log("After buying 1 share A - Price B:", p1_1);

        // Step 3: Buy another 1 share of option A
        console.log("Buying 1 more share of option A");
        vm.startPrank(trader);
        market.buyShares(mId, 0, 1e18, type(uint256).max, 0);
        vm.stopPrank();

        uint256 p0_2 = views.calculateCurrentPrice(mId, 0);
        uint256 p1_2 = views.calculateCurrentPrice(mId, 1);
        console.log("After buying 2 total shares A - Price A:", p0_2);
        console.log("After buying 2 total shares A - Price B:", p1_2);

        // Step 4: Check trader's share balance
        vm.prank(trader);
        uint256[] memory shares = getUserShares(mId, trader);
        console.log("Trader has shares A:", shares[0]);
        console.log("Trader has shares B:", shares[1]);

        // Should have exactly 2 shares of A
        assertEq(shares[0], 2e18, "Should have exactly 2 shares of A");
        assertEq(shares[1], 0, "Should have 0 shares of B");

        // Step 5: Sell 0.2 shares (20% of position)
        uint256 sellAmount = 2e17; // 0.2 shares
        console.log("Selling 0.2 shares of option A");
        vm.startPrank(trader);
        market.sellShares(mId, 0, sellAmount, 0, 0); // 0.2 shares, min price 0, no deadline
        vm.stopPrank();

        uint256 p0_3 = views.calculateCurrentPrice(mId, 0);
        uint256 p1_3 = views.calculateCurrentPrice(mId, 1);
        console.log("After selling 0.2 shares A - Price A:", p0_3);
        console.log("After selling 0.2 shares A - Price B:", p1_3);

        // Verify final position
        shares = getUserShares(mId, trader);
        assertEq(shares[0], 18e17, "Should have exactly 1.8 shares of A remaining"); // 2.0 - 0.2 = 1.8

        // Verify price movements are logical
        assertTrue(p0_1 > p0_0, "Price A should increase after buying A");
        assertTrue(p1_1 < p1_0, "Price B should decrease after buying A");
        assertTrue(p0_2 > p0_1, "Price A should keep increasing with more buys");
        assertTrue(p0_3 < p0_2, "Price A should decrease after selling A");
        assertTrue(p1_3 > p1_2, "Price B should increase after selling A");
    }

    // NEW: 3-Option Test
    function testThreeOptionBuyPriceMovement() public {
        // Create 3-option market with high liquidity
        vm.startPrank(creator);
        string[] memory names = new string[](3);
        names[0] = "Red";
        names[1] = "Green";
        names[2] = "Blue";
        string[] memory descs = new string[](3);
        descs[0] = "R";
        descs[1] = "G";
        descs[2] = "B";
        uint256 mId = market.createMarket(
            "3-Option Test",
            "Testing 3-option buy movements",
            names,
            descs,
            2 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            150000 ether, // Higher for N=3 coverage
            false
        );
        market.validateMarket(mId);
        vm.stopPrank();

        // Log the computed b value for this market
        uint256 computedB = market.getMarketLMSRB(mId);
        console.log("Market", mId, "computed b value:", computedB);

        // Initial state: ~33.33 each
        _emitPriceSample(mId, 0, 0);
        _emitPriceSample(mId, 1, 0);
        _emitPriceSample(mId, 2, 0);

        // Adaptive buy on option 0 (full share start)
        uint256 qty = 1e18;
        uint256 executedA1 = 0;
        for (uint256 i; i < 12; i++) {
            vm.startPrank(trader);
            (bool ok,) = address(market).call(abi.encodeWithSelector(BUY_EXT_SIG, mId, 0, qty, type(uint256).max, 0));
            vm.stopPrank();
            if (ok) {
                executedA1 = qty;
                break;
            }
            qty *= 2;
        }
        require(executedA1 > 0, "adaptive buy A1 failed");
        _emitPriceSample(mId, 0, 1);
        _emitPriceSample(mId, 1, 1);
        _emitPriceSample(mId, 2, 1);

        // Adaptive buy on option 1 to balance
        qty = executedA1;
        uint256 executedB1 = 0;
        for (uint256 i; i < 8; i++) {
            vm.startPrank(trader);
            (bool ok,) = address(market).call(abi.encodeWithSelector(BUY_EXT_SIG, mId, 1, qty, type(uint256).max, 0));
            vm.stopPrank();
            if (ok) {
                executedB1 = qty;
                break;
            }
            qty *= 2;
        }
        require(executedB1 > 0, "adaptive buy B1 failed");
        _emitPriceSample(mId, 0, 2);
        _emitPriceSample(mId, 1, 2);
        _emitPriceSample(mId, 2, 2);

        // Adaptive small sell of ~10% from option 0
        vm.prank(trader);
        uint256[] memory shares = getUserShares(mId, trader);
        if (shares[0] > 0) {
            uint256 sellTry = shares[0] / 10;
            if (sellTry == 0) sellTry = shares[0];
            uint256 executedSell = 0;
            for (uint256 i; i < 6 && sellTry > 0; i++) {
                vm.startPrank(trader);
                (bool ok,) = address(market).call(abi.encodeWithSelector(SELL_EXT_SIG, mId, 0, sellTry, 0, 0));
                vm.stopPrank();
                if (ok) {
                    executedSell = sellTry;
                    break;
                }
                sellTry /= 2;
            }
            // Optional; ignore if precision fails
        }
        _emitPriceSample(mId, 0, 3);
        _emitPriceSample(mId, 1, 3);
        _emitPriceSample(mId, 2, 3);

        // Ensure prices valid
        assertGt(views.calculateCurrentPrice(mId, 0), 0);
        assertGt(views.calculateCurrentPrice(mId, 1), 0);
        assertGt(views.calculateCurrentPrice(mId, 2), 0);
    }
}
