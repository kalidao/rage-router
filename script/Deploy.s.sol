// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.15;

import {Script} from "forge-std/Script.sol";

import {RageRouter} from "src/RageRouter.sol";

/// @notice A very simple deployment script
contract Deploy is Script {

  /// @notice The main script entrypoint
  /// @return router The deployed contract
  function run() external returns (RageRouter router) {
    vm.startBroadcast();
    router = new RageRouter();
    vm.stopBroadcast();
  }
}