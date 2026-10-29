// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20Upgradeable} from "openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
// OZ 5.x: the base ReentrancyGuard is proxy-safe (ERC-7201 namespaced storage) —
// there is no upgradeable variant anymore.
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// FakeableERC20 — an abstract, upgradeable-compatible wrapped ERC20 with real/fake
/// balance components (fakeable/PLAN.md v2).
///
/// Every account carries `real` (asset-backed, redeemable) + `fake` (synthetic,
/// non-redeemable) components; `balanceOf` = the sum, `totalSupply` = Σreal + Σfake.
/// Normal transfers move both legs PROPORTIONALLY (floor on the real leg, fake
/// absorbs the dust); each leg also has a specific path (transferFake/transferReal
/// plus `*From` allowance variants); fake mint is gated by the derived contract's
/// `_authorizeFakeMint`; wrap/unwrap move underlying through a vault seam (self by
/// default, external vaults supported).
///
/// Invariants the tests pin: fake never redeems; real never inflates (Σreal ==
/// vault underlying balance); the beacon upgrade path can never re-set the
/// underlying or the vault.
abstract contract FakeableERC20 is ERC20Upgradeable, ReentrancyGuard {
    /// @custom:storage-location erc7201:fakeable.erc20.v1
    struct FakeableStorage {
        /// Synthetic (non-redeemable) balances; the inherited ERC20 `_balances` is
        /// the REAL (asset-backed) ledger.
        mapping(address => uint256) fake;
        uint256 fakeSupply;
        /// The wrapped asset, set once at init (never re-set — not even on upgrade).
        IERC20 underlying;
        /// The vault holding the underlying (default: the instance itself).
        address vault;
        uint8 decimals;
    }

    // keccak256(abi.encode(uint256(keccak256("fakeable.erc20.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT =
        0x2aca9a3a2fee8fed96042df01d4c28856b63ef7691bb29763035cdcd161ed200;

    function _storage() private pure returns (FakeableStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    event Wrapped(address indexed account, uint256 amount);
    event Unwrapped(address indexed account, uint256 amount);
    event FakeMinted(address indexed caller, address indexed to, uint256 amount);
    event FakeBurnt(address indexed caller, address indexed from, uint256 amount);
    /// Emitted alongside the standard Transfer for specific-leg moves.
    event FakeMoved(address indexed from, address indexed to, uint256 amount);
    event RealMoved(address indexed from, address indexed to, uint256 amount);

    error FakeableAlreadyInitialized();
    error InsufficientReal();
    error InsufficientFake();
    error UnauthorizedMinter(address caller);

    /// @notice The wrapped asset (set once at init).
    function underlying() public view returns (IERC20) {
        return _storage().underlying;
    }

    /// @notice The vault holding the underlying (self when unset).
    function vault() public view returns (address) {
        address v = _storage().vault;
        return v == address(0) ? address(this) : v;
    }

    function decimals() public view override returns (uint8) {
        return _storage().decimals;
    }

    function fakeOf(address account) public view returns (uint256) {
        return _storage().fake[account];
    }

    /// @notice The real (asset-backed, redeemable) component.
    function realOf(address account) public view returns (uint256) {
        return super.balanceOf(account);
    }

    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account) + _storage().fake[account];
    }

    /// @notice The real (asset-backed) total supply.
    function realSupply() public view returns (uint256) {
        return super.totalSupply();
    }

    function fakeSupply() public view returns (uint256) {
        return _storage().fakeSupply;
    }

    function totalSupply() public view override returns (uint256) {
        return super.totalSupply() + _storage().fakeSupply;
    }

    /// Base initializer: ERC20 name/symbol, reentrancy guard, underlying, decimals.
    function __FakeableERC20_init(string memory name_, string memory symbol_, IERC20 underlying_) internal onlyInitializing {
        __ERC20_init(name_, symbol_);
        // ReentrancyGuard has no initializer in 5.x (storage is 7201-namespaced).
        FakeableStorage storage $ = _storage();
        if (address($.underlying) != address(0)) revert FakeableAlreadyInitialized();
        $.underlying = underlying_;
        // decimals via a low-level staticcall with an 18 fallback (some underlyings
        // lack the method).
        (bool ok, bytes memory data) = address(underlying_).staticcall(abi.encodeWithSignature("decimals()"));
        $.decimals = ok && data.length >= 32 && uint8(uint256(bytes32(data))) != 0
            ? uint8(uint256(bytes32(data)))
            : 18;
    }

    /// Derived-contract hook (external vaults, plan §2.3): the vault is init-once.
    function _setVault(address vault_) internal onlyInitializing {
        _storage().vault = vault_;
    }

    /// Derived-contract hook: the fake-minting policy (owner minting, a
    /// transfer-from-existing reserve, …) — the base never names a minter.
    function _authorizeFakeMint(address caller) internal view virtual returns (bool);

    // -----------------------------------------------------------------------
    // Movement core (the derived contract never reimplements the math)
    // -----------------------------------------------------------------------

    /// Proportional move (plan §2.1): real leg floor, fake leg remainder.
    function _moveProportional(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0)) revert("zero address");
        FakeableStorage storage $ = _storage();
        uint256 r = super.balanceOf(from);
        uint256 f = $.fake[from];
        uint256 s = r + f;
        require(s >= amount, "ERC20: transfer amount exceeds balance");
        if (amount == 0) return;
        uint256 realMoved = (amount * r) / s; // s > 0 here
        uint256 fakeMoved = amount - realMoved;
        // The real leg rides the ERC20 ledger (one Transfer event); the fake leg
        // gets a second Transfer — the two sum to `amount`, keeping indexers exact.
        if (realMoved != 0) _update(from, to, realMoved);
        if (fakeMoved != 0) {
            $.fake[from] = f - fakeMoved;
            $.fake[to] += fakeMoved;
            emit Transfer(from, to, fakeMoved);
        }
    }

    function _moveFake(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0)) revert("zero address");
        FakeableStorage storage $ = _storage();
        if ($.fake[from] < amount) revert InsufficientFake();
        $.fake[from] -= amount;
        $.fake[to] += amount;
        emit Transfer(from, to, amount);
        emit FakeMoved(from, to, amount);
    }

    function _moveReal(address from, address to, uint256 amount) internal {
        if (super.balanceOf(from) < amount) revert InsufficientReal();
        _update(from, to, amount);
        emit RealMoved(from, to, amount);
    }

    function _mintFake(address to, uint256 amount) internal {
        FakeableStorage storage $ = _storage();
        $.fake[to] += amount;
        $.fakeSupply += amount;
        emit Transfer(address(0), to, amount);
        emit FakeMinted(msg.sender, to, amount);
    }

    function _burnFake(address from, uint256 amount) internal {
        FakeableStorage storage $ = _storage();
        if ($.fake[from] < amount) revert InsufficientFake();
        $.fake[from] -= amount;
        $.fakeSupply -= amount;
        emit Transfer(from, address(0), amount);
        emit FakeBurnt(msg.sender, from, amount);
    }

    // -----------------------------------------------------------------------
    // Public surface
    // -----------------------------------------------------------------------

    function transfer(address to, uint256 amount) public override returns (bool) {
        _moveProportional(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _moveProportional(from, to, amount);
        return true;
    }

    function transferFake(address to, uint256 amount) external returns (bool) {
        _moveFake(msg.sender, to, amount);
        return true;
    }

    function transferFakeFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _moveFake(from, to, amount);
        return true;
    }

    function transferReal(address to, uint256 amount) external returns (bool) {
        _moveReal(msg.sender, to, amount);
        return true;
    }

    function transferRealFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _moveReal(from, to, amount);
        return true;
    }

    function burnFake(uint256 amount) external {
        _burnFake(msg.sender, amount);
    }

    function burnFakeFrom(address from, uint256 amount) external {
        _spendAllowance(from, msg.sender, amount);
        _burnFake(from, amount);
    }

    /// Real burn (markets redemption path): the underlying stays in the vault — the
    /// caller's protocol (e.g. an Event) settles the payout separately.
    function burnReal(uint256 amount) external {
        if (super.balanceOf(msg.sender) < amount) revert InsufficientReal();
        _burn(msg.sender, amount);
    }

    function burnRealFrom(address from, uint256 amount) external {
        _spendAllowance(from, msg.sender, amount);
        if (super.balanceOf(from) < amount) revert InsufficientReal();
        _burn(from, amount);
    }

    /// Privileged fake mint — the policy is the derived contract's.
    function mintFake(address to, uint256 amount) external {
        if (!_authorizeFakeMint(msg.sender)) revert UnauthorizedMinter(msg.sender);
        _mintFake(to, amount);
    }

    // -----------------------------------------------------------------------
    // wrap / unwrap (vault seam — self by default, external via overrides)
    // -----------------------------------------------------------------------

    /// Wrap: credits the vault-balance DELTA as real (fee-on-transfer/rebasing
    /// underlyings supported).
    function wrap(uint256 amount) external virtual nonReentrant {
        FakeableStorage storage $ = _storage();
        IERC20 u = $.underlying;
        address v = vault();
        uint256 before = u.balanceOf(v);
        _depositUnderlying(u, v, amount);
        uint256 received = u.balanceOf(v) - before;
        _mint(msg.sender, received);
        emit Wrapped(msg.sender, received);
    }

    /// Unwrap: burns REAL only (fake never redeems) and pays out of the vault.
    function unwrap(uint256 amount) external virtual nonReentrant {
        if (super.balanceOf(msg.sender) < amount) revert InsufficientReal();
        _burn(msg.sender, amount);
        _withdrawUnderlying(_storage().underlying, vault(), msg.sender, amount);
        emit Unwrapped(msg.sender, amount);
    }

    /// Vault seam: the default holds underlying on the instance. Derived contracts
    /// override for an external vault (the vault must let the instance pay out).
    function _depositUnderlying(IERC20 u, address v, uint256 amount) internal virtual {
        require(u.transferFrom(msg.sender, v, amount), "deposit failed");
    }

    function _withdrawUnderlying(IERC20 u, address v, address to, uint256 amount) internal virtual {
        v;
        require(u.transfer(to, amount), "withdraw failed");
    }

    /// Storage gap for future base-contract additions (derived storage lives after).
    uint256[50] private __gap;
}
