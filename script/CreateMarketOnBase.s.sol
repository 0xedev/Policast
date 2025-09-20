// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CreateMarketOnBase is Script {
    // Base mainnet contract address
    address constant POLICAST_CONTRACT = 0x8aCAa80590bf3d8f419568a241c88C7791136B8C;
    
    function run() external {
        // Get environment variables
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address bettingToken = vm.envAddress("BETTING_TOKEN");
        string memory rpcUrl = vm.envString("RPC_URL");
        
        address deployer = vm.addr(deployerKey);
        
        console2.log("=== Base Mainnet Market Creation ===");
        console2.log("Deployer:", deployer);
        console2.log("Policast Contract:", POLICAST_CONTRACT);
        console2.log("Betting Token:", bettingToken);
        console2.log("RPC URL:", rpcUrl);
        
        // Connect to the existing contract
        PolicastMarketV3 policast = PolicastMarketV3(POLICAST_CONTRACT);
        IERC20 token = IERC20(bettingToken);
        
        // Check if we can interact with contracts
        console2.log("Checking contract connectivity...");
        
        // Check deployer's token balance with error handling
        uint256 balance;
        try token.balanceOf(deployer) returns (uint256 bal) {
            balance = bal;
            console2.log("Deployer token balance:", balance);
        } catch {
            console2.log("Warning: Could not check token balance - token might not be accessible");
            console2.log("Continuing with market creation attempt...");
            balance = type(uint256).max; // Assume sufficient balance for testing
        }
        
        uint256 initialLiquidity = 1000 ether; // 1000 tokens as specified
        
        if (balance != type(uint256).max) {
            require(balance >= initialLiquidity, "Insufficient token balance for market creation");
        }
        
        vm.startBroadcast(deployerKey);
        
        // Check current allowance with error handling
        uint256 currentAllowance;
        try token.allowance(deployer, POLICAST_CONTRACT) returns (uint256 allowance) {
            currentAllowance = allowance;
            console2.log("Current allowance:", currentAllowance);
        } catch {
            console2.log("Warning: Could not check token allowance");
            currentAllowance = 0;
        }
        
        // Approve tokens if needed
        if (currentAllowance < initialLiquidity) {
            console2.log("Approving tokens for market creation...");
            try token.approve(POLICAST_CONTRACT, initialLiquidity) returns (bool approveSuccess) {
                require(approveSuccess, "Token approval failed");
                console2.log("Approved", initialLiquidity, "tokens for market creation");
            } catch {
                console2.log("Warning: Token approval failed - this might be expected in a dry run");
            }
        } else {
            console2.log("Sufficient allowance already exists");
        }
        
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
        bool earlyResolutionAllowed = true;
        
        console2.log("Creating market with parameters:");
        console2.log("Question:", question);
        console2.log("Description:", description);
        console2.log("Duration (seconds):", duration);
        console2.log("Initial Liquidity:", initialLiquidity);
        console2.log("Early Resolution Allowed:", earlyResolutionAllowed);
        
        // Create the market
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
        
        console2.log("Market created successfully!");
        console2.log("Market ID:", marketId);
        
        // Verify market creation by fetching market info
        (
            string memory retrievedQuestion,
            string memory retrievedDescription,
            uint256 endTime,
            PolicastMarketV3.MarketCategory retrievedCategory,
            uint256 optionCount,
            bool resolved,
            PolicastMarketV3.MarketType retrievedMarketType,
            bool invalidated,
            uint256 totalVolume
        ) = policast.getMarketBasicInfo(marketId);
        
        console2.log("--- Market Verification ---");
        console2.log("Retrieved Question:", retrievedQuestion);
        console2.log("Retrieved Description:", retrievedDescription);
        console2.log("End Time (timestamp):", endTime);
        console2.log("Category:", uint8(retrievedCategory));
        console2.log("Option Count:", optionCount);
        console2.log("Market Type:", uint8(retrievedMarketType));
        console2.log("Resolved:", resolved);
        console2.log("Invalidated:", invalidated);
        console2.log("Total Volume:", totalVolume);
        
        // Get option details
        for (uint256 i = 0; i < optionCount; i++) {
            (
                string memory optionName,
                string memory optionDesc,
                uint256 totalShares,
                uint256 optionVolume,
                uint256 currentPrice,
                bool isActive
            ) = policast.getMarketOption(marketId, i);
            
            console2.log("--- Option", i, "---");
            console2.log("Name:", optionName);
            console2.log("Description:", optionDesc);
            console2.log("Current Price:", currentPrice);
            console2.log("Is Active:", isActive);
            console2.log("Total Shares:", totalShares);
            console2.log("Total Volume:", optionVolume);
        }
        
        // Calculate end time in human readable format
        uint256 currentTime = block.timestamp;
        uint256 timeUntilEnd = endTime - currentTime;
        console2.log("Current timestamp:", currentTime);
        console2.log("Time until market ends (seconds):", timeUntilEnd);
        console2.log("Market ends in approximately", timeUntilEnd / 3600, "hours");
        
        vm.stopBroadcast();
        
        console2.log("\n=== MARKET CREATION SUMMARY ===");
        console2.log("Network: Base Mainnet");
        console2.log("Policast Contract:", POLICAST_CONTRACT);
        console2.log("Betting Token:", bettingToken);
        console2.log("Market ID:", marketId);
        console2.log("Question:", question);
        console2.log("Initial Liquidity:", initialLiquidity);
        console2.log("Market successfully created on Base mainnet!");
        
        // Provide next steps
        console2.log("\n=== NEXT STEPS ===");
        console2.log("1. Market ID", marketId, "is now live on Base mainnet");
        console2.log("2. Users can now trade on this market");
        console2.log("3. Market will end at timestamp:", endTime);
        console2.log("4. You can resolve the market after it ends using the resolver role");
    }
}