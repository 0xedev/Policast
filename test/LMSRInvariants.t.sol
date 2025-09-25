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
        // Buy a very large amount on option 0
        vm.startPrank(user);
        market.buyShares(mId, 0, QTY, 5e20, 0);
        vm.stopPrank();

        uint256[] memory probs = views.getMarketOdds(mId);
        uint256 sum = 0;
        uint256 maxP = 0;
        uint256 minP = type(uint256).max;
        for (uint256 i = 0; i < probs.length; i++) {
            sum += probs[i];
            if (probs[i] > maxP) maxP = probs[i];
            if (probs[i] < minP) minP = probs[i];
        }
        // Sum remains ~1e18
        assertApproxEqAbs(sum, 1e18, 1e15, "prob sum");
        // No collapse to exactly 1 or 0
        assertLt(maxP, 1e18, "no prob 100%");
        assertGt(minP, 0, "no prob 0");
    }

    function testRoundTripCostSymmetry() public {
        uint256 mId = _createMarket(3);
        uint256 balBefore = token.balanceOf(user);

        vm.startPrank(user);
        // Buy QTY
        uint256 costBuy = market.buyShares(mId, 0, QTY, 5e20, 0);
        // Immediately sell QTY
        uint256 retSell = market.sellShares(mId, 0, QTY, 0, 0);
        vm.stopPrank();

        uint256 balAfter = token.balanceOf(user);
        // Two fees applied (buy and sell). Net loss should be close to 2 * fee on the raw ΔC, w/ tiny curvature diff.
        uint256 paid = costBuy;
        uint256 recvd = retSell;
        assertLt(balAfter, balBefore, "should lose fees");
        uint256 loss = paid - recvd;
        // fee rate from contract is 2% (200 bps) nominal, allow 10 bps wiggle for curvature rounding
        // Expect loss between 3.9% and 4.1% of mid value ~= 2*2% of notional around trade size
        // Use paid as reference since ΔC symmetric aside from fees
        uint256 minLoss = (paid * 390) / 10_000;
        uint256 maxLoss = (paid * 410) / 10_000;
        assertGe(loss, minLoss, "loss too small");
        assertLe(loss, maxLoss, "loss too big");
    }
}
