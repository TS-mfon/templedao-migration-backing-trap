// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    ITempleMigrationBackingRegistry,
    ITempleMigrationEmergency,
    ITempleTelegramAlertSink
} from "./ITempleMigrationBacking.sol";
import {TempleTypes} from "./TempleTypes.sol";

contract TempleMigrationRiskResponse {
    address public immutable DROSERA_CALLER;
    ITempleMigrationBackingRegistry public immutable REGISTRY;
    ITempleTelegramAlertSink public immutable TELEGRAM_ALERT_SINK;
    uint256 public immutable COOLDOWN_BLOCKS;
    uint256 public lastHandledBlock;

    event PauseAttempted(address indexed target, bool success, bytes returnData);
    event IncidentHandled(
        bytes32 indexed invariantId,
        bytes32 indexed environmentId,
        address indexed target,
        uint256 blockNumber,
        bytes32 reasonBitmap
    );

    error ZeroAddress();
    error OnlyDrosera();
    error WrongInvariant();
    error WrongEnvironment();
    error WrongTarget();
    error WrongResponseExecutor();
    error RegistryInactive();
    error CooldownActive();
    error PauseFailed(bytes returnData);

    constructor(address droseraCaller_, address registry_, address telegramAlertSink_, uint256 cooldownBlocks_) {
        if (droseraCaller_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        DROSERA_CALLER = droseraCaller_;
        REGISTRY = ITempleMigrationBackingRegistry(registry_);
        TELEGRAM_ALERT_SINK = ITempleTelegramAlertSink(telegramAlertSink_);
        COOLDOWN_BLOCKS = cooldownBlocks_;
    }

    function handleIncident(TempleTypes.Incident calldata incident) external {
        if (msg.sender != DROSERA_CALLER) revert OnlyDrosera();
        if (incident.invariantId != TempleTypes.INVARIANT_ID) revert WrongInvariant();
        if (!REGISTRY.active()) revert RegistryInactive();
        if (incident.environmentId != REGISTRY.environmentId()) revert WrongEnvironment();
        if (incident.target != REGISTRY.monitoredTarget()) revert WrongTarget();
        if (REGISTRY.responseExecutor() != address(this)) revert WrongResponseExecutor();
        if (lastHandledBlock != 0 && block.number < lastHandledBlock + COOLDOWN_BLOCKS) revert CooldownActive();

        (bool success, bytes memory returnData) = incident.target.call(abi.encodeCall(ITempleMigrationEmergency.emergencyPause, ()));
        emit PauseAttempted(incident.target, success, returnData);
        if (!success) revert PauseFailed(returnData);

        lastHandledBlock = block.number;
        if (address(TELEGRAM_ALERT_SINK) != address(0)) {
            TELEGRAM_ALERT_SINK.notifyTempleIncident(incident);
        }

        emit IncidentHandled(
            incident.invariantId,
            incident.environmentId,
            incident.target,
            incident.blockNumber,
            incident.reasonBitmap
        );
    }
}
