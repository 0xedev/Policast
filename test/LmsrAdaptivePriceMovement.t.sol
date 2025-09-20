// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {PolicastViews} from "src/PolicastViews.sol";
import {MockERC20} from "./MockERC20.sol";

contract LmsrAdaptivePriceMovement is Test {
    MockERC20 internal token;
    PolicastMarketV3 internal market;
    PolicastViews internal views;
    address internal creator = address(0xCAFE);
    address internal trader = address(0xBEEF1);

    // Pre-computed selectors for overloaded functions
    bytes4 private constant BUY_EXT_SELECTOR = bytes4(keccak256("buyShares(uint256,uint256,uint256,uint256,uint256)"));
    bytes4 private constant SELL_EXT_SELECTOR = bytes4(keccak256("sellShares(uint256,uint256,uint256,uint256,uint256)"));

    struct PriceRow {
        uint256 step;
        uint256[] probs;
        uint256[] tokenScaled;
    }

    event PriceRowEmitted(uint256 indexed step, uint256[] probs, uint256[] tokens);

    function setUp() public {
        token = new MockERC20(5_000_000 ether);
        vm.prank(creator);
        market = new PolicastMarketV3(address(token));
        views = new PolicastViews(address(market));
        token.transfer(creator, 500_000 ether);
        token.transfer(trader, 200_000 ether);
        vm.prank(creator);
        token.approve(address(market), type(uint256).max);
        vm.prank(trader);
        token.approve(address(market), type(uint256).max);
        vm.startPrank(creator);
        market.grantQuestionCreatorRole(creator);
        market.grantQuestionResolveRole(creator);
        market.grantMarketValidatorRole(creator);
        vm.stopPrank();
    }

    function _snapshot(uint256 marketId, uint256 step, uint256 optionCount) internal {
        uint256[] memory probs = new uint256[](optionCount);
        uint256[] memory tokens = new uint256[](optionCount);
        for (uint256 i = 0; i < optionCount; i++) {
            uint256 p = views.calculateCurrentPrice(marketId, i);
            probs[i] = p;
            tokens[i] = (p * 100) / 1e18;
        }
        emit PriceRowEmitted(step, probs, tokens);
    }

    function _adaptiveBuy(uint256 marketId, uint256 optionId, uint256 maxAttempts, uint256 initialSize)
        internal
        returns (uint256 executedSize)
    {
        uint256 size = initialSize;
        uint256 cap = initialSize * 2 ** (maxAttempts - 1);
        for (uint256 i = 0; i < maxAttempts; i++) {
            vm.prank(trader);
            (bool ok,) = address(market).call(
                abi.encodeWithSelector(BUY_EXT_SELECTOR, marketId, optionId, size, type(uint256).max, 0)
            );
            if (ok) {
                executedSize = size;
                return executedSize;
            }
            size *= 2;
            if (size > cap) break;
        }
        revert("NoNonZeroBuyFound");
    }

    function _adaptiveSell(uint256 marketId, uint256 optionId, uint256 maxAttempts, uint256 initialSize)
        internal
        returns (uint256 executedSize)
    {
        uint256 size = initialSize;
        uint256 cap = initialSize * 2 ** (maxAttempts - 1);
        for (uint256 i = 0; i < maxAttempts; i++) {
            vm.prank(trader);
            (bool ok,) = address(market).call(abi.encodeWithSelector(SELL_EXT_SELECTOR, marketId, optionId, size, 0, 0));
            if (ok) {
                executedSize = size;
                return executedSize;
            }
            size *= 2;
            if (size > cap) break;
        }
        revert("NoNonZeroSellFound");
    }

    function testAdaptiveTwoOptionBuySell() public {
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "Yes";
        names[1] = "No";
        string[] memory descs = new string[](2);
        descs[0] = "Y";
        descs[1] = "N";
        uint256 mId = market.createMarket(
            "Adaptive 2",
            "Demo adaptive two option",
            names,
            descs,
            2 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            50_000 ether,
            false
        );
        market.validateMarket(mId);
        vm.stopPrank();

        _snapshot(mId, 0, 2);
        uint256 buyA = _adaptiveBuy(mId, 0, 8, 1e16);
        _snapshot(mId, 1, 2);
        uint256 buyB = _adaptiveBuy(mId, 1, 8, 1e16);
        _snapshot(mId, 2, 2);
        uint256 buyA2 = _adaptiveBuy(mId, 0, 8, buyA);
        _snapshot(mId, 3, 2);

        // Get user shares for option 0 directly
        uint256 sharesTrader0 = market.getMarketOptionUserShares(mId, 0, trader);
        uint256 tentativeSell = sharesTrader0 / 4;
        if (tentativeSell > 0) {
            uint256 base = tentativeSell / 8;
            if (base == 0) base = 1e16;
            uint256 sellA = _adaptiveSell(mId, 0, 8, base);
            emit log_named_uint("Executed sell size", sellA);
            _snapshot(mId, 4, 2);
        }
        uint256 p0 = views.calculateCurrentPrice(mId, 0);
        uint256 p1 = views.calculateCurrentPrice(mId, 1);
        assertGt(p0, 0);
        assertGt(p1, 0);
        assertApproxEqAbs(p0 + p1, 1e18, 2e15);
        // Silence warnings about unused vars (show they exist for debugging if needed)
        emit log_named_uint("buyA", buyA);
        emit log_named_uint("buyB", buyB);
        emit log_named_uint("buyA2", buyA2);
    }

    function _snapshotN(uint256 marketId, uint256 step, uint256 optionCount) internal {
        uint256[] memory probs = new uint256[](optionCount);
        uint256[] memory tokens = new uint256[](optionCount);
        for (uint256 i = 0; i < optionCount; i++) {
            uint256 p = views.calculateCurrentPrice(marketId, i);
            probs[i] = p;
            tokens[i] = (p * 100) / 1e18;
        }
        emit PriceRowEmitted(step, probs, tokens);
    }

    function testAdaptiveThreeOptionBuySell() public {
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
            "Adaptive 3",
            "Three option adaptive",
            names,
            descs,
            2 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            120_000 ether,
            false
        );
        market.validateMarket(mId);
        vm.stopPrank();

        _snapshotN(mId, 0, 3); // initial ~33/33/33
        uint256 buy0 = _adaptiveBuy(mId, 0, 8, 1e16);
        _snapshotN(mId, 1, 3);
        uint256 buy1 = _adaptiveBuy(mId, 1, 8, 1e16);
        _snapshotN(mId, 2, 3);
        uint256 buy2 = _adaptiveBuy(mId, 2, 8, 1e16);
        _snapshotN(mId, 3, 3);
        // Push leading option further (likely 0) and then sell part of it
        uint256 buy0b = _adaptiveBuy(mId, 0, 8, buy0);
        _snapshotN(mId, 4, 3);

        // Get user shares for each option
        uint256 shares0 = market.getMarketOptionUserShares(mId, 0, trader);
        uint256 shares1 = market.getMarketOptionUserShares(mId, 1, trader);
        uint256 shares2 = market.getMarketOptionUserShares(mId, 2, trader);

        // find an option with shares to sell (prefer option 0)
        uint256 sellOption = 0;
        uint256 sellShares = shares0;
        if (sellShares == 0) {
            if (shares1 > 0) {
                sellOption = 1;
                sellShares = shares1;
            } else if (shares2 > 0) {
                sellOption = 2;
                sellShares = shares2;
            }
        }
        if (sellShares > 0) {
            uint256 base = sellShares / 16;
            if (base == 0) base = 1e16;
            _adaptiveSell(mId, sellOption, 8, base);
            _snapshotN(mId, 5, 3);
        }
        uint256 p0 = views.calculateCurrentPrice(mId, 0);
        uint256 p1 = views.calculateCurrentPrice(mId, 1);
        uint256 p2 = views.calculateCurrentPrice(mId, 2);
        assertGt(p0, 0);
        assertGt(p1, 0);
        assertGt(p2, 0);
        assertApproxEqAbs(p0 + p1 + p2, 1e18, 3e15);
        emit log_named_uint("buy0", buy0);
        emit log_named_uint("buy1", buy1);
        emit log_named_uint("buy2", buy2);
        emit log_named_uint("buy0b", buy0b);
    }

    function testAdaptiveFourOptionBuySell() public {
        vm.startPrank(creator);
        string[] memory names = new string[](4);
        names[0] = "A";
        names[1] = "B";
        names[2] = "C";
        names[3] = "D";
        string[] memory descs = new string[](4);
        descs[0] = "A";
        descs[1] = "B";
        descs[2] = "C";
        descs[3] = "D";
        uint256 mId = market.createMarket(
            "Adaptive 4",
            "Four option adaptive",
            names,
            descs,
            2 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            200_000 ether,
            false
        );
        market.validateMarket(mId);
        vm.stopPrank();

        _snapshotN(mId, 0, 4); // initial ~25% each
        uint256 b0 = _adaptiveBuy(mId, 0, 8, 1e16);
        _snapshotN(mId, 1, 4);
        uint256 b1 = _adaptiveBuy(mId, 1, 8, 1e16);
        _snapshotN(mId, 2, 4);
        uint256 b2 = _adaptiveBuy(mId, 2, 8, 1e16);
        _snapshotN(mId, 3, 4);
        uint256 b3 = _adaptiveBuy(mId, 3, 8, 1e16);
        _snapshotN(mId, 4, 4);
        // Further buy on option 0 then sell some of it
        uint256 b0b = _adaptiveBuy(mId, 0, 8, b0);
        _snapshotN(mId, 5, 4);
        uint256 shares0 = market.getMarketOptionUserShares(mId, 0, trader);
        if (shares0 > 0) {
            uint256 base = shares0 / 20;
            if (base == 0) base = 1e16;
            _adaptiveSell(mId, 0, 8, base);
            _snapshotN(mId, 6, 4);
        }
        uint256 q0 = views.calculateCurrentPrice(mId, 0);
        uint256 q1 = views.calculateCurrentPrice(mId, 1);
        uint256 q2 = views.calculateCurrentPrice(mId, 2);
        uint256 q3 = views.calculateCurrentPrice(mId, 3);
        assertGt(q0, 0);
        assertGt(q1, 0);
        assertGt(q2, 0);
        assertGt(q3, 0);
        assertApproxEqAbs(q0 + q1 + q2 + q3, 1e18, 4e15);
        emit log_named_uint("b0", b0);
        emit log_named_uint("b1", b1);
        emit log_named_uint("b2", b2);
        emit log_named_uint("b3", b3);
        emit log_named_uint("b0b", b0b);
    }
}
