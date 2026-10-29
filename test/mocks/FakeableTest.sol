// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {FakeableERC20} from "../../src/FakeableERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// Minimal concrete wrapper for tests: owner-gated fake minting.
contract FakeableTest is FakeableERC20 {
    address public owner;

    function initialize(string memory name_, string memory symbol_, IERC20 underlying_) external initializer {
        owner = msg.sender;
        __FakeableERC20_init(name_, symbol_, underlying_);
    }

    function _authorizeFakeMint(address caller) internal view override returns (bool) {
        return caller == owner;
    }
}
