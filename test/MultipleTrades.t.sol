// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/Policast.sol";
import "../src/PolicastViews.sol";
import "./MockERC20.sol";

contract MultipleTradesTest is Test {
    // Precomputed selectors for overloaded functions
    bytes4 private constant BUY_EXT_SIG = bytes4(keccak256("buyShares(uint256,uint256,uint256,uint256,uint256)"));
    bytes4 private constant SELL_EXT_SIG = bytes4(keccak256("sellShares(uint256,uint256,uint256,uint256,uint256)"));
    
    PolicastMarketV3 public market;
    PolicastViews public views;
    MockERC20 public token;

    address creator = address(0xcafE);
    address trader1 = address(0xbEEf1);
    address trader2 = address(0xbEEf2);
    address trader3 = address(0xbEEf3);
    address trader4 = address(0xbEEf4);

    event TradeLog(
        uint256 indexed marketId,
        uint256 indexed optionId,
        address indexed trader,
        string action,
        uint256 quantity,
        uint256 priceA,
        uint256 priceB,
        uint256 step
    );

    function setUp() public {
        token = new MockERC20(10000000 ether);

        vm.prank(creator);
        market = new PolicastMarketV3(address(token));
        views = new PolicastViews(address(market));

        // Fund everyone
        token.transfer(creator, 100000 ether);
        token.transfer(trader1, 10000 ether);
        token.transfer(trader2, 10000 ether);
        token.transfer(trader3, 10000 ether);
        token.transfer(trader4, 10000 ether);

        // Set approvals
        address[] memory traders = new address[](5);
        traders[0] = creator;
        traders[1] = trader1;
        traders[2] = trader2;
        traders[3] = trader3;
        traders[4] = trader4;

        for (uint256 i = 0; i < traders.length; i++) {
            vm.prank(traders[i]);
            token.approve(address(market), type(uint256).max);
        }

        // Grant roles
        vm.startPrank(creator);
        market.grantQuestionCreatorRole(creator);
        market.grantQuestionResolveRole(creator);
        market.grantMarketValidatorRole(creator);
        vm.stopPrank();
    }

    function _logTrade(
        uint256 mId,
        uint256 optId,
        address trader,
        string memory action,
        uint256 quantity,
        uint256 step
    ) internal {
        uint256 priceA = views.calculateCurrentPrice(mId, 0);
        uint256 priceB = views.calculateCurrentPrice(mId, 1);
        emit TradeLog(mId, optId, trader, action, quantity, priceA, priceB, step);
    }

    function _adaptiveBuy(
        uint256 mId,
        uint256 optId,
        address trader,
        uint256 startQty,
        uint256 step
    ) internal returns (uint256) {
        uint256 qty = startQty;
        uint256 executed = 0;
        
        for (uint256 i = 0; i < 12; i++) {
            vm.startPrank(trader);
            (bool ok,) = address(market).call(
                abi.encodeWithSelector(BUY_EXT_SIG, mId, optId, qty, type(uint256).max, 0)
            );
            vm.stopPrank();
            
            if (ok) {
                executed = qty;
                _logTrade(mId, optId, trader, "BUY", qty, step);
                break;
            }
            qty *= 2;
        }
        
        require(executed > 0, "Adaptive buy failed");
        return executed;
    }

    function _adaptiveSell(
        uint256 mId,
        uint256 optId,
        address trader,
        uint256 maxShares,
        uint256 step
    ) internal returns (uint256) {
        uint256 qty = maxShares / 10; // Start with 10% of holdings
        if (qty == 0) qty = maxShares;
        uint256 executed = 0;
        
        for (uint256 i = 0; i < 8 && qty > 0; i++) {
            vm.startPrank(trader);
            (bool ok,) = address(market).call(
                abi.encodeWithSelector(SELL_EXT_SIG, mId, optId, qty, 0, 0)
            );
            vm.stopPrank();
            
            if (ok) {
                executed = qty;
                _logTrade(mId, optId, trader, "SELL", qty, step);
                break;
            }
            qty /= 2;
        }
        
        return executed; // Could be 0 if all attempts failed
    }

    function _getUserShares(uint256 mId, address user, uint256 optId) internal view returns (uint256) {
        return market.getMarketOptionUserShares(mId, optId, user);
    }

    function testIntensiveTrading() public {
        // Create market with high liquidity for stable testing
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "Option A";
        names[1] = "Option B";
        string[] memory descs = new string[](2);
        descs[0] = "First option";
        descs[1] = "Second option";
        
        uint256 mId = market.createMarket(
            "Multiple Trades Test",
            "Testing intensive trading patterns",
            names,
            descs,
            7 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            100000 ether, // High liquidity for b=30
            false
        );
        market.validateMarket(mId);
        vm.stopPrank();

        console.log("=== INTENSIVE TRADING TEST ===");
        console.log("Market ID:", mId);
        console.log("Initial Liquidity: 100,000 ETH");
        console.log("LMSR b parameter:", market.getMarketLMSRB(mId));
        
        // Initial state
        _logTrade(mId, 0, address(0), "INITIAL", 0, 0);

        uint256 step = 1;
        uint256 baseQty = 1e18; // 1 whole share starting quantity

        // Round 1: Multiple traders buy Option A
        console.log("\n--- Round 1: Multiple traders buy Option A ---");
        _adaptiveBuy(mId, 0, trader1, baseQty, step++);
        _adaptiveBuy(mId, 0, trader2, baseQty, step++);
        _adaptiveBuy(mId, 0, trader3, baseQty, step++);
        _adaptiveBuy(mId, 0, trader4, baseQty, step++);

        // Round 2: Some traders buy Option B (counter-movement)
        console.log("\n--- Round 2: Counter-movement on Option B ---");
        _adaptiveBuy(mId, 1, trader1, baseQty * 2, step++);
        _adaptiveBuy(mId, 1, trader2, baseQty * 2, step++);

        // Round 3: Aggressive buying on Option A
        console.log("\n--- Round 3: Aggressive buying on Option A ---");
        _adaptiveBuy(mId, 0, trader3, baseQty * 4, step++);
        _adaptiveBuy(mId, 0, trader4, baseQty * 4, step++);
        _adaptiveBuy(mId, 0, trader1, baseQty * 8, step++);

        // Round 4: Profit taking - some sell Option A
        console.log("\n--- Round 4: Profit taking ---");
        uint256 shares1A = _getUserShares(mId, trader1, 0);
        uint256 shares3A = _getUserShares(mId, trader3, 0);
        
        if (shares1A > 0) _adaptiveSell(mId, 0, trader1, shares1A, step++);
        if (shares3A > 0) _adaptiveSell(mId, 0, trader3, shares3A, step++);

        // Round 5: New wave of buying
        console.log("\n--- Round 5: New wave of buying ---");
        _adaptiveBuy(mId, 1, trader3, baseQty * 6, step++);
        _adaptiveBuy(mId, 1, trader4, baseQty * 6, step++);
        _adaptiveBuy(mId, 0, trader2, baseQty * 3, step++);

        // Round 6: More selling
        console.log("\n--- Round 6: More selling ---");
        uint256 shares2A = _getUserShares(mId, trader2, 0);
        uint256 shares4A = _getUserShares(mId, trader4, 0);
        uint256 shares1B = _getUserShares(mId, trader1, 1);
        
        if (shares2A > 0) _adaptiveSell(mId, 0, trader2, shares2A, step++);
        if (shares4A > 0) _adaptiveSell(mId, 0, trader4, shares4A, step++);
        if (shares1B > 0) _adaptiveSell(mId, 1, trader1, shares1B, step++);

        // Round 7: Final surge
        console.log("\n--- Round 7: Final surge ---");
        _adaptiveBuy(mId, 0, trader1, baseQty * 10, step++);
        _adaptiveBuy(mId, 0, trader2, baseQty * 10, step++);
        _adaptiveBuy(mId, 1, trader3, baseQty * 8, step++);

        // Final state
        console.log("\n--- FINAL STATE ---");
        _logTrade(mId, 0, address(0), "FINAL", 0, step);
        
        uint256 finalPriceA = views.calculateCurrentPrice(mId, 0);
        uint256 finalPriceB = views.calculateCurrentPrice(mId, 1);
        
        console.log("Final Price A:", finalPriceA);
        console.log("Final Price B:", finalPriceB);
        console.log("Price A change from initial 50%:", int256(finalPriceA) - 5e17);
        console.log("Price B change from initial 50%:", int256(finalPriceB) - 5e17);
        
        // Verify prices sum to ~1e18 (100%) after removing 100x scaling
        uint256 totalPrice = finalPriceA + finalPriceB;
        assertApproxEqRel(totalPrice, 1e18, 1e15, "Prices should sum to ~1e18 (100%)"); // 0.1% tolerance
        
        // Verify both prices are positive
        assertGt(finalPriceA, 0, "Price A should be positive");
        assertGt(finalPriceB, 0, "Price B should be positive");
        
        console.log("Total price sum:", totalPrice);
        console.log("Test completed successfully!");
    }

    function testBackAndForthTrading() public {
        // Create a smaller market to see more price sensitivity
        vm.startPrank(creator);
        string[] memory names = new string[](2);
        names[0] = "YES";
        names[1] = "NO";
        string[] memory descs = new string[](2);
        descs[0] = "Yes outcome";
        descs[1] = "No outcome";
        
        uint256 mId = market.createMarket(
            "Back and Forth Test",
            "Testing oscillating trades",
            names,
            descs,
            5 days,
            PolicastMarketV3.MarketCategory.POLITICS,
            PolicastMarketV3.MarketType.PAID,
            50000 ether, // Medium liquidity
            false
        );
        market.validateMarket(mId);
        vm.stopPrank();

        console.log("\n=== BACK AND FORTH TRADING TEST ===");
        console.log("Market ID:", mId);
        console.log("Initial Liquidity: 50,000 ETH");
        console.log("LMSR b parameter:", market.getMarketLMSRB(mId));

        uint256 step = 1;
        uint256 baseQty = 5e18; // 5 whole shares

        // Initial state
        _logTrade(mId, 0, address(0), "INITIAL", 0, 0);

        // Create oscillating pattern
        console.log("\n--- Oscillating Trading Pattern ---");
        
        // Push YES up
        _adaptiveBuy(mId, 0, trader1, baseQty, step++);
        _adaptiveBuy(mId, 0, trader2, baseQty, step++);
        _adaptiveBuy(mId, 0, trader1, baseQty * 2, step++);
        
        // Push NO up (YES down)
        _adaptiveBuy(mId, 1, trader3, baseQty * 3, step++);
        _adaptiveBuy(mId, 1, trader4, baseQty * 3, step++);
        _adaptiveBuy(mId, 1, trader3, baseQty * 2, step++);
        
        // Push YES back up
        _adaptiveBuy(mId, 0, trader2, baseQty * 4, step++);
        _adaptiveBuy(mId, 0, trader4, baseQty * 4, step++);
        
        // Some selling
        uint256 sharesT1YES = _getUserShares(mId, trader1, 0);
        uint256 sharesT3NO = _getUserShares(mId, trader3, 1);
        if (sharesT1YES > 0) _adaptiveSell(mId, 0, trader1, sharesT1YES, step++);
        if (sharesT3NO > 0) _adaptiveSell(mId, 1, trader3, sharesT3NO, step++);
        
        // Final push
        _adaptiveBuy(mId, 1, trader1, baseQty * 5, step++);
        _adaptiveBuy(mId, 0, trader3, baseQty * 6, step++);

        // Final state
        console.log("\n--- OSCILLATION FINAL STATE ---");
        _logTrade(mId, 0, address(0), "FINAL", 0, step);
        
        uint256 finalPriceYES = views.calculateCurrentPrice(mId, 0);
        uint256 finalPriceNO = views.calculateCurrentPrice(mId, 1);
        
        console.log("Final YES Price:", finalPriceYES);
        console.log("Final NO Price:", finalPriceNO);
        
        // Verify market integrity - prices should sum to ~1e18 (100%) after removing 100x scaling
        assertGt(finalPriceYES, 0, "YES price should be positive");
        assertGt(finalPriceNO, 0, "NO price should be positive");
        assertApproxEqRel(finalPriceYES + finalPriceNO, 1e18, 1e15, "Prices should sum to ~1e18 (100%)");
        
        console.log("Back and forth test completed!");
    }
}