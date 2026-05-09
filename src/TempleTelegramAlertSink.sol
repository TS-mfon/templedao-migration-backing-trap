// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITempleTelegramAlertSink} from "./ITempleMigrationBacking.sol";
import {TempleTypes} from "./TempleTypes.sol";

contract TempleTelegramAlertSink is ITempleTelegramAlertSink {
    address public immutable RESPONSE;

    event TelegramAlertRequested(
        bytes32 indexed invariantId,
        bytes32 indexed environmentId,
        address indexed target,
        uint256 blockNumber,
        uint256 creditedStake,
        uint256 tokenBacking,
        address lastMigrationOldStaking,
        address lastMigrator,
        uint256 lastMigrationAmount,
        uint256 lastBackingBefore,
        uint256 lastBackingAfter,
        bytes32 reasonBitmap
    );

    error OnlyResponse();
    error ZeroAddress();

    constructor(address response_) {
        if (response_ == address(0)) revert ZeroAddress();
        RESPONSE = response_;
    }

    function notifyTempleIncident(TempleTypes.Incident calldata incident) external {
        if (msg.sender != RESPONSE) revert OnlyResponse();
        emit TelegramAlertRequested(
            incident.invariantId,
            incident.environmentId,
            incident.target,
            incident.blockNumber,
            incident.creditedStake,
            incident.tokenBacking,
            incident.lastMigrationOldStaking,
            incident.lastMigrator,
            incident.lastMigrationAmount,
            incident.lastBackingBefore,
            incident.lastBackingAfter,
            incident.reasonBitmap
        );
    }
}
