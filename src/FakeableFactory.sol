// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";

/// FakeableFactory — deploys wrapped-token instances as beacon proxies over the
/// shared implementation beacon (one beacon upgrade upgrades every instance).
/// The factory itself is unprivileged: anyone may create a wrapper for an
/// underlying; the BEACON's owner is the upgrade admin.
contract FakeableFactory {
    UpgradeableBeacon public immutable beacon;
    address[] public wrappers;

    event WrapperCreated(address indexed proxy, address indexed underlying);

    constructor(UpgradeableBeacon beacon_) {
        beacon = beacon_;
    }

    /// initData is the derived implementation's initializer encoding (e.g.
    /// `initialize(underlying, name, symbol, admin)`); the underlying is fixed at
    /// creation and can never change (the base's init-once guard).
    function createWrapper(bytes memory initData, address underlying_) external returns (address proxy) {
        proxy = address(new BeaconProxy(address(beacon), initData));
        wrappers.push(proxy);
        emit WrapperCreated(proxy, underlying_);
    }

    function wrapperCount() external view returns (uint256) {
        return wrappers.length;
    }
}
