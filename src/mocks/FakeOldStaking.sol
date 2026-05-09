// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract FakeOldStaking {
    event FakeMigrateWithdraw(address indexed user, uint256 amount);

    function migrateWithdraw(address user, uint256 amount) external {
        emit FakeMigrateWithdraw(user, amount);
    }
}
