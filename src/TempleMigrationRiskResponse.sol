// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    ITempleMigrationBackingMetrics,
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
    mapping(bytes32 => bool) public handledIncident;

    event PauseAttempted(address indexed target, bool success, bytes returnData);
    event AlertSinkFailed(bytes32 indexed incidentHash, bytes reason);
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
    error NonActionableIncident();
    error TargetHasNoCode();
    error PauseDidNotTakeEffect();
    error DuplicateIncident();

    bytes32 internal constant ACTIONABLE_REASONS = TempleTypes.REASON_UNBACKED_STAKE
        | TempleTypes.REASON_UNTRUSTED_MIGRATOR
        | TempleTypes.REASON_MIGRATION_WITHOUT_BACKING_INFLOW;

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
        if ((incident.reasonBitmap & ACTIONABLE_REASONS) == bytes32(0)) revert NonActionableIncident();
        if (incident.target.code.length == 0) revert TargetHasNoCode();
        bytes32 incidentHash = _incidentHash(incident);
        if (handledIncident[incidentHash]) revert DuplicateIncident();

        (bool success, bytes memory returnData) = incident.target.call(abi.encodeCall(ITempleMigrationEmergency.emergencyPause, ()));
        emit PauseAttempted(incident.target, success, returnData);
        if (!success) revert PauseFailed(returnData);
        TempleTypes.Metrics memory metrics = ITempleMigrationBackingMetrics(incident.target).templeMigrationMetrics();
        if (!metrics.paused) revert PauseDidNotTakeEffect();

        handledIncident[incidentHash] = true;
        lastHandledBlock = block.number;
        if (address(TELEGRAM_ALERT_SINK) != address(0)) {
            try TELEGRAM_ALERT_SINK.notifyTempleIncident(incident) {}
            catch (bytes memory reason) {
                emit AlertSinkFailed(incidentHash, reason);
            }
        }

        emit IncidentHandled(
            incident.invariantId,
            incident.environmentId,
            incident.target,
            incident.blockNumber,
            incident.reasonBitmap
        );
    }

    function _incidentHash(TempleTypes.Incident calldata incident) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
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
                incident.reasonBitmap,
                keccak256(incident.extraData)
            )
        );
    }
}
