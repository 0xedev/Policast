// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {PolicastViews} from "src/PolicastViews.sol";
import {MockERC20} from "./MockERC20.sol";

contract MultiOptionDeterministicTest is Test {
    MockERC20 internal token;
    PolicastMarketV3 internal market;
    PolicastViews internal views;
    address internal creator = address(0xAA01);
    address internal user = address(0xBB01);

    uint256 constant INITIAL_LIQ = 200_000 ether;
    uint256 constant SMALL_QTY = 10e18; // 10 shares

    function setUp() public {
        token = new MockERC20(50_000_000 ether);
        vm.prank(creator);
        market = new PolicastMarketV3(address(token));
        views = new PolicastViews(address(market));

        token.transfer(creator, 10_000_000 ether);
        token.transfer(user, 10_000_000 ether);

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
        for (uint256 i; i < n; i++) {
            names[i] = string(abi.encodePacked("O", vm.toString(i)));
            descs[i] = names[i];
        }
        uint256 id = market.createMarket(
            "Deterministic",
            "Deterministic",
            names,
            descs,
            2 days,
            PolicastMarketV3.MarketCategory.SPORTS,
            PolicastMarketV3.MarketType.PAID,
            INITIAL_LIQ,
            false
        );
        market.validateMarket(id);
        vm.stopPrank();
        return id;
    }

    function testInitialEqualProbabilities() public {
        uint256[5] memory counts = [uint256(2), 4, 5, 6, 8];
        for (uint256 idx; idx < counts.length; idx++) {
            uint256 n = counts[idx];
            uint256 id = _create(n);
            uint256 expected = 1e18 / n;
            uint256 sum = 0;
            for (uint256 i; i < n; i++) {
                uint256 p = views.calculateCurrentPrice(id, i);
                sum += p;
                // allow small 5e12 tolerance (~5 ppm) around uniform
                assertApproxEqAbs(p, expected, 5e12, "init prob");
            }
            assertApproxEqAbs(sum, 1e18, 5e12 * n, "sum 1e18");
        }
    }

    function testSmallTradeAdjustsOneProbability() public {
        uint256[5] memory counts = [uint256(2), 4, 5, 6, 8];
        for (uint256 idx; idx < counts.length; idx++) {
            uint256 n = counts[idx];
            uint256 id = _create(n);

            // capture before
            uint256[] memory beforeP = new uint256[](n);
            for (uint256 i; i < n; i++) {
                beforeP[i] = views.calculateCurrentPrice(id, i);
            }

            vm.prank(user);
            market.buyShares(id, 0, SMALL_QTY, 5e20, 0); // generous max price

            // after
            uint256 sum = 0;
            uint256[] memory afterP = new uint256[](n);
            for (uint256 i; i < n; i++) {
                afterP[i] = views.calculateCurrentPrice(id, i);
                sum += afterP[i];
            }

            // Option 0 probability should increase
            assertGt(afterP[0], beforeP[0], "target prob should rise");
            // Others should not increase (strictly) all simultaneously; at least one other should decrease
            bool anyDecrease = false;
            for (uint256 i = 1; i < n; i++) {
                if (afterP[i] < beforeP[i]) {
                    anyDecrease = true;
                    break;
                }
            }
            assertTrue(anyDecrease, "some other decreased");
            // Sum conservation
            assertApproxEqAbs(sum, 1e18, 2e13, "sum stable"); // 2e13 tolerance (20 ppm) slack
            // Bounds
            for (uint256 i; i < n; i++) {
                assertLt(afterP[i], 1e18, "no 100%");
                assertGt(afterP[i], 0, "no zero");
            }
        }
    }
}
