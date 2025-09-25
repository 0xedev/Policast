// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {PolicastViews} from "src/PolicastViews.sol";
import {MockERC20} from "test/MockERC20.sol";

// Verifies that after an extreme concentrated buy, non-target probabilities do not collapse to exact zero
// due to the probability floor introduced in LMSRMathPRB.
contract ExtremeConcentrationFloorTest is Test {
	PolicastMarketV3 internal market;
	PolicastViews internal views;
	MockERC20 internal token;

	address internal owner = address(0xABCD);
	address internal whale = address(0xDEAD);

	uint256 internal constant INITIAL_SUPPLY = 50_000_000 ether;
	uint256 internal constant ONE = 1e18;

	function setUp() public {
		vm.startPrank(owner);
		token = new MockERC20(INITIAL_SUPPLY);
		market = new PolicastMarketV3(address(token));
		views = new PolicastViews(address(market));
		market.grantQuestionCreatorRole(owner);
		market.grantMarketValidatorRole(owner);
		vm.stopPrank();

		vm.prank(owner); token.transfer(whale, 10_000_000 ether);
		vm.prank(whale); token.approve(address(market), type(uint256).max);
		vm.prank(owner); token.approve(address(market), type(uint256).max);
	}

	function testExtremeConcentrationMaintainsFloor() public {
		uint256 optionCount = 5;
		uint256 marketId = _createMarket(optionCount, 500_000 ether);
		uint256 target = 2;

		// Whale performs very large buy to push distribution to extreme
		uint256 hugeQty = 10_000 * ONE; // 10k shares
		vm.prank(whale);
		market.buyShares(marketId, target, hugeQty, type(uint256).max, 0);

		// Probabilities post-buy
		uint256 sum;
		uint256 minProb = type(uint256).max;
		uint256 maxProb;
		for (uint256 i = 0; i < optionCount; i++) {
			uint256 p = views.calculateCurrentPrice(marketId, i);
			sum += p;
			if (p < minProb) minProb = p;
			if (p > maxProb) maxProb = p;
			if (i != target) {
				// Non-target should not be zero
				assertGt(p, 0, "Floor failed: zero prob");
			}
		}
		// Sum stays normalized within small tolerance (5 ppm already enforced in logic but we recheck)
		assertApproxEqAbs(sum, 1e18, 5e12, "Probability sum drift");
		// Distribution should be meaningfully skewed: require maxProb > 0.6 (not necessarily >0.95 after floor compression)
		assertGt(maxProb, 60e16, "Max prob insufficient skew");
		// Min should be > 0 (already), and at least the configured floor (1e-12)
		assertGt(minProb, 1e6 - 1, "Min prob below expected floor");
		emit log_named_uint("Extreme buy maxProb", maxProb);
		emit log_named_uint("Extreme buy minProb", minProb);
	}

	function _createMarket(uint256 optionCount, uint256 initialLiquidity) internal returns (uint256 id) {
		string[] memory names = new string[](optionCount);
		string[] memory descs = new string[](optionCount);
		for (uint256 i = 0; i < optionCount; i++) {
			names[i] = string(abi.encodePacked("OPT", vm.toString(i)));
			descs[i] = names[i];
		}
		vm.startPrank(owner);
		id = market.createMarket(
			"Extreme Concentration",
			"Floor preservation test",
			names,
			descs,
			7 days,
			PolicastMarketV3.MarketCategory.OTHER,
			PolicastMarketV3.MarketType.PAID,
			initialLiquidity,
			false
		);
		market.validateMarket(id);
		vm.stopPrank();
	}
}