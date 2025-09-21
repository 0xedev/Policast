// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Policast.sol";
import "../src/PolicastViews.sol";
import "./MockERC20.sol";

contract PriceCostAnalysisTest is Test {
    PolicastMarketV3 policast;
    PolicastViews policastViews;
    MockERC20 token;
    address alice = address(0x1);
    uint256 constant INITIAL_LIQUIDITY = 10000 * 1e18;

    // Events to replace console.log usage (console.log with printf-like formatting isn't available)
    event LogString(string message);
    event TradeLog(string action, uint256 tradeIndex, uint256 price, uint256 value, uint256 avgPrice);
    event PriceLog(string option, uint256 price);

    function setUp() public {
         token = new MockERC20(3_000_000 ether); 
        policast = new PolicastMarketV3(address(token));
        policastViews = new PolicastViews(address(policast));
        // token.mint(address(this), INITIAL_LIQUIDITY);
        token.approve(address(policast), type(uint256).max);
        vm.prank(address(this));
        policast.grantQuestionCreatorRole(address(this));
        vm.prank(address(this));
        policast.grantRole(policast.MARKET_VALIDATOR_ROLE(), address(this));
    }

    function test_TwoOptionMarket_PriceVsCost() public {
        string[] memory options = new string[](2);
        options[0] = "Option A";
        options[1] = "Option B";
        string[] memory optionDescriptions = new string[](2);
        optionDescriptions[0] = "Description A";
        optionDescriptions[1] = "Description B";

        uint256 marketId = policast.createMarket(
            "2 Option Market",
            "Test description",
            options,
            optionDescriptions,
            block.timestamp + 1 days,
            PolicastMarketV3.MarketCategory.TECHNOLOGY,
            PolicastMarketV3.MarketType.PAID,
            10000 * 1e18, // 10,000 tokens initial liquidity (more appropriate)
            false
        );

        vm.prank(address(this));
        policast.validateMarket(marketId);

        emit LogString("=== 2-Option Market: Price vs Cost Analysis ===");
        _performTrades(marketId, 0, 5);
    }

    function test_ThreeOptionMarket_PriceVsCost() public {
        string[] memory options = new string[](3);
        options[0] = "Option A";
        options[1] = "Option B";
        options[2] = "Option C";
        string[] memory optionDescriptions = new string[](3);
        optionDescriptions[0] = "Description A";
        optionDescriptions[1] = "Description B";
        optionDescriptions[2] = "Description C";

        uint256 marketId = policast.createMarket(
            "3 Option Market",
            "Test description",
            options,
            optionDescriptions,
            block.timestamp + 1 days,
            PolicastMarketV3.MarketCategory.TECHNOLOGY,
            PolicastMarketV3.MarketType.PAID,
            10000 * 1e18, // 10,000 tokens initial liquidity
            false
        );

        vm.prank(address(this));
        policast.validateMarket(marketId);

        emit LogString("=== 3-Option Market: Price vs Cost Analysis ===");
        _performTrades(marketId, 0, 5);
    }

    function test_FourOptionMarket_PriceVsCost() public {
        string[] memory options = new string[](4);
        options[0] = "Option A";
        options[1] = "Option B";
        options[2] = "Option C";
        options[3] = "Option D";
        string[] memory optionDescriptions = new string[](4);
        optionDescriptions[0] = "Description A";
        optionDescriptions[1] = "Description B";
        optionDescriptions[2] = "Description C";
        optionDescriptions[3] = "Description D";

        uint256 marketId = policast.createMarket(
            "4 Option Market",
            "Test description",
            options,
            optionDescriptions,
            block.timestamp + 1 days,
            PolicastMarketV3.MarketCategory.TECHNOLOGY,
            PolicastMarketV3.MarketType.PAID,
            10000 * 1e18, // 10,000 tokens initial liquidity
            false
        );

        vm.prank(address(this));
        policast.validateMarket(marketId);

        emit LogString("=== 4-Option Market: Price vs Cost Analysis ===");
        _performTrades(marketId, 0, 5);
    }

    function test_FiveOptionMarket_PriceVsCost() public {
        string[] memory options = new string[](5);
        options[0] = "Option A";
        options[1] = "Option B";
        options[2] = "Option C";
        options[3] = "Option D";
        options[4] = "Option E";
        string[] memory optionDescriptions = new string[](5);
        optionDescriptions[0] = "Description A";
        optionDescriptions[1] = "Description B";
        optionDescriptions[2] = "Description C";
        optionDescriptions[3] = "Description D";
        optionDescriptions[4] = "Description E";

        uint256 marketId = policast.createMarket(
            "5 Option Market",
            "Test description",
            options,
            optionDescriptions,
            block.timestamp + 1 days,
            PolicastMarketV3.MarketCategory.TECHNOLOGY,
            PolicastMarketV3.MarketType.PAID,
            10000 * 1e18, // 10,000 tokens initial liquidity
            false
        );

        vm.prank(address(this));
        policast.validateMarket(marketId);

        emit LogString("=== 5-Option Market: Price vs Cost Analysis ===");
        _performTrades(marketId, 0, 5);
    }

    function _performTrades(uint256 marketId, uint256 optionId, uint256 tradeCount) internal {
        uint256 sharesToTrade = 1 * 1e18; // Trade 1 share at a time
        
        // Get number of options for this market
        (, , , , uint256 numOptions, , , ,) = policast.getMarketBasicInfo(marketId);

        // Show initial prices
        _logAllPrices(marketId, numOptions, "Initial");

        emit LogString("--- Buying ---");
        for (uint256 i = 0; i < tradeCount; i++) {
            uint256 price = policastViews.calculateCurrentPrice(marketId, optionId);
            uint256 balanceBefore = token.balanceOf(address(this));
            vm.prank(address(this));
            policast.buyShares(marketId, optionId, sharesToTrade, type(uint256).max, 0);
            uint256 balanceAfter = token.balanceOf(address(this));
            uint256 cost = balanceBefore - balanceAfter;
            emit TradeLog("Buy", i + 1, price, cost, cost * 1e18 / sharesToTrade);
            
            // Show all prices after this buy
            string memory stage = string.concat("After Buy ", _uint256ToString(i + 1));
            _logAllPrices(marketId, numOptions, stage);
        }

        emit LogString("--- Selling ---");
        for (uint256 i = 0; i < tradeCount; i++) {
            uint256 price = policastViews.calculateCurrentPrice(marketId, optionId);
            uint256 balanceBefore = token.balanceOf(address(this));
            vm.prank(address(this));
            policast.sellShares(marketId, optionId, sharesToTrade, 0, 0);
            uint256 balanceAfter = token.balanceOf(address(this));
            uint256 proceeds = balanceAfter - balanceBefore;
            emit TradeLog("Sell", i + 1, price, proceeds, proceeds * 1e18 / sharesToTrade);
            
            // Show all prices after this sell
            string memory stage = string.concat("After Sell ", _uint256ToString(i + 1));
            _logAllPrices(marketId, numOptions, stage);
        }
    }

    function _logAllPrices(uint256 marketId, uint256 numOptions, string memory stage) internal {
        emit LogString(stage);
        for (uint256 i = 0; i < numOptions; i++) {
            uint256 price = policastViews.calculateCurrentPrice(marketId, i);
            string memory optionName = string.concat("Option ", _uint256ToString(i));
            emit PriceLog(optionName, price);
        }
        emit LogString("---");
    }

    function _uint256ToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        
        return string(buffer);
    }
}
