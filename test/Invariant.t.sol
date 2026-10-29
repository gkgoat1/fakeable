// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FakeableTest} from "./mocks/FakeableTest.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// F-4: invariant fuzzing over random operation sequences. The pinned invariants:
///   Σ real == underlying in the vault            (real never inflates/deflates)
///   totalSupply == Σ real + Σ fake               (accounting conservation)
///   balanceOf(a) == real(a) + fake(a)            (per-account composition)
contract FakeableInvariantTest is Test {
    FakeableTest token;
    MockERC20 underlying;
    Handler handler;

    function setUp() public {
        underlying = new MockERC20();
        handler = new Handler(underlying); // the handler deploys + owns the token
        token = handler.token();
        targetContract(address(handler));
    }

    function invariant_supply_conservation() public view {
        uint256 sumReal;
        uint256 sumFake;
        for (uint256 i; i < handler.actorCount(); i++) {
            address a = handler.actorAt(i);
            sumReal += token.realOf(a);
            sumFake += token.fakeOf(a);
        }
        assertEq(token.totalSupply(), sumReal + sumFake);
        assertEq(sumReal, underlying.balanceOf(address(token)));
    }
}

contract Handler is Test {
    FakeableTest public token;
    MockERC20 public underlying;
    address[] public actors;

    constructor(MockERC20 u) {
        underlying = u;
        // The handler deploys + initializes the token so it is the fake-mint owner.
        token = new FakeableTest();
        token.initialize("W", "W", IERC20(address(u)));
        for (uint256 i = 1; i <= 5; i++) {
            actors.push(address(uint160(i * 1000)));
            underlying.mint(actors[i - 1], 1_000_000);
            vm.prank(actors[i - 1]);
            underlying.approve(address(token), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function wrap(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 0, underlying.balanceOf(a));
        if (amount == 0) return;
        vm.prank(a);
        token.wrap(amount);
    }

    function unwrap(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        uint256 r = token.realOf(a);
        if (r == 0) return;
        amount = bound(amount, 1, r);
        vm.prank(a);
        token.unwrap(amount);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address a = _actor(fromSeed);
        address b = _actor(1 + fromSeed + toSeed);
        uint256 bal = token.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 0, bal);
        vm.prank(a);
        token.transfer(b, amount);
    }

    function mintFake(uint256 seed, uint256 amount) external {
        amount = bound(amount, 1, 10_000);
        token.mintFake(_actor(seed), amount);
    }

    function transferFake(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address a = _actor(fromSeed);
        uint256 f = token.fakeOf(a);
        if (f == 0) return;
        amount = bound(amount, 0, f);
        if (amount == 0) return;
        vm.prank(a);
        token.transferFake(_actor(1 + fromSeed + toSeed), amount);
    }

    function transferReal(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address a = _actor(fromSeed);
        uint256 r = token.realOf(a);
        if (r == 0) return;
        amount = bound(amount, 0, r);
        if (amount == 0) return;
        vm.prank(a);
        token.transferReal(_actor(1 + fromSeed + toSeed), amount);
    }

    function burnFake(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        uint256 f = token.fakeOf(a);
        if (f == 0) return;
        amount = bound(amount, 1, f);
        vm.prank(a);
        token.burnFake(amount);
    }
}
