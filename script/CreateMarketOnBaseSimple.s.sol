// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CreateMarketOnBaseSimple is Script {
    // Base mainnet contract address
    address constant POLICAST_CONTRACT = 0x8aCAa80590bf3d8f419568a241c88C7791136B8C;
    
    function run() external {
        // Get environment variables
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address bettingToken = vm.envAddress("BETTING_TOKEN");
        
        address deployer = vm.addr(deployerKey);
        
        console2.log("=== Base Mainnet Market Creation (Simple) ===");
        console2.log("Deployer:", deployer);
        console2.log("Policast Contract:", POLICAST_CONTRACT);
        console2.log("Betting Token:", bettingToken);
        
        // Connect to contracts
        PolicastMarketV3 policast = PolicastMarketV3(POLICAST_CONTRACT);
        IERC20 token = IERC20(bettingToken);
        
        vm.startBroadcast(deployerKey);
        
        // Market parameters
        string memory question = "Will Russia and Ukraine announce a ceasefire?";
        string memory description = "Test market for ceasefire announcement.";
        string[] memory optionNames = new string[](2);
        optionNames[0] = "Yes";
        optionNames[1] = "No";
        
        string[] memory optionDescriptions = new string[](2);
        optionDescriptions[0] = "Yes outcome";
        optionDescriptions[1] = "No outcome";
        
        uint256 duration = 604800; // 7 days in seconds
        PolicastMarketV3.MarketCategory category = PolicastMarketV3.MarketCategory.POLITICS; // 0
        PolicastMarketV3.MarketType marketType = PolicastMarketV3.MarketType.PAID; // 0
        uint256 initialLiquidity = 1000 ether; // 1000 tokens
        bool earlyResolutionAllowed = true;
        
        console2.log("Market parameters:");
        console2.log("Question:", question);
        console2.log("Initial Liquidity:", initialLiquidity);
        
        // Approve tokens (this will be the actual transaction)
        console2.log("Approving tokens...");
        token.approve(POLICAST_CONTRACT, initialLiquidity);
        
        // Create the market (this will be the main transaction)
        console2.log("Creating market...");
        uint256 marketId = policast.createMarket(
            question,
            description,
            optionNames,
            optionDescriptions,
            duration,
            category,
            marketType,
            initialLiquidity,
            earlyResolutionAllowed
        );
        
        console2.log("Market created successfully! Market ID:", marketId);
        
        vm.stopBroadcast();
        
        console2.log("\n=== SUCCESS ===");
        console2.log("Market ID:", marketId, "created on Base mainnet");
        console2.log("Contract:", POLICAST_CONTRACT);
    }
}