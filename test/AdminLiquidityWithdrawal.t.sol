// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Policast.sol";
import "../src/PolicastViews.sol";
import "../test/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AdminLiquidityWithdrawalTest is Test {
    PolicastMarketV3 public policast;
    MockERC20 public token;
    PolicastViews public views;

    address public owner = address(0x1);
    address public creator = address(0x2);
    address public user = address(0x3);

    function setUp() public {
        vm.startPrank(owner);

        // Deploy token and policast
        token = new MockERC20(100000 * 1e18); // Owner gets all tokens initially
    policast = new PolicastMarketV3(address(token));
    views = new PolicastViews(address(policast));

        // Grant roles
        policast.grantQuestionCreatorRole(creator);
        policast.grantMarketValidatorRole(owner);
        policast.grantQuestionResolveRole(owner);

        // Transfer tokens to users
        token.transfer(creator, 20000 * 1e18);
        token.transfer(user, 20000 * 1e18);

        vm.stopPrank();
    }

    function testWithdrawAdminLiquidityAfterResolution() public {
        uint256 initialLiquidity = 5000 * 1e18;

        // Create market
        vm.startPrank(creator);
        token.approve(address(policast), initialLiquidity);

        string[] memory optionNames = new string[](2);
        optionNames[0] = "Yes";
        optionNames[1] = "No";

        string[] memory optionDescriptions = new string[](2);
        optionDescriptions[0] = "Yes description";
        optionDescriptions[1] = "No description";

        uint256 marketId = policast.createMarket(
            "Test Question?",
            "Test Description",
            optionNames,
            optionDescriptions,
            7 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            initialLiquidity,
            false
        );
        vm.stopPrank();

        // Validate market
        vm.prank(owner);
        policast.validateMarket(marketId);

        // Try to withdraw before resolution (should fail)
        vm.prank(creator);
        vm.expectRevert(PolicastMarketV3.MarketNotReady.selector);
        policast.withdrawAdminLiquidity(marketId);

        // Fast forward past market end
        vm.warp(block.timestamp + 8 days);

        // Resolve market
        vm.prank(owner);
        policast.resolveMarket(marketId, 0);

    // Skip querying removed getter; rely on actual withdrawal effects

        // Record creator balance before withdrawal
        uint256 balanceBefore = token.balanceOf(creator);

        // Withdraw admin liquidity
        vm.prank(creator);
        policast.withdrawAdminLiquidity(marketId);

        // Check balance increased
        uint256 balanceAfter = token.balanceOf(creator);
        assertEq(balanceAfter - balanceBefore, initialLiquidity);

        // Check can't withdraw again
        vm.prank(creator);
        vm.expectRevert(PolicastMarketV3.AdminLiquidityAlreadyClaimed.selector);
        policast.withdrawAdminLiquidity(marketId);

    // Removed withdrawable getter assertion (moved to views returning conservative 0)
    }

    function testWithdrawAdminLiquidityAfterInvalidation() public {
        uint256 initialLiquidity = 3000 * 1e18;

        // Create market
        vm.startPrank(creator);
        token.approve(address(policast), initialLiquidity);

        string[] memory optionNames = new string[](2);
        optionNames[0] = "Yes";
        optionNames[1] = "No";

        string[] memory optionDescriptions = new string[](2);
        optionDescriptions[0] = "Yes description";
        optionDescriptions[1] = "No description";

        uint256 marketId = policast.createMarket(
            "Test Question?",
            "Test Description",
            optionNames,
            optionDescriptions,
            7 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            initialLiquidity,
            false
        );
        vm.stopPrank();

        // Record creator balance before invalidation
        uint256 balanceBefore = token.balanceOf(creator);

        // Invalidate market (this should auto-refund in current implementation)
        vm.prank(owner);
        policast.invalidateMarket(marketId);

        // Balance should have increased due to auto-refund in invalidateMarket
        uint256 balanceAfterInvalidation = token.balanceOf(creator);
        assertEq(balanceAfterInvalidation - balanceBefore, initialLiquidity);

    // Removed withdrawable assertion; refund effect validated via balance delta
    }

    function testEmergencyWithdraw() public {
        uint256 withdrawAmount = 1000 * 1e18;

        // Transfer some tokens to contract
        vm.prank(creator);
        token.transfer(address(policast), withdrawAmount);

        // Check contract balance
        uint256 contractBalance = token.balanceOf(address(policast));
        assertGe(contractBalance, withdrawAmount);

        // Record owner balance
        uint256 ownerBalanceBefore = token.balanceOf(owner);

        // Emergency withdraw (only owner can call)
        vm.prank(owner);
        policast.emergencyWithdraw(withdrawAmount);

        // Check owner balance increased
        uint256 ownerBalanceAfter = token.balanceOf(owner);
        assertEq(ownerBalanceAfter - ownerBalanceBefore, withdrawAmount);

        // Test non-owner cannot call
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        policast.emergencyWithdraw(100 * 1e18);

        // Test cannot withdraw more than contract balance
        // Add some tokens back to contract first
        vm.prank(creator);
        token.transfer(address(policast), 500 * 1e18);

        vm.prank(owner);
        vm.expectRevert(PolicastMarketV3.InsufficientContractBalance.selector);
        policast.emergencyWithdraw(600 * 1e18); // Try to withdraw more than available
    }

    function testOnlyCreatorCanWithdrawAdminLiquidity() public {
        uint256 initialLiquidity = 3000 * 1e18; // Increased to meet minimum requirement

        // Create market
        vm.startPrank(creator);
        token.approve(address(policast), initialLiquidity);

        string[] memory optionNames = new string[](2);
        optionNames[0] = "Yes";
        optionNames[1] = "No";

        string[] memory optionDescriptions = new string[](2);
        optionDescriptions[0] = "Yes description";
        optionDescriptions[1] = "No description";

        uint256 marketId = policast.createMarket(
            "Test Question?",
            "Test Description",
            optionNames,
            optionDescriptions,
            7 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            initialLiquidity,
            false
        );
        vm.stopPrank();

        // Validate and resolve market
        vm.prank(owner);
        policast.validateMarket(marketId);

        vm.warp(block.timestamp + 8 days);

        vm.prank(owner);
        policast.resolveMarket(marketId, 0);

        // Test that user cannot withdraw creator's liquidity
        vm.prank(user);
        vm.expectRevert(PolicastMarketV3.NotAuthorized.selector);
        policast.withdrawAdminLiquidity(marketId);

        // Test that owner cannot withdraw creator's liquidity
        vm.prank(owner);
        vm.expectRevert(PolicastMarketV3.NotAuthorized.selector);
        policast.withdrawAdminLiquidity(marketId);

        // Creator can withdraw
        vm.prank(creator);
        policast.withdrawAdminLiquidity(marketId);
    }
}
