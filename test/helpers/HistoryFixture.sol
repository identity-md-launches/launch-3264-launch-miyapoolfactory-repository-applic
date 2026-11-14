// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev EIP-2935's raw uint256 calldata / bytes32 return convention, with explicitly seeded history.
///      Used only off-chain; fork tests use the actual deployed history contract.
contract HistoryFixture {
    mapping(uint256 => bytes32) public hashes;

    function set(uint256 number, bytes32 hash) external {
        hashes[number] = hash;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        require(input.length == 32, "history calldata");
        uint256 number = abi.decode(input, (uint256));
        require(number < block.number && block.number - number <= 8191, "history range");
        return abi.encode(hashes[number]);
    }
}
