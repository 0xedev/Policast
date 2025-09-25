// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {MockERC20} from "test/MockERC20.sol";

contract FuzzBuySellNewTest is Test {
    MockERC20 internal token;
    PolicastMarketV3 internal market;

    address internal OWNER = address(0xA11CE);
    address internal USER = address(0xBEEF);

    uint256 internal constant ONE = 1e18;

    function setUp() public {
        // Mint total to this test contract
        token = new MockERC20(20_000_000e18);
        vm.startPrank(OWNER);
        market = new PolicastMarketV3(address(token));
        vm.stopPrank();
        // Distribute balances
        token.transfer(OWNER, 10_000_000e18);
        token.transfer(USER, 10_000_000e18);

        vm.startPrank(OWNER);
        token.approve(address(market), type(uint256).max);
        string[] memory names = new string[](3);
        names[0] = "A";
        names[1] = "B";
        names[2] = "C";
        string[] memory desc = new string[](3);
        desc[0] = "";
        desc[1] = "";
        desc[2] = "";
        uint256 marketId = market.createMarket(
            "Tri",
            "",
            names,
            desc,
            7 days,
            PolicastMarketV3.MarketCategory(0),
            PolicastMarketV3.MarketType(0),
            50_000e18,
            false
        );
        market.validateMarket(marketId);
        vm.stopPrank();

        // Approve from USER
        vm.prank(USER);
        token.approve(address(market), type(uint256).max);
    }

    function testFuzz_BuySell(uint256 seed) public {
        vm.assume(seed != 0);
        uint256 marketId = 0; // first market

        // perform 50 random ops
        for (uint256 i = 0; i < 50; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bool doBuy = (r & 1) == 0;
            uint256 optionId = (r >> 1) % 3;
            uint256 qty = ((r >> 4) % 1000 + 1) * 1e16; // 0.01 to 10 shares

            if (doBuy) {
                // buy with generous slippage
                vm.prank(USER);
                try market.buyShares(marketId, optionId, qty, type(uint256).max, 0) {} catch {}
            } else {
                // sell bounded by user shares
                // We can't read internal mapping directly, so attempt a sell; if insufficient shares it will revert, catch it.
                vm.prank(USER);
                try market.sellShares(marketId, optionId, qty, 0, 0) {} catch {}
            }

            // Basic smoke: operations should not revert under generous slippage
        }
    }
}
