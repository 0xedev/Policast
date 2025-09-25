// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library LMSRMath {
    // ===================== LMSR HELPERS (Improved Precision) =====================
    // Implements stable log-sum-exp based LMSR cost with higher-order series for exp(-x)
    // and a symmetric series (atanh form) for ln(x) around 1 for improved precision.
    // All values use 1e18 fixed point scaling.

    uint256 private constant _LN2 = 693147180559945309; // ln(2) * 1e18
    uint256 private constant _MAX_DIFF = 80e18; // beyond this exp(-x) is < ~1e-35 -> negligible

    function expNeg(uint256 x) internal pure returns (uint256) {
        // Returns exp(-x) for x>=0 using alternating series with signed accumulation.
        // exp(-x) ≈ 1 - x + x^2/2 - x^3/6 + x^4/24 - x^5/120 + x^6/720 - x^7/5040 + ...
        // All terms use 1e18 fixed-point scaling. This implementation preserves monotonicity
        // for the domain we use in LMSR (diffs typically in [0, ~2]).
        if (x == 0) return 1e18;
        if (x >= _MAX_DIFF) return 0; // negligible for our purposes

        // Precompute powers: x, x^2, x^3, ... with scaling at each step
        uint256 x1 = x; // x
        uint256 x2 = (x1 * x1) / 1e18; // x^2
        uint256 x3 = (x2 * x1) / 1e18; // x^3
        uint256 x4 = (x3 * x1) / 1e18; // x^4
        uint256 x5 = (x4 * x1) / 1e18; // x^5
        uint256 x6 = (x5 * x1) / 1e18; // x^6
        uint256 x7 = (x6 * x1) / 1e18; // x^7

        // Use signed accumulator to avoid clamping errors when x > 1e18
        int256 acc = int256(1e18);
        acc -= int256(x1); // - x
        acc += int256(x2) / 2; // + x^2/2
        acc -= int256(x3) / 6; // - x^3/6
        acc += int256(x4) / 24; // + x^4/24
        acc -= int256(x5) / 120; // - x^5/120
        acc += int256(x6) / 720; // + x^6/720
        acc -= int256(x7) / 5040; // - x^7/5040

        if (acc <= 0) return 0; // underflow to ~0
        return uint256(acc);
    }

    function ln(uint256 y) internal pure returns (int256) {
        // Natural log for y in (0, +inf). 1e18 scaling. Uses range reduction to (1,2]
        // then atanh series: ln(y) = 2*( z + z^3/3 + z^5/5 + z^7/7 + z^9/9 ), z=(y-1)/(y+1)
        require(y > 0, "LN_ZERO");
        // Note: Removed require(y >= 1e18) to support full range

        int256 result = 0;
        // Range reduce by powers of two to bring y into (0.5, 2]
        while (y >= 2e18) {
            y = y / 2;
            result += int256(_LN2);
        }
        while (y <= 5e17) {
            // <0.5 - now this branch is reachable
            y = y * 2;
            result -= int256(_LN2);
        }
        // Now y in (0.5,2]; use series centered at 1
        // z = (y-1)/(y+1)
        uint256 numerator = y > 1e18 ? y - 1e18 : (1e18 - y); // abs(y-1)
        uint256 sign = y >= 1e18 ? 1 : 0;
        uint256 denom = y + 1e18;
        uint256 z = (numerator * 1e18) / denom; // |z|
        // Compute z + z^3/3 + z^5/5 + z^7/7 + z^9/9
        uint256 z2 = (z * z) / 1e18; // z^2
        uint256 z3 = (z2 * z) / 1e18; // z^3
        uint256 z5 = (z3 * z2) / 1e18; // z^5
        uint256 z7 = (z5 * z2) / 1e18; // z^7
        uint256 z9 = (z7 * z2) / 1e18; // z^9
        uint256 series = z;
        series += z3 / 3;
        series += z5 / 5;
        series += z7 / 7;
        series += z9 / 9;
        uint256 core = (series * 2); // multiply by 2 (still 1e18 scaled)

        // Combine with accumulated powers-of-two adjustments using signed arithmetic
        if (sign == 0) {
            // y < 1, so ln(y) < 0
            result -= int256(core);
        } else {
            // y >= 1, so ln(y) >= 0
            result += int256(core);
        }

        // Convert back to uint256, handling negative results appropriately
        return result; // signed natural log (1e18 scaled)
    }

    function logSumExp(uint256[] memory scaled) internal pure returns (uint256 maxScaled, uint256 lnSumExp) {
        uint256 n = scaled.length;
        if (n == 0) return (0, 0);
        for (uint256 i = 0; i < n; i++) {
            uint256 v = scaled[i];
            if (v > maxScaled) maxScaled = v;
        }
        uint256 sumExp = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 diff = scaled[i] >= maxScaled ? 0 : (maxScaled - scaled[i]);
            uint256 e = expNeg(diff); // 1e18 scaled
            sumExp += e; // safe for n<=10
        }
        // sumExp is sum of 1e18-scaled exponentials. Need ln(sumExp/1e18).
        // ln(1e18) = 18 * ln(10) ≈ 41.446531673892822312 * 1e18
        // Correct 1e18-scaled constant:
        int256 LN_1E18 = 41446531673892822312;
        int256 lnSum = ln(sumExp); // signed
        // lnSumExp can be negative (e.g., when maxScaled >> others and n small)
        int256 diff = lnSum - LN_1E18; // still 1e18 scaled, could be <0
        if (diff < 0) {
            // Encode negative using two's complement cast via uint256 then rely on caller to treat as signed? Simpler: clamp to 0 to avoid under-estimation bias.
            // However clamping distorts probabilities; instead return 0 when negative magnitude is tiny. If large negative, return 0 to avoid underflow.
            // For precision we allow negative by storing sign externally: but existing interface expects uint256.
            // Given downstream just adds maxScaled + lnSumExp (both uint), negative would underflow. So fallback to 0.
            lnSumExp = 0;
        } else {
            lnSumExp = uint256(diff);
        }
    }

    function computeB(uint256 _initialLiquidity, uint256 _optionCount, uint256 payoutPerShare)
        internal
        pure
        returns (uint256)
    {
        if (_optionCount < 2) revert("BadOptionCount");
        if (_optionCount > 10) revert("UnsupportedOptionCount");
        if (_initialLiquidity == 0) revert("ZeroLiquidity");
        if (payoutPerShare == 0) revert("ZeroPayoutPerShare");

        // Target: platform should initially allow buying ~5% of payout on one outcome
        // before probability shifts by more than a few points.
        // Classic LMSR guidance: choose b roughly = (initial bankroll) / ln(n)
        // We treat initialLiquidity as bankroll (already 1e18 scaled tokens).
        // Convert tokens to share units: divide by payoutPerShare, then scale back to 1e18.
        // b_shares = (initialLiquidity * 1e18 / payoutPerShare) / ln(n)
        // Use fixed ln(n) approximation for n<=10.
        uint256 lnN;
        if (_optionCount == 2) lnN = 693147180559945309; // ln(2)

        else if (_optionCount == 3) lnN = 1098612288668109692; // ln(3)

        else if (_optionCount == 4) lnN = 1386294361119890648; // ln(4)

        else if (_optionCount == 5) lnN = 1609437912434100375; // ln(5)

        else if (_optionCount == 6) lnN = 1783378370508591168; // ln(6)

        else if (_optionCount == 7) lnN = 1922703101705143167; // ln(7)

        else if (_optionCount == 8) lnN = 2037421927016425482; // ln(8)

        else if (_optionCount == 9) lnN = 2133745237141597423; // ln(9)

        else lnN = 2218487496163563680; // ln(10)

        // sharesEquivalent = initialLiquidity / payoutPerShare (both 1e18 scaled) => (initialLiquidity * 1e18) / payoutPerShare
        uint256 sharesEquivalent = (_initialLiquidity * 1e18) / payoutPerShare;
        // b_shares = sharesEquivalent / lnN  (both 1e18 scaled)
        uint256 bShares = (sharesEquivalent * 1e18) / lnN;

        // Safety clamp: ensure b not absurdly small or huge
        if (bShares < 10e18) bShares = 10e18;
        if (bShares > 10_000_000e18) bShares = 10_000_000e18;
        return bShares;
    }
}
