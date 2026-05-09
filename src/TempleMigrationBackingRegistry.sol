// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract TempleMigrationBackingRegistry {
    address public owner;
    uint256 internal activeFlag;
    bytes32 public environmentId;
    address public monitoredTarget;
    address public responseExecutor;

    event ConfigUpdated(bytes32 environmentId, address monitoredTarget, address responseExecutor, bool active);

    error OnlyOwner();
    error ZeroAddress();

    constructor(bytes32 environmentId_, address monitoredTarget_, address responseExecutor_, bool active_) {
        owner = msg.sender;
        _setConfig(environmentId_, monitoredTarget_, responseExecutor_, active_);
    }

    function setConfig(bytes32 environmentId_, address monitoredTarget_, address responseExecutor_, bool active_) external {
        if (msg.sender != owner) revert OnlyOwner();
        _setConfig(environmentId_, monitoredTarget_, responseExecutor_, active_);
    }

    function active() external view returns (bool) {
        return activeFlag == 1;
    }

    function getConfig() external view returns (bool, bytes32, address, address) {
        return (activeFlag == 1, environmentId, monitoredTarget, responseExecutor);
    }

    function _setConfig(bytes32 environmentId_, address monitoredTarget_, address responseExecutor_, bool active_) internal {
        if (environmentId_ == bytes32(0) || monitoredTarget_ == address(0) || responseExecutor_ == address(0)) {
            revert ZeroAddress();
        }
        environmentId = environmentId_;
        monitoredTarget = monitoredTarget_;
        responseExecutor = responseExecutor_;
        activeFlag = active_ ? 1 : 0;
        emit ConfigUpdated(environmentId_, monitoredTarget_, responseExecutor_, active_);
    }
}
