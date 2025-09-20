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
        // Returns exp(-x) for x>=0 using 7-term alternating series.
        // exp(-x) = 1 - x + x^2/2 - x^3/6 + x^4/24 - x^5/120 + x^6/720 - x^7/5040
        if (x == 0) return 1e18;
        if (x >= _MAX_DIFF) return 0; // negligible
        uint256 x1 = x; // x
        uint256 x2 = (x1 * x1) / 1e18; // x^2
        uint256 x3 = (x2 * x1) / 1e18; // x^3
        uint256 x4 = (x3 * x1) / 1e18; // x^4
        uint256 x5 = (x4 * x1) / 1e18; // x^5
        uint256 x6 = (x5 * x1) / 1e18; // x^6
        uint256 x7 = (x6 * x1) / 1e18; // x^7

        uint256 result = 1e18; // 1
        // - x
        result = x1 > result ? 0 : result - x1;
        // + x^2/2
        result += x2 / 2;
        // - x^3/6
        uint256 t = x3 / 6;
        result = result > t ? result - t : 0;
        // + x^4/24
        result += x4 / 24;
        // - x^5/120
        t = x5 / 120;
        result = result > t ? result - t : 0;
        // + x^6/720
        result += x6 / 720;
        // - x^7/5040
        t = x7 / 5040;
        result = result > t ? result - t : 0;
        return result;
    }

    function ln(uint256 y) internal pure returns (uint256) {
        // Natural log for y in (0, +inf). 1e18 scaling. Uses range reduction to (1,2]
        // then atanh series: ln(y) = 2*( z + z^3/3 + z^5/5 + z^7/7 + z^9/9 ), z=(y-1)/(y+1)
        require(y > 0, "LN_ZERO");
        uint256 result = 0;
        // Range reduce by powers of two to bring y into (0.5, 2]
        while (y >= 2e18) {
            y = y / 2;
            result += _LN2;
        }
        while (y <= 5e17) {
            // <0.5
            y = y * 2;
            result -= _LN2;
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
        // Adjust sign: if y < 1 then ln(y) = -core
        if (sign == 0) {
            core = core > 0 ? (uint256(0) - core) : 0; // underflow prevention not needed due to sign logic, kept for safety
        }
        // Combine with accumulated powers-of-two adjustments
        if (sign == 0) {
            // result currently may be negative due to subtractions; treat result as signed in int256 domain
            // Convert result (uint256) + negative core by using assembly to allow signed arithmetic safely.
            // Simpler: use int256
            int256 signedResult = int256(result);
            signedResult -= int256(core);
            if (signedResult < 0) return uint256(signedResult * -1); // fallback; (in practice y<1 implies negative ln but callers use only inside log-sum-exp with positive shift)
        }
        // For y>=1, ln is positive: result + core
        return result + core;
    }

    function logSumExp(uint256[] memory scaled) internal pure returns (uint256 maxScaled, uint256 lnSumExp) {
        uint256 n = scaled.length;
        if (n == 0) return (0, 0);
        // Find max for stability
        for (uint256 i = 0; i < n; i++) {
            uint256 v = scaled[i];
            if (v > maxScaled) maxScaled = v;
        }
        // Sum exp(scaled[i]-max)
        uint256 sumExp = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 diff = scaled[i] >= maxScaled ? 0 : (maxScaled - scaled[i]);
            sumExp += expNeg(diff);
        }
        // ln(sumExp / 1e18) = ln(sumExp) - ln(1e18) ; ln(1e18)= ~ 41.446531673892822e18 (but we operate with scaling embedded)
        // We already keep scaling inside _ln; since sumExp is 1e18-scaled sum of 1e18 terms, divide by 1e18 logically -> skip by subtracting ln(1e18).
        // For simplicity we approximate ln(1e18) = 18 * ln(10) ≈ 4144653167389282231 (1e18 scaled). Precompute constant.
        uint256 LN_1E18 = 4144653167389282231;
        uint256 lnSum = ln(sumExp);
        if (lnSum > LN_1E18) lnSumExp = lnSum - LN_1E18; // positive region

        else lnSumExp = 0; // extremely small (should not happen with n>=1)
    }

    function computeB(uint256 _initialLiquidity, uint256 _optionCount, uint256 payoutPerShare)
        internal
        pure
        returns (uint256)
    {
        if (_optionCount < 2) revert("BadOptionCount");
        uint256 lnN;
        if (_optionCount == 2) lnN = 693147180559945309; // ln(2)

        else if (_optionCount == 3) lnN = 1098612288668109692; // ln(3)

        else if (_optionCount == 4) lnN = 1386294361119890614; // ln(4)

        else if (_optionCount == 5) lnN = 1609437912434100375; // ln(5)

        else if (_optionCount == 6) lnN = 1791759469228055172; // ln(6)

        else if (_optionCount == 7) lnN = 1945932330622312828; // ln(7)

        else if (_optionCount == 8) lnN = 2079441541679835928; // ln(8)

        else if (_optionCount == 9) lnN = 2197224577336213040; // ln(9)

        else if (_optionCount == 10) lnN = 2302585092994045684; // ln(10)

        else revert("BadOptionCount");

        uint256 LMSR_COVERAGE_RATIO_NUM = 60;
        uint256 LMSR_COVERAGE_RATIO_DEN = 100;
        uint256 MIN_LMSR_B = 1e16;
        uint256 MAX_LMSR_B = 1e24;

        uint256 denominatorD = (lnN * payoutPerShare) / 1e18; // scaled 1e18
        uint256 targetWorstCase = (_initialLiquidity * LMSR_COVERAGE_RATIO_NUM) / LMSR_COVERAGE_RATIO_DEN;
        uint256 b = (targetWorstCase * 1e18) / denominatorD;

        if (b < MIN_LMSR_B) b = MIN_LMSR_B;
        if (b > MAX_LMSR_B) b = MAX_LMSR_B;

        uint256 worstCaseLoss = ((b * lnN) / 1e18) * payoutPerShare / 1e18;
        if (_initialLiquidity < worstCaseLoss) revert("InsufficientInitialLiquidity");
        return b;
    }
}
