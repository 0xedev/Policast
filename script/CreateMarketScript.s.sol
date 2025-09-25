// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {MockERC20} from "test/MockERC20.sol";

contract CreateMarketScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // Deploy a mock ERC20 token for testing
        MockERC20 token = new MockERC20(1_000_000 ether);
        console2.log("Mock token deployed at:", address(token));
        console2.log("Token balance of deployer:", token.balanceOf(deployer));

        // Deploy Policast contract
        PolicastMarketV3 policast = new PolicastMarketV3(address(token));
        console2.log("Policast deployed at:", address(policast));

        // Grant creator role to deployer (owner already has it by default)
        policast.grantQuestionCreatorRole(deployer);
        console2.log("Granted QUESTION_CREATOR_ROLE to deployer");

        // Approve tokens for market creation
        uint256 initialLiquidity = 1000 ether; // 1000 tokens as specified
        token.approve(address(policast), initialLiquidity);
        console2.log("Approved", initialLiquidity, "tokens for market creation");

        // Create market with specified parameters
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
        PolicastMarketV3.FreeMarketParams memory freeParams =
            PolicastMarketV3.FreeMarketParams({maxFreeParticipants: 0, tokensPerParticipant: 0});

        uint256 marketId = policast.createMarket(
            question,
            description,
            optionNames,
            optionDescriptions,
            duration,
            category,
            marketType,
            initialLiquidity,
            earlyResolutionAllowed,
            freeParams
        );

        console2.log("Market created successfully!");
        console2.log("Market ID:", marketId);
        console2.log("Question:", question);
        console2.log("Description:", description);
        console2.log("Duration (seconds):", duration);
        console2.log("Initial Liquidity:", initialLiquidity);
        console2.log("Early Resolution Allowed:", earlyResolutionAllowed);

        // Get market info to verify creation
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
        console2.log("End Time:", endTime);
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

        vm.stopBroadcast();

        console2.log("\n=== SUMMARY ===");
        console2.log("Policast Contract:", address(policast));
        console2.log("Betting Token:", address(token));
        console2.log("Market ID:", marketId);
        console2.log("Market successfully created with the specified parameters!");
    }
}
