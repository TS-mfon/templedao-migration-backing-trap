// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TempleTypes} from "./TempleTypes.sol";

interface ITempleMigrationBackingRegistry {
    function active() external view returns (bool);
    function environmentId() external view returns (bytes32);
    function monitoredTarget() external view returns (address);
    function responseExecutor() external view returns (address);
    function getConfig() external view returns (bool, bytes32, address, address);
}

interface ITempleMigrationBackingMetrics {
    function templeMigrationMetrics() external view returns (TempleTypes.Metrics memory);
}

interface ITempleMigrationEmergency {
    function emergencyPause() external;
}

interface ITempleTelegramAlertSink {
    function notifyTempleIncident(TempleTypes.Incident calldata incident) external;
}
