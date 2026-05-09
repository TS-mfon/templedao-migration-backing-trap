// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct EventFilter {
    address contractAddress;
    string signature;
}

interface ITrap {
    function collect() external view returns (bytes memory);
    function eventLogFilters() external pure returns (EventFilter[] memory);
    function shouldRespond(bytes[] calldata data) external pure returns (bool, bytes memory);
    function shouldAlert(bytes[] calldata data) external pure returns (bool, bytes memory);
}
