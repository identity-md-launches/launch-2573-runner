// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Runner (RUNNER)
/// @notice A fixed supply ERC-20 with 18 decimals, minted entirely to its deployer.
/// @dev When deployed by a factory, the factory receives the supply. There are no
/// administrative powers, external mint/burn entry points, fees, or upgrade paths.
contract Runner is ERC20 {
    /// @notice The entire lifetime supply, expressed in the token's smallest units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("Runner", "RUNNER") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
