// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, StdUtils} from "forge-std/Test.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {PolicastViews} from "src/PolicastViews.sol";
import {MockERC20} from "./MockERC20.sol";

// Fuzz test focusing on LMSR probability invariants under random trade sequences.
// Not exhaustive economic fuzzing, but validates key invariants:
// 1. Sum of probabilities ≈ 1e18 within small tolerance
// 2. No probability collapses to 0 or 1e18
// 3. Directional buys raise target probability vs immediate prior state (when qty>0)
contract FuzzProbabilitiesTest is Test {
    MockERC20 internal token;
    PolicastMarketV3 internal market;
    PolicastViews internal views;
    address internal creator = address(0xCAFE);
    address internal userA = address(0xB0A1);
    address internal userB = address(0xB0B2);

    uint256 constant INITIAL_LIQ = 300_000 ether;

    function setUp() public {
        token = new MockERC20(100_000_000 ether);
        vm.prank(creator);
        market = new PolicastMarketV3(address(token));
        views = new PolicastViews(address(market));
        token.transfer(creator, 20_000_000 ether);
        token.transfer(userA, 20_000_000 ether);
        token.transfer(userB, 20_000_000 ether);
        vm.prank(creator);
        token.approve(address(market), type(uint256).max);
        vm.prank(userA);
        token.approve(address(market), type(uint256).max);
        vm.prank(userB);
        token.approve(address(market), type(uint256).max);
        vm.startPrank(creator);
        market.grantQuestionCreatorRole(creator);
        market.grantQuestionResolveRole(creator);
        market.grantMarketValidatorRole(creator);
        vm.stopPrank();
    }

    function _create(uint256 n) internal returns (uint256) {
        string[] memory names = new string[](n);
        string[] memory descs = new string[](n);
        for (uint256 i; i < n; i++) {
            names[i] = string(abi.encodePacked("F", vm.toString(i)));
            descs[i] = names[i];
        }
        vm.startPrank(creator);
        uint256 id = market.createMarket(
            "Fuzz",
            "Fuzz",
            names,
            descs,
            3 days,
            PolicastMarketV3.MarketCategory.TECHNOLOGY,
            PolicastMarketV3.MarketType.PAID,
            INITIAL_LIQ,
            false
        );
        market.validateMarket(id);
        vm.stopPrank();
        return id;
    }

    // Fuzz across option count, trade iterations, and trade size
    function testFuzzProbabilities(uint8 optionCountRaw, uint8 iterationsRaw, uint128 qtyRaw) public {
        uint256 optionCount = 2 + (uint256(optionCountRaw) % 6); // 2..7 options
        if (optionCount == 7) optionCount = 8; // map 7 -> 8 to include 8 outcomes path
        uint256 iterations = 1 + (uint256(iterationsRaw) % 25); // 1..25 trades
        uint256 qty = 1e18 + (uint256(qtyRaw) % (50e18)); // 1 to 50 shares

        uint256 id = _create(optionCount);

        address[2] memory actors = [userA, userB];

        for (uint256 it = 0; it < iterations; it++) {
            uint256 opt = uint256(keccak256(abi.encode(qtyRaw, it, optionCount))) % optionCount;
            address actor = actors[it % 2];
            // capture before probability
            uint256 beforeP = views.calculateCurrentPrice(id, opt);
            // generous max price cap
            vm.prank(actor);
            market.buyShares(id, opt, qty, 5e20, 0);
            uint256 afterP = views.calculateCurrentPrice(id, opt);
            assertGt(afterP, 0, "after prob zero");
            assertLt(afterP, 1e18, "after prob one");
            // directional monotonicity (allow equal if rounding)
            assertGe(afterP, beforeP, "target prob should not fall");

            // Check global invariants
            uint256 sum = 0;
            for (uint256 i = 0; i < optionCount; i++) {
                uint256 p = views.calculateCurrentPrice(id, i);
                sum += p;
                assertLt(p, 1e18, "p < 1e18");
                assertGt(p, 0, "p > 0");
            }
            // 30 ppm tolerance on sum
            assertApproxEqAbs(sum, 1e18, 3e13, "sum");
        }
    }
}
