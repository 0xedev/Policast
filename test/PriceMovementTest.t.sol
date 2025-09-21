// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Policast.sol";
import "../src/PolicastViews.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    event Transfer(address indexed from, address indexed to, uint256 value);
    
    constructor() {
        balanceOf[msg.sender] = 10000000 * 1e18;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        require(balanceOf[from] >= amount, "Insufficient balance");
        
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract PriceMovementTest is Test {
    PolicastMarketV3 public policast;
    PolicastViews public views;
    MockERC20 public token;
    
    event PriceLog(string action, uint256 optionA, uint256 optionB, uint256 optionC, uint256 total);
    
    function setUp() public {
        token = new MockERC20();
        policast = new PolicastMarketV3(address(token));
        views = new PolicastViews(address(policast));
        
        token.approve(address(policast), type(uint256).max);
    }
    
    function test_PriceMovements() public {
        // Create a 3-option market
        string[] memory options = new string[](3);
        options[0] = "Option A";
        options[1] = "Option B"; 
        options[2] = "Option C";
        
        string[] memory descriptions = new string[](3);
        descriptions[0] = "Description A";
        descriptions[1] = "Description B";
        descriptions[2] = "Description C";
        
        uint256 marketId = policast.createMarket(
            "3 Option Market",
            "Test description", 
            options,
            descriptions,
            86400, // 1 day
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            10000 * 1e18, // Initial liquidity
            false
        );
        
        policast.validateMarket(marketId);
        
        // Check initial prices
        console.log("=== Initial Prices ===");
        logAllPrices(marketId, "Initial");
        
        console.log("=== Buy 1 share of Option A ===");
        policast.buyShares(marketId, 0, 100 * 1e18, type(uint256).max, 0);
        logAllPrices(marketId, "After buying 1 A");
        
        console.log("=== Buy 2 shares of Option B ===");
        policast.buyShares(marketId, 1, 20 * 1e18, type(uint256).max, 0);
        logAllPrices(marketId, "After buying 2 B");
        
        console.log("=== Buy 3 shares of Option C ===");
        policast.buyShares(marketId, 2, 350 * 1e18, type(uint256).max, 0);
        logAllPrices(marketId, "After buying 3 C");
        
        console.log("=== Final Summary ===");
        uint256 priceA = views.calculateCurrentPrice(marketId, 0);
        uint256 priceB = views.calculateCurrentPrice(marketId, 1);
        uint256 priceC = views.calculateCurrentPrice(marketId, 2);
        uint256 total = priceA + priceB + priceC;
        
        console.log("Final prices:");
        console.log("Option A:", priceA / 1e18, "tokens");
        console.log("Option B:", priceB / 1e18, "tokens");  
        console.log("Option C:", priceC / 1e18, "tokens");
        console.log("Total:", total / 1e18, "tokens");
        
        // Verify total is exactly 100 tokens
        assertEq(total, 100 * 1e18, "Total should be exactly 100 tokens");
    }
    
    function logAllPrices(uint256 marketId, string memory action) internal {
        uint256 priceA = views.calculateCurrentPrice(marketId, 0);
        uint256 priceB = views.calculateCurrentPrice(marketId, 1);
        uint256 priceC = views.calculateCurrentPrice(marketId, 2);
        uint256 total = priceA + priceB + priceC;
        
        console.log("Action:", action);
        console.log("  A:", priceA / 1e15, "/1000 tokens"); // Show with more precision
        console.log("  B:", priceB / 1e15, "/1000 tokens");
        console.log("  C:", priceC / 1e15, "/1000 tokens");
        console.log("  Total:", total / 1e18, "tokens");
        console.log("---");
        
        emit PriceLog(action, priceA, priceB, priceC, total);
    }
}