// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {PolicastViews} from "src/PolicastViews.sol";
import {MockERC20} from "./MockERC20.sol";

contract LMSRMultiOptionTest is Test {
    MockERC20 internal token;
    PolicastMarketV3 internal market;
    PolicastViews internal views;
    address internal creator = address(0xCAFE);
    address internal user = address(0xF00D);

    function setUp() public {
        token = new MockERC20(10_000_000 ether);
        vm.prank(creator);
        market = new PolicastMarketV3(address(token));
        views = new PolicastViews(address(market));
        token.transfer(creator, 2_000_000 ether);
        token.transfer(user, 2_000_000 ether);
        vm.prank(creator);
        token.approve(address(market), type(uint256).max);
        vm.prank(user);
        token.approve(address(market), type(uint256).max);
        vm.startPrank(creator);
        market.grantQuestionCreatorRole(creator);
        market.grantQuestionResolveRole(creator);
        market.grantMarketValidatorRole(creator);
        vm.stopPrank();
    }

    function _create(uint256 n) internal returns (uint256) {
        vm.startPrank(creator);
        string[] memory names = new string[](n);
        string[] memory descs = new string[](n);
        for (uint256 i = 0; i < n; i++) {
            names[i] = string(abi.encodePacked("O", vm.toString(i)));
            descs[i] = names[i];
        }
        uint256 mId = market.createMarket(
            "Multi",
            "Multi",
            names,
            descs,
            1 days,
            PolicastMarketV3.MarketCategory.SPORTS,
            PolicastMarketV3.MarketType.PAID,
            100_000 ether,
            false
        );
        market.validateMarket(mId);
        vm.stopPrank();
        return mId;
    }

    function testInitialEqualPricing() public {
        uint256[5] memory counts = [uint256(2), 4, 5, 6, 8];
        for (uint256 k = 0; k < counts.length; k++) {
            uint256 n = counts[k];
            uint256 mId = _create(n);
            uint256[] memory odds = views.getMarketOdds(mId);
            uint256 sum = 0;
            for (uint256 i = 0; i < n; i++) {
                sum += odds[i];
                // Each should be close to 1/n
                uint256 expected = 1e18 / n;
                assertApproxEqAbs(odds[i], expected, 1e15, "equal pricing");
            }
            assertApproxEqAbs(sum, 1e18, 1e15, "sum 1.0");
        }
    }

    function testSmallTradeBehavior() public {
        uint256[5] memory counts = [uint256(2), 4, 5, 6, 8];
        for (uint256 k = 0; k < counts.length; k++) {
            uint256 n = counts[k];
            uint256 mId = _create(n);
            // small trade
            vm.startPrank(user);
            market.buyShares(mId, 0, 10e18, 5e20, 0);
            vm.stopPrank();
            uint256[] memory odds = views.getMarketOdds(mId);
            uint256 sum = 0;
            for (uint256 i = 0; i < n; i++) sum += odds[i];
            assertApproxEqAbs(sum, 1e18, 1e15, "sum 1.0 after buy");
            // bought outcome should have highest probability
            for (uint256 i = 1; i < n; i++) {
                assertGt(odds[0], odds[i], "bought outcome should gain");
            }
        }
    }

    function testFuzzOptionCounts(uint8 nRaw, uint96 qtyRaw) public {
        uint256 n = 2 + (uint256(nRaw) % 7); // 2..8
        uint256 qty = 1e18 + (uint256(qtyRaw) % (200e18)); // [1,200] shares
        uint256 mId = _create(n);
        vm.startPrank(user);
        market.buyShares(mId, uint256(qtyRaw) % n, qty, 5e20, 0);
        vm.stopPrank();
        uint256[] memory odds = views.getMarketOdds(mId);
        uint256 sum = 0;
        for (uint256 i = 0; i < n; i++) {
            assertLe(odds[i], 1e18, "p<=1");
            sum += odds[i];
        }
        assertApproxEqAbs(sum, 1e18, 2e15, "sum 1.0 fuzz");
    }
}
