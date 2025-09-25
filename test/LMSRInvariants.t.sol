// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {PolicastViews} from "src/PolicastViews.sol";
import {MockERC20} from "./MockERC20.sol";

contract LMSRInvariantsTest is Test {
    MockERC20 internal token;
    PolicastMarketV3 internal market;
    PolicastViews internal views;
    address internal creator = address(0xAAA1);
    address internal user = address(0xBBB1);

    uint256 constant QTY = 1000e18; // large trade in shares

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

    function _createMarket(uint256 n) internal returns (uint256) {
        vm.startPrank(creator);
        string[] memory names = new string[](n);
        string[] memory descs = new string[](n);
        for (uint256 i = 0; i < n; i++) {
            names[i] = string(abi.encodePacked("Opt", vm.toString(i)));
            descs[i] = names[i];
        }
        uint256 mId = market.createMarket(
            "Stress",
            "Stress",
            names,
            descs,
            2 days,
            PolicastMarketV3.MarketCategory.SPORTS,
            PolicastMarketV3.MarketType.PAID,
            200_000 ether,
            false
        );
        market.validateMarket(mId);
        vm.stopPrank();
        return mId;
    }

    function testProbabilitiesDoNotCollapseOnLargeBuy() public {
        uint256 mId = _createMarket(5);
        // Large directional buy on option 0
        vm.startPrank(user);
        market.buyShares(mId, 0, QTY, 5e20, 0);
        vm.stopPrank();

        // Reconstruct probabilities from currentPrice (already scaled to 1e18 probabilities in main contract)
        uint256 optionCount = 5;
        uint256[] memory probs = new uint256[](optionCount);
        uint256 sum = 0;
        uint256 maxP = 0;
        uint256 minP = type(uint256).max;
        for (uint256 i = 0; i < optionCount; i++) {
            probs[i] = views.calculateCurrentPrice(mId, i);
            sum += probs[i];
            if (probs[i] > maxP) maxP = probs[i];
            if (probs[i] < minP) minP = probs[i];
        }
        // Sum remains ~1e18 (allow small 1e15 tolerance = 0.000001)
        assertApproxEqAbs(sum, 1e18, 1e15, "prob sum");
        // No collapse to exactly 1 or 0 (give 1e12 guard band)
        assertLt(maxP, 1e18 - 1e12, "no prob 100%");
        assertGt(minP, 1e12, "no prob 0");
    }

    function testRoundTripCostSymmetry() public {
        uint256 mId = _createMarket(3);
        uint256 balBefore = token.balanceOf(user);

        vm.startPrank(user);
        // Capture balance before buy
        uint256 beforeBuy = token.balanceOf(user);
        market.buyShares(mId, 0, QTY, 5e20, 0);
        uint256 afterBuy = token.balanceOf(user);
        uint256 paid = beforeBuy - afterBuy; // tokens spent including fee

        // Sell back the same quantity
        uint256 beforeSell = token.balanceOf(user);
        market.sellShares(mId, 0, QTY, 0, 0);
        uint256 afterSell = token.balanceOf(user);
        vm.stopPrank();

        uint256 recvd = afterSell - beforeSell; // tokens received after fees
        uint256 balAfter = token.balanceOf(user);

        assertLt(balAfter, balBefore, "should net lose fees");
        uint256 loss = paid > recvd ? paid - recvd : 0;

        // Expect loss close to 2 * 2% = 4% of paid notional (allow tighter 35-45 bps window around 4%)
        uint256 minLoss = (paid * 350) / 10_000; // 3.5%
        uint256 maxLoss = (paid * 450) / 10_000; // 4.5%
        assertGe(loss, minLoss, "loss too small");
        assertLe(loss, maxLoss, "loss too big");
    }
}
