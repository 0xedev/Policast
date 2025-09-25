// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol"; // use console2 for more stable logging overloads
import {PolicastMarketV3} from "src/Policast.sol";
import {PolicastViews} from "src/PolicastViews.sol";
import {MockERC20} from "test/MockERC20.sol";
import {UD60x18} from "lib/prb-math/src/ud60x18/ValueType.sol";

// Focus: Create markets with 5 and 6 options, repeatedly buy a single option
// and track (log + assert) probability & token price movements for all options
// across sequential concentrated buys.
contract MultiOptionConcentrationPathTest is Test {
    PolicastMarketV3 internal market;
    PolicastViews internal views;
    MockERC20 internal token;

    address internal owner = address(0x1111);
    address internal trader = address(0x2222);

    uint256 internal constant INITIAL_SUPPLY = 10_000_000_000_000_000 ether;
    uint256 internal constant TRADER_FUNDS = 2_000_000_000_000 ether;
    uint256 internal constant ONE = 1e18;
    uint256 internal constant PAYOUT_PER_SHARE = 100 * 1e18; // must mirror contract constant
    uint256 internal constant PROB_EPS = 5e12; // 5 ppm tolerance for sum

    bytes32 internal constant QUESTION_CREATOR_ROLE = keccak256("QUESTION_CREATOR_ROLE");
    bytes32 internal constant MARKET_VALIDATOR_ROLE = keccak256("MARKET_VALIDATOR_ROLE");

    function setUp() public {
        vm.startPrank(owner);
        token = new MockERC20(INITIAL_SUPPLY);
        market = new PolicastMarketV3(address(token));
        views = new PolicastViews(address(market));
        market.grantQuestionCreatorRole(owner);
        market.grantMarketValidatorRole(owner);
        vm.stopPrank();

        // Fund trader
        vm.prank(owner); token.transfer(trader, TRADER_FUNDS);
        vm.prank(trader); token.approve(address(market), type(uint256).max);
        vm.prank(owner); token.approve(address(market), type(uint256).max);
    }

    struct StepSnapshot {
        uint256 cost;              // tokens paid (including fee)
        uint256[] probs;           // probabilities (sum ~ 1e18)
        uint256[] tokenPrices;     // probability * 100 (scaled 1e18)
        int256 unrealizedPnL;      // aggregate unrealized PnL after step (from views)
        int256 realizedPnL;        // realized PnL (should stay 0 for only buys)
        uint256 cumulativeCost;    // sum of total costs paid so far (includes fee)
        int256 expectedUnrealized; // locally recomputed expected unrealized PnL
    }

    function testConcentratedBuysFiveOptions() public {
        uint256 marketId = _createMarket(5, 300_000 ether); // sizeable initial liquidity
        uint256 targetOption = 2; // concentrate on middle option for clarity
        uint256 buys = 6;
        uint256 quantityPerBuy = 10000 * ONE; // 10 shares each step

        StepSnapshot[] memory steps = _executeConcentratedBuys(marketId, 5, targetOption, buys, quantityPerBuy);
        _assertMonotonicPath(steps, targetOption, 5, quantityPerBuy);
        _logPath("5-option market", steps, targetOption);
    }

    function testConcentratedBuysSixOptions() public {
        // Adaptive test: analytically estimate required shares to reach 95% cap, then buy in several steps.
        uint256 optionCount = 6;
        uint256 marketId = _createMarket(optionCount, 300_000 ether); // moderate initial liquidity keeps b smaller => fewer shares needed
        uint256 targetOption = 4; // arbitrary non-edge index
        uint256 CAP = 950000000000000000; // 0.95 * 1e18
        uint256 TOL = 1e6; // 1e-12 tolerance band

        // Fetch LMSR b (share units 1e18 scaled)
        uint256 b = market.getMarketLMSRB(marketId);

        // Required shares q to achieve p=CAP (softmax with others 0):
        // p = 1 / (1 + (n-1) * exp(-q/b)) => exp(-q/b) = (1-p)/(p*(n-1)) => q = -b * ln((1-p)/(p*(n-1)))
        // All quantities are 1e18 scaled. We'll compute ratio scaled (1e18) then ln via PRB-Math UD60x18.
    uint256 num = CAP * (optionCount - 1); // p*(n-1)
    uint256 den = ONE - CAP;              // (1-p)
    // ratio' = (p*(n-1))/(1-p) >= 1 for p>=1/n ; ensures ln input >= 1
    uint256 ratioPrime = (num * ONE) / den; // 1e18 scaled
    require(ratioPrime >= ONE, "ratioPrime<1");
    uint256 lnRatioPrime = UD60x18.unwrap(UD60x18.wrap(ratioPrime).ln()); // ln(ratio') positive
    // From derivation: q = b * ln( (p*(n-1))/(1-p) )
    uint256 qNeeded = (b * lnRatioPrime) / ONE;
        // Add a 1% safety margin to ensure we cross the natural softmax threshold so cap logic triggers
        qNeeded = (qNeeded * 101) / 100;
        // Split into at most 5 equal(ish) buys to observe path dynamics
        uint256 stepsTarget = 5;
        uint256 quantityPerBuy = qNeeded / stepsTarget;
        if (quantityPerBuy == 0) quantityPerBuy = 1e18; // at least 1 share unit
        // Round up so total >= qNeeded
        if (quantityPerBuy * stepsTarget < qNeeded) {
            quantityPerBuy += 1e18 - (quantityPerBuy % 1e18);
        }

        // Execute buys until cap reached or max steps
        StepSnapshot[] memory rawSteps = _executeConcentratedBuys(marketId, optionCount, targetOption, stepsTarget, quantityPerBuy);
        // Determine actual number of steps used to reach cap (cap may be reached early)
        uint256 reachedIndex = stepsTarget - 1;
        for (uint256 i = 0; i < rawSteps.length; i++) {
            if (rawSteps[i].probs[targetOption] >= CAP - TOL) { reachedIndex = i; break; }
        }
        // Trim array if cap reached early
        StepSnapshot[] memory steps = new StepSnapshot[](reachedIndex + 1);
        for (uint256 i = 0; i <= reachedIndex; i++) steps[i] = rawSteps[i];

        // Assertions: final probability at cap within tolerance; others roughly equal sharing remaining 5%
        uint256 finalProb = steps[steps.length - 1].probs[targetOption];
        require(finalProb >= CAP - TOL && finalProb <= CAP + TOL, "Target not capped");
        uint256 remaining = ONE - finalProb; // ~5%
        uint256 expectedEach = remaining / (optionCount - 1);
        for (uint256 i = 0; i < optionCount; i++) {
            if (i == targetOption) continue;
            uint256 p = steps[steps.length - 1].probs[i];
            // difference tolerance: allow 2e6 (2 * 1e-12)
            uint256 diff = p > expectedEach ? p - expectedEach : expectedEach - p;
            require(diff <= 2e6, "Non-target imbalance");
        }
        _logPath("6-option adaptive cap path", steps, targetOption);
    }

    // --- Internal Helpers ---

    function _createMarket(uint256 optionCount, uint256 initialLiquidity) internal returns (uint256 id) {
        string[] memory names = new string[](optionCount);
        string[] memory descs = new string[](optionCount);
        for (uint256 i = 0; i < optionCount; i++) {
            names[i] = string(abi.encodePacked("OPT", vm.toString(i)));
            descs[i] = names[i];
        }
        vm.startPrank(owner);
        id = market.createMarket(
            string(abi.encodePacked("Concentration Test ", vm.toString(optionCount), " opts")),
            "Sequential concentrated buys",
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

    function _executeConcentratedBuys(
        uint256 marketId,
        uint256 optionCount,
        uint256 targetOption,
        uint256 buys,
        uint256 quantityPerBuy
    ) internal returns (StepSnapshot[] memory steps) {
        steps = new StepSnapshot[](buys);
        uint256 cumulativeCost;
        for (uint256 i = 0; i < buys; i++) {
            uint256 balBefore = token.balanceOf(trader);
            vm.prank(trader);
            market.buyShares(marketId, targetOption, quantityPerBuy, type(uint256).max, 0);
            uint256 balAfter = token.balanceOf(trader);
            uint256 cost = balBefore - balAfter;
            // Snapshot probabilities & token prices
            uint256[] memory probs = new uint256[](optionCount);
            uint256[] memory tokenPrices = new uint256[](optionCount);
            uint256 sum;
            for (uint256 j = 0; j < optionCount; j++) {
                uint256 p = views.calculateCurrentPrice(marketId, j); // probability scaled 1e18
                probs[j] = p;
                tokenPrices[j] = (p * PAYOUT_PER_SHARE) / ONE;
                sum += p;
            }
            // Basic sanity: use uint256 overload (sum, expected, absTolerance)
            assertApproxEqAbs(sum, ONE, PROB_EPS, "Probability sum drift");
            require(cost > 0, "Zero cost buy (unexpected)");
            cumulativeCost += cost;
            // Fetch fresh unrealized PnL via view (portfolio mapping value may lag until explicit update in core logic)
            int256 unrealized = views.calculateUnrealizedPnL(trader);
            (, , int256 storedUnrealized, int256 realized,) = market.userPortfolios(trader);
            // Sanity: stored unrealized should either be zero (not actively updated on buys) or close to view value
            if (storedUnrealized != 0) {
                int256 dd = storedUnrealized - unrealized; if (dd < 0) dd = -dd; require(uint256(dd) < 1e14, "Stored unrealized diverges");
            }
            // Recompute expected unrealized PnL for single-position scenario
            uint256 userShares = market.getMarketOptionUserShares(marketId, targetOption, trader);
            uint256 prob = probs[targetOption];
            // mark value = shares * prob * payout / 1e36
            uint256 markValue = (userShares * prob / 1e18) * PAYOUT_PER_SHARE / 1e18;
            int256 expectedUnrealized = int256(markValue) - int256(cumulativeCost);
            // Allow small rounding difference (<= 5 ppm of markValue or 1e12 absolute whichever larger)
            int256 diff = unrealized - expectedUnrealized;
            if (diff < 0) diff = -diff;
            uint256 tol = markValue / 200000; // 5 ppm
            if (tol < 1e12) tol = 1e12;
            require(uint256(diff) <= tol, "Unrealized PnL mismatch");
            steps[i] = StepSnapshot({
                cost: cost,
                probs: probs,
                tokenPrices: tokenPrices,
                unrealizedPnL: unrealized,
                realizedPnL: realized,
                cumulativeCost: cumulativeCost,
                expectedUnrealized: expectedUnrealized
            });
        }
    }

    function _assertMonotonicPath(
        StepSnapshot[] memory steps,
        uint256 targetOption,
        uint256 optionCount,
        uint256 quantityPerBuy
    ) internal pure {
        // Target option probability must strictly increase until it hits ~95% cap, then remain within tolerance band
        uint256 CAP = 950000000000000000; // 0.95 * 1e18
        uint256 TOL = 1e6; // 1e-12 tolerance
        bool reachedCap;
        for (uint256 i = 1; i < steps.length; i++) {
            uint256 prev = steps[i-1].probs[targetOption];
            uint256 curr = steps[i].probs[targetOption];
            if (!reachedCap) {
                if (curr + TOL >= CAP) {
                    require(curr >= prev, "Cap transition decreased");
                    reachedCap = true;
                    uint256 diffCap = curr > CAP ? curr - CAP : CAP - curr;
                    require(diffCap <= TOL, "Cap overshoot");
                } else {
                    assertGt(curr, prev, "Target probability not increasing pre-cap");
                }
            } else {
                // After cap: non-decreasing and stays in [CAP-TOL, CAP+TOL]
                require(curr + TOL >= CAP && curr <= CAP + TOL, "Post-cap outside band");
                require(curr >= prev, "Post-cap decreased");
            }
        }
        // Other options should not increase materially (> small jitter) — allow 1e6 slack (1e-12 absolute)
        uint256 slack = 1e6; // absolute probability slack (1e-12 scaled)
        for (uint256 i = 1; i < steps.length; i++) {
            for (uint256 j = 0; j < optionCount; j++) {
                if (j == targetOption) continue;
                uint256 prevO = steps[i-1].probs[j];
                uint256 currO = steps[i].probs[j];
                if (!reachedCap) {
                    require(currO + slack <= prevO + slack, "Non-target increased pre-cap");
                } else {
                    // After cap reached we allow stabilization or slight increase (redistribution) but cap at 1 - (CAP - slack)
                    require(currO <= ONE - (CAP - slack), "Non-target exceeded remaining mass");
                }
            }
        }
        // Extended assertions:
        // 1. Sum of tokenPrices should ~ PAYOUT_PER_SHARE within PAYOUT_PER_SHARE * PROB_EPS / 1e18
        uint256 payoutScaled = 100 * 1e18; // matches PAYOUT_PER_SHARE / (1e18 / 1)
        uint256 tokenPriceTolerance = (payoutScaled * 5e12) / 1e18; // reuse 5 ppm
        for (uint256 i = 0; i < steps.length; i++) {
            uint256 sumTP;
            for (uint256 j = 0; j < optionCount; j++) {
                sumTP += steps[i].tokenPrices[j];
            }
            // tokenPrices are probability * 100, so sum should equal 100e18 exactly (small rounding tolerated)
            assertApproxEqAbs(sumTP, payoutScaled, tokenPriceTolerance, "Token price sum drift");
        }
        // 2. Target tokenPrice strictly increases until cap; then constant within tolerance
        bool priceCapped;
        for (uint256 i = 1; i < steps.length; i++) {
            uint256 prevTP = steps[i-1].tokenPrices[targetOption];
            uint256 currTP = steps[i].tokenPrices[targetOption];
            if (!priceCapped) {
                if (steps[i].probs[targetOption] + TOL >= CAP) {
                    require(currTP >= prevTP, "Token price decreased at cap");
                    priceCapped = true;
                } else {
                    assertGt(currTP, prevTP, "Target tokenPrice not increasing pre-cap");
                }
            } else {
                require(currTP >= prevTP, "Post-cap token price decreased");
            }
        }
        // 3. Marginal per-share cost should be non-decreasing (rounding may keep equal occasionally)
        for (uint256 i = 1; i < steps.length; i++) {
            uint256 prevMarginal = (steps[i-1].cost * 1e18) / quantityPerBuy; // scaled 1e18
            uint256 currMarginal = (steps[i].cost * 1e18) / quantityPerBuy;
            require(currMarginal >= prevMarginal, "Marginal cost decreased");
        }
        // 4. Realized PnL must remain zero (only buys)
        for (uint256 i = 0; i < steps.length; i++) {
            require(steps[i].realizedPnL == 0, "Realized PnL changed on buys only path");
        }
        // 5. Unrealized PnL behavior:
        //    Pre-cap: additional buys should not reduce unrealized PnL (since probability still rising)
        //    Post-cap: probability pinned; marginal cost can exceed mark value (95 * payout), so unrealized PnL can decline.
        //    Enforce: once cap reached, unrealized PnL must be non-increasing (allow tiny rounding jitter).
        bool capReachedInUnrealized;
        for (uint256 i = 1; i < steps.length; i++) {
            if (!capReachedInUnrealized) {
                // Detect cap by probability plateau (price movement already validated above). If plateau triggers earlier logic, reachedCap was set.
                // Here we approximate: if target token price difference <= tolerance we treat as plateau only if >= 0.95 - TOL.
                // Simpler: if target probability >= 0.95e18 - 1e6 treat as cap reached.
                if (steps[i-1].probs[targetOption] >= 950000000000000000 - 1e6) {
                    capReachedInUnrealized = true;
                }
            }
            if (!capReachedInUnrealized) {
                require(steps[i].unrealizedPnL + 1e12 >= steps[i-1].unrealizedPnL, "Unrealized PnL decreased pre-cap");
            } else {
                require(steps[i].unrealizedPnL <= steps[i-1].unrealizedPnL + 1e12, "Unrealized PnL increased post-cap (unexpected)");
            }
        }
    }

    function _format1e18(uint256 x) internal pure returns (string memory) {
        // Render with two decimals: intPart.decPart (truncated)
        uint256 intPart = x / 1e18;
        uint256 twoDec = (x % 1e18) / 1e16; // two decimal digits
        bytes memory dec;
        if (twoDec < 10) {
            dec = abi.encodePacked("0", _toString(twoDec));
        } else {
            dec = abi.encodePacked(_toString(twoDec));
        }
        return string(abi.encodePacked(_toString(intPart), ".", dec));
    }

    function _toString(uint256 v) internal pure returns (string memory) {
        // Simple itoa (minimal) to avoid vm.toString in pure fn
        if (v == 0) return "0";
        uint256 temp = v;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (v != 0) { digits -= 1; buffer[digits] = bytes1(uint8(48 + uint256(v % 10))); v /= 10; }
        return string(buffer);
    }

    function _logPath(string memory label, StepSnapshot[] memory steps, uint256 targetOption) internal pure {
        console2.log("=== Concentrated Buy Path ===");
        console2.log(label);
        console2.log("Target Option", targetOption);
        for (uint256 i = 0; i < steps.length; i++) {
            console2.log("Step", i);
            console2.log("  Cost (tokens, full wei)", steps[i].cost);
            console2.log("  Cost (tokens, 2dp)", _format1e18(steps[i].cost));
            for (uint256 j = 0; j < steps[i].probs.length; j++) {
                console2.log("  Opt", j);
                console2.log("    prob(1e18)", steps[i].probs[j]);
                console2.log("    prob(2dp)", _format1e18(steps[i].probs[j]));
                console2.log("    tokenPrice(1e18)", steps[i].tokenPrices[j]);
                console2.log("    tokenPrice(2dp)", _format1e18(steps[i].tokenPrices[j]));
            }
            console2.log("  unrealizedPnL", steps[i].unrealizedPnL);
            console2.log("  realizedPnL", steps[i].realizedPnL);
        }
    }
}
