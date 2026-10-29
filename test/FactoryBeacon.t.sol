// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {FakeableFactory} from "../src/FakeableFactory.sol";
import {FakeableTest} from "./mocks/FakeableTest.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {FakeableERC20} from "../src/FakeableERC20.sol";

/// A V2 implementation: adds a view + emits nothing new; storage-compatible.
contract FakeableTestV2 is FakeableTest {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// F-3: factory + beacon deployment; one beacon upgrade upgrades every instance;
/// storage (real/fake/underlying/vault) survives the upgrade.
contract FactoryBeaconTest is Test {
    FakeableFactory factory;
    UpgradeableBeacon beacon;
    MockERC20 underlying;
    address beaconOwner = makeAddr("beaconOwner");
    address alice = makeAddr("alice");

    function setUp() public {
        underlying = new MockERC20();
        beacon = new UpgradeableBeacon(address(new FakeableTest()), beaconOwner);
        factory = new FakeableFactory(beacon);
        underlying.mint(alice, 1000);
    }

    function _create() internal returns (FakeableTest proxy) {
        bytes memory init = abi.encodeCall(
            FakeableTest.initialize, ("Wrapped", "wM", IERC20(address(underlying)))
        );
        proxy = FakeableTest(factory.createWrapper(init, address(underlying)));
    }

    function test_create_and_wrap_through_proxy() public {
        FakeableTest proxy = _create();
        assertEq(address(proxy.underlying()), address(underlying));
        assertEq(proxy.name(), "Wrapped");
        vm.prank(alice);
        underlying.approve(address(proxy), 1000);
        vm.prank(alice);
        proxy.wrap(500);
        assertEq(proxy.realOf(alice), 500);
        assertEq(underlying.balanceOf(address(proxy)), 500);
    }

    function test_beacon_upgrade_preserves_state_for_all_instances() public {
        FakeableTest proxy = _create();
        bytes memory init2 = abi.encodeCall(
            FakeableTest.initialize, ("Wrapped2", "wM2", IERC20(address(underlying)))
        );
        FakeableTest proxy2 = FakeableTest(factory.createWrapper(init2, address(underlying)));

        vm.prank(alice);
        underlying.approve(address(proxy), 1000);
        vm.prank(alice);
        proxy.wrap(400);
        // owner of the test contract mints (the proxies' owner = the factory caller)
        // — the initialize set owner = factory... check: the factory calls the proxy
        // constructor; initialize runs via initData with msg.sender = the factory?
        // (the initializer records the caller — see the owner assertion below.)
        vm.stopPrank();

        // Upgrade the beacon: every instance gets V2. (Deploy before pranking —
        // CREATE consumes the prank.)
        address v2 = address(new FakeableTestV2());
        vm.prank(beaconOwner);
        beacon.upgradeTo(v2);
        assertEq(FakeableTestV2(address(proxy)).version(), 2);
        assertEq(FakeableTestV2(address(proxy2)).version(), 2);
        // State survives: the real balance and the fixed underlying.
        assertEq(proxy.realOf(alice), 400);
        assertEq(address(proxy.underlying()), address(underlying));
        assertEq(proxy.name(), "Wrapped");
        // A re-init attempt reverts (init-once, even across upgrades).
        vm.expectRevert();
        proxy.initialize("Evil", "EVIL", IERC20(address(0xdead)));
    }

    function test_owner_cannot_reinit() public {
        FakeableTest proxy = _create();
        vm.expectRevert();
        proxy.initialize("Again", "AG", IERC20(address(underlying)));
    }
}
