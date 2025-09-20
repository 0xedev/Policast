// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "test/MockERC20.sol";

contract MarketLifecycleTest is Test {
    PolicastMarketV3 market;
    MockERC20 token;

    address owner = address(0xABCD);
    address resolver = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    bytes32 internal constant QUESTION_CREATOR_ROLE = keccak256("QUESTION_CREATOR_ROLE");
    bytes32 internal constant QUESTION_RESOLVE_ROLE = keccak256("QUESTION_RESOLVE_ROLE");
    bytes32 internal constant MARKET_VALIDATOR_ROLE = keccak256("MARKET_VALIDATOR_ROLE");

    function setUp() public {
        vm.startPrank(owner);
        token = new MockERC20(3_000_000 ether); // owner receives full supply
        market = new PolicastMarketV3(address(token));
        // distribute to alice & bob
        token.transfer(alice, 1_000_000 ether);
        token.transfer(bob, 1_000_000 ether);
        // give roles
        market.grantQuestionCreatorRole(owner);
        market.grantQuestionResolveRole(resolver);
        market.grantMarketValidatorRole(owner);
        vm.stopPrank();
        // approve
        vm.prank(owner);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);
        vm.prank(bob);
        token.approve(address(market), type(uint256).max);
    }

    function _createAndValidate(bool early) internal returns (uint256 id) {
        string[] memory names = new string[](2);
        names[0] = "Yes";
        names[1] = "No";
        string[] memory desc = new string[](2);
        desc[0] = "Y";
        desc[1] = "N";
        vm.prank(owner);
        id = market.createMarket(
            "Q?",
            "Desc",
            names,
            desc,
            2 days,
            PolicastMarketV3.MarketCategory.OTHER,
            PolicastMarketV3.MarketType.PAID,
            200_000 ether,
            early
        );
        vm.prank(owner);
        market.validateMarket(id);
    }

    function testUnauthorizedResolveReverts() public {
        uint256 id = _createAndValidate(false);
        // fast-forward after end so only auth matters
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(abi.encodeWithSelector(PolicastMarketV3.NotAuthorized.selector));
        market.resolveMarket(id, 0);
    }

    function testEarlyResolveNotAllowedRevertsBeforeEnd() public {
        uint256 id = _createAndValidate(false); // earlyResolutionAllowed = false
        // before endTime
        vm.expectRevert(abi.encodeWithSelector(PolicastMarketV3.MarketNotEndedYet.selector));
        vm.prank(owner); // owner has resolve role? Only explicit resolver role or owner allowed
        market.resolveMarket(id, 0);
    }

    function testEarlyResolveAllowedStillTooSoonRevertsWithinFirstHour() public {
        uint256 id = _createAndValidate(true); // early allowed
        // Give resolver role already set; attempt before 1 hour passes
        vm.expectRevert(abi.encodeWithSelector(PolicastMarketV3.MarketTooNew.selector));
        vm.prank(resolver);
        market.resolveMarket(id, 0);
    }

    function testEarlyResolveAllowedAfterOneHourBeforeEndSucceeds() public {
        uint256 id = _createAndValidate(true);
        vm.warp(block.timestamp + 1 hours + 1); // pass safety window
        vm.prank(resolver);
        market.resolveMarket(id, 1);
        // second resolve should revert
        vm.expectRevert(abi.encodeWithSelector(PolicastMarketV3.MarketAlreadyResolved.selector));
        vm.prank(resolver);
        market.resolveMarket(id, 1);
    }

    function testClaimFlowAndGuards() public {
        uint256 id = _createAndValidate(false);
        // Provide some trades so users own shares in winning option.
        // Need to wait until after end for resolution since earlyResolutionAllowed=false
        // Buy shares after validation
        vm.prank(alice);
        market.buyShares(id, 0, 1e16, type(uint256).max, 0);
        vm.prank(bob);
        market.buyShares(id, 1, 2e16, type(uint256).max, 0);
        // Fast forward past end time
        vm.warp(block.timestamp + 3 days);
        // Resolve choosing option 0 as winner (alice wins)
        vm.prank(owner); // owner has NotAuthorized? Owner passes authorization check
        market.resolveMarket(id, 0);
        // Bob has no winning shares
        vm.expectRevert(abi.encodeWithSelector(PolicastMarketV3.NoWinningShares.selector));
        vm.prank(bob);
        market.claimWinnings(id);
        // Alice claims
        uint256 balBefore = token.balanceOf(alice);
        vm.prank(alice);
        market.claimWinnings(id);
        uint256 balAfter = token.balanceOf(alice);
        assertGt(balAfter, balBefore, "Alice must receive winnings");
        // Double claim
        vm.expectRevert(abi.encodeWithSelector(PolicastMarketV3.AlreadyClaimed.selector));
        vm.prank(alice);
        market.claimWinnings(id);
    }
}
