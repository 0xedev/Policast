// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {PolicastMarketV3} from "src/Policast.sol";
import {PolicastViews} from "src/PolicastViews.sol";

contract DeployPolicast is Script {
    // Role identifiers (must match the contract's expectations)
    bytes32 internal constant QUESTION_CREATOR_ROLE = keccak256("QUESTION_CREATOR_ROLE");
    bytes32 internal constant QUESTION_RESOLVE_ROLE = keccak256("QUESTION_RESOLVE_ROLE");
    bytes32 internal constant MARKET_VALIDATOR_ROLE = keccak256("MARKET_VALIDATOR_ROLE");

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY"); // required

        address bettingToken = vm.envAddress("BETTING_TOKEN");

        vm.startBroadcast(deployerKey);
        PolicastMarketV3 policast = new PolicastMarketV3(bettingToken);
        vm.stopBroadcast();

        console2.log("PolicastMarketV3 deployed:", address(policast));

        vm.startBroadcast(deployerKey);
        PolicastViews views = new PolicastViews(address(policast));
        vm.stopBroadcast();

        console2.log("PolicastViews deployed:", address(views));
    }

    // -------------------- Internal Helpers --------------------
    function _envAddressOrZero(string memory key) internal view returns (address) {
        try vm.envAddress(key) returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }

    function _envUintOr(string memory key, uint256 defVal) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return defVal;
        }
    }

    function _envBool(string memory key) internal view returns (bool) {
        try vm.envString(key) returns (string memory v) {
            bytes32 h = keccak256(bytes(v));
            return h == keccak256("1") || h == keccak256("true") || h == keccak256("TRUE");
        } catch {
            return false;
        }
    }
}
