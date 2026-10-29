# Fakeable Wrapped Token — PLAN v1 (draft for review)

**Status:** DRAFT v2 — owner review round 1 incorporated (§9 decisions). This repo is
independent (separately pushable to GitHub/Radicle; the eth superproject ignores it).
Implementation begins on approval; on approval it integrates into `MASTER-PLAN.md`.

**One-line:** an abstract, upgradeable-compatible ERC20 base contract for wrapping an
ERC20 into a token with real (redeemable) and fake (non-redeemable) balance
components — normal transfers move both proportionally, fake tokens have a custom
specific-transfer/burn path, and instances deploy as beacon proxies upgradable in
one beacon transaction.

## 1. Context and goals

The future system needs a wrapped token with synthetic-balance semantics: accounts
carry a promotion/incentive component ("fake") alongside the asset-backed component
("real"). The base contract OWNS the real/fake bookkeeping, the proportional-transfer
math, the privileged fake lifecycle, and the beacon-proxy deployment surface — so the
future system inherits all of it and supplies only its policy (who mints fake, caps,
allowed underlyings, fees) through extension hooks.

Goals (this repo):

1. `FakeableERC20` — an abstract OZ-upgradeable-compatible ERC20 base: wrap, unwrap,
   proportional transfers, specific-fake transfer, fake mint/burn.
2. Deployed instances are ERC-1967 beacon proxies (`BeaconProxy`) over a shared
   `UpgradeableBeacon` implementation — upgrade the logic for every wrapped token in
   one beacon transaction.
3. Future-system hooks: the derived contract decides the minter, caps, and any fees —
   the base enforces the mechanic (real never printed, fake never redeemed) without
   knowing the downstream policy.
4. Full forge suite + size-checked implementation (EIP-170 discipline from day one —
   the base must leave the derived contracts headroom).

Non-goals (stay in the future system, OQ-1..OQ-4): the minter identity, mint caps,
underlying registry, fees/rebates policy, any dapp UI.

## 2. Tokenomics semantics (normative)

Every account's wrapped balance splits: `real[acct]` (asset-backed, redeemable) and
`fake[acct]` (synthetic, non-redeemable). Invariants:

- `balanceOf(a) == real[a] + fake[a]`; `totalSupply() == Σreal + Σfake`.
- Fake is NEVER redeemable: `unwrap(n)` requires `real[msg.sender] ≥ n` and reduces
  real only, paying underlying `n` from the vault.
- Real is never printed: real increases only via `wrap` (1:1 with underlying pulled
  in) and transfers in (already-existing real).
- Both components move in `balanceOf`/`totalSupply`, allowances count wrapped units
  (real+fake fungible for transfer purposes).

### 2.1 The proportional rule (normal transfers)

For `transfer(to, amount)` / `transferFrom(from, to, amount)` with sender composition
`(r, f)`, `s = r + f`:

```text
realMoved = amount * r / s          (integer floor; r=f=0 is impossible when moving)
fakeMoved = amount - realMoved      (the remainder rides fake)
```

Rounding: floor the real leg, fake absorbs the dust. Rationale: real is the
constrained resource (underlying-backed); dust must never create redeemable units out
of nothing, and fake is the flexible/synthetic leg. Single wei dust on tiny transfers
rounds real down — one-way, never inflating real.

Zero-leg shortcuts (exact, no math): `r == 0 ⇒ realMoved = 0`, `f == 0 ⇒ fakeMoved = 0`.

Accounting after the move: sender `(r − realMoved, f − fakeMoved)`, receiver
`(r' + realMoved, f' + fakeMoved)`. A zero-balance receiver inherits the moved
ratio; a funded receiver's own ratio shifts toward the moved ratio (composition is
per-account, never global).

`approve`/`allowance` are composition-blind (ERC-20 standard).

### 2.2 The specific-leg lifecycle (custom methods)

Fake AND real each get a specific path; the standard allowance carries the
`*From` variants (allowances stay composition-blind — a spender's allowance covers
wrapped units, and a specific-leg call just fails if that leg is short):

- `mintFake(to, amount)` — privileged (abstract minter gate, §3.1). Creates fake.
- `transferFake(to, amount)` / `transferFakeFrom(from, to, amount)` — exact fake
  move; requires `fake ≥ amount`; real untouched.
- `transferReal(to, amount)` / `transferRealFrom(from, to, amount)` — exact real
  move; requires `real ≥ amount`; fake untouched.
- `burnFake(amount)` / `burnFakeFrom(from, amount)` — destroys fake; totalSupply
  falls accordingly.
- Unwrap never touches fake; a fully-fake account cannot unwrap anything.

### 2.3 wrap / unwrap

- `wrap(amount)`: pull underlying into the vault and mint the RECEIVED amount as real
  — measured as the vault's `balanceOf` delta, so fee-on-transfer and rebasing
  underlyings are supported (the mint credits what actually arrived).
- `unwrap(amount)`: require `real[caller] ≥ amount` (reverts even if `balanceOf ≥
  amount` — the standard trap), burn real, pay `amount` underlying out of the vault.
- The vault is a seam, not a fixed choice: `_vault()` virtual (default: the instance
  itself) plus virtual `_depositUnderlying(amount)` / `_withdrawUnderlying(to, amount)`
  — the future system overrides to route through its external vault.
- Decimals: read `decimals()` at init via a low-level staticcall with an 18 fallback
  (underlyings without the method).
- Underlying is fixed at initialization (immutable-per-instance storage; the
  `upgrade()` path can never swap it — swapping the backing asset under holders is a
  footgun by design impossible).

### 2.4 The transfer matrix (reference)

| Call | Moves real? | Moves fake? |
| --- | --- | --- |
| `transfer` / `transferFrom` | yes — `amount*r/s` (floor) | yes — remainder |
| `transferFake` / `transferFakeFrom` | no | yes — exact |
| `transferReal` / `transferRealFrom` | yes — exact | no |
| `mintFake` (privileged) | no | creates |
| `burnFake` / `burnFakeFrom` | no | destroys |
| `wrap` | creates (received-amount underlying) | no |
| `unwrap` | destroys (pays underlying) | no (must be real-backed) |

## 3. Contract architecture

### 3.1 The abstract base (`src/FakeableERC20.sol`)

Layout: inherits `ERC20Upgradeable` (name/symbol via initializer), `Initializable`,
`OwnableUpgradeable` (future-system owner = beacon admin-ish; the base leaves ownership
semantics to the derived contract — ownable is for instance-level admin such as
emergency naming, NOT the beacon).

- Reuses ERC20's `_balances` as the **real** ledger; a new `mapping(address => uint256)
  _fake` holds fake. (`_totalSupply` = real supply; `totalSupply()` overridden to
  return `_totalSupply + _fakeSupply`, where `_fakeSupply` is a new counter.)
- `balanceOf` overridden: `_balances[a] + _fake[a]`.
- The movement core is THREE internal functions the base owns (the derived contract
  never touches the math):
  - `_moveProportional(from, to, amount)` — implements §2.1 and emits the standard
    `Transfer` event (once, for `amount` — indexers see standard ERC-20).
  - `_moveFake(from, to, amount)` / `_moveReal(from, to, amount)` — exact single-leg
    moves; emit `Transfer` (standard — both legs ARE wrapped units for accounting)
    AND `FakeMoved` / `RealMoved`.
  - `_mintFake(to, amount)` / `_burnFake(from, amount)` — fake lifecycle; emit
    `Transfer` (zero-address legs) AND `FakeMinted` / `FakeBurnt`.
  - `wrap`/`unwrap` call ERC20's `_mint`/`_burn` (real legs) — inherited, unchanged —
    plus `Wrapped`/`Unwrapped` events.
- Public `transfer`/`transferFrom` are overridden to call `_moveProportional`
  (allowance plumbing inherited untouched).
- Abstract extension surface (the future system implements these; the base calls them):
  - `abstract function _authorizeFakeMinter(address minter) internal view virtual returns (bool)` —
    `mintFake` requires it. The gate is PURELY abstract (owner decision round 1): the
    future system will combine owner minting with a transfer-from-existing model (a
    reserve account drained via `transferFakeFrom` allowances); any policy is
    implementable because the base never names a minter.
  - `abstract function underlying() public view virtual returns (IERC20)`
    (storage slot for the instance's underlying, set once in the initializer).
  - Optional hooks: `_beforeWrap/_afterWrap`, `_beforeUnwrap/_afterUnwrap`
    (no-op defaults — fee/open-fee extension points the future system can fill).

### 3.2 Deployment surface: beacon proxies, one beacon transaction upgrades all

- The future system deploys ONE concrete derived implementation, ONE
  `UpgradeableBeacon(impl)` plus a `FakeableFactory` (base-owned):
  `createWrapper(underlying, name, symbol)` → deploys `BeaconProxy(beacon, initData)`
  where initData calls the derived `initialize(underlying, name, symbol, admin)`.
- Per-instance init data is baked into each proxy's constructor args — the underlying
  is instance state, set ONCE (initializer `reinitializer`-guarded single-set; the
  beacon upgrade path cannot re-set it). The vault follows the same rule: set at init
  (default self); a derived external-vault override points at a fixed address.
- The beacon admin is the future system's owner (multisig/Safe eventually) — the base
  only exposes upgrade through the beacon, never through instances.

### 3.3 Upgrade compatibility

- OZ upgradeable pattern throughout: `Initializable`, no constructors in the base,
  `__gap[50]` in the base contract, ERC-7201 namespaced storage for the NEW fake
  state (`keccak256("fakeable.erc20.v1")` slot holding `_fake` mapping + `_fakeSupply`)
  so derived contracts can append storage without shifting the base layout.
- No storage in the abstract contract outside the namespaced struct.
- The derived-implementation bytecode must stay EIP-170-safe with headroom (the base
  budget: ≤ 16 KiB implementation so derivatives have room — CI-enforced via
  `forge build --sizes`).

## 4. Events

- Standard: `Transfer` emitted for every movement incl. fake legs and wrap/unwrap
  (wraps = from/to zero address — indexers see a normal ERC-20).
- `Wrapped(account, underlying, amount)`, `Unwrapped(account, underlying, amount)`
- `FakeMinted(minter, to, amount)`, `FakeMoved(from, to, amount)`,
  `FakeBurnt(from, amount)`, `WrapperCreated(proxy, underlying)`.

## 5. Security considerations (to be pinned by tests)

1. **Fake must never redeem**: `unwrap` pulls ONLY from `_balances` (real); there is no
   code path that pays underlying against fake. Regression-test: full-fake account
   unwraps 1 wei → reverts.
2. **Real must never inflate**: `transfer`/`transferFrom` move existing units only;
   `mintFake` touches `_fake` only; property test: `Σ(real)` never exceeds underlying
   ever deposited minus underlying withdrawn (forge invariant test with a handler).
3. **Rounding dust**: floor-real/remainder-fake is one-way (never inflates real);
   fuzz-transfer property: sender + receiver `(r, f)` conserved across every move.
4. **Reentrancy**: `wrap`/`unwrap` interact with arbitrary ERC20s — CEI + a
   `nonReentrant` guard on both (OZ `ReentrancyGuardUpgradeable`).
4b. **Fee-on-transfer / rebasing underlyings are supported**: wrap credits the
   vault-balance DELTA (not the requested amount); a deflationary underlying simply
   mints less. Tests include a fee-on-transfer mock underlying.
4c. **External vaults**: the derived contract's vault receives wrap deposits and must
   let the instance pay out on unwrap (the vault's payout authorization is the
   future system's design surface; the base's seam is deposit/withdraw only).
5. **Beacon trust**: beacon admin can replace ALL logic — the future system owns that
   key; the base documents it and emits `Upgraded`-family events via OZ.
6. **Approval-aliasing**: `transferFrom` prorates at execution composition — a spender
   can't drain real specifically; document (no `transferFakeFrom` on the base — OQ-3).

## 6. Test plan (forge)

- Unit: wrap/unwrap round-trip (incl. a fee-on-transfer mock underlying — minted real
  equals the received delta), mintFake/burnFake lifecycle, gated minter
  (unauthorized mints revert), transferFake/transferReal exactness, the `*From`
  allowance variants, transfer proportionality on mixed/ratio accounts + edge
  compositions (0/100, 100/0, 1-wei dust, full-supply moves), external-vault wiring
  (a mock vault overriding the seam), decimals fallback (an underlying without the
  method).
- Fake-redeem gate: unwrap with `balanceOf ≥ n` but `real < n` reverts; full-fake
  account always reverts.
- Invariant (handler fuzz): conservation of `(real, fake, underlying)` across random
  wrap/unwrap/transfer/mint/burn sequences; `Σreal == underlying.balanceOf(vault)`.
- Upgrade: deploy V2 (adds a view) via the beacon; storage preserved; events identical.
- Size: `forge build --sizes` gate ≤ 16 KiB implementation.
- Back-compat: every emitted `Transfer` matches what a vanilla ERC-20 indexer expects.

## 7. Milestones

- **F-1** Abstract base: storage, initializer, wrap/unwrap, internal movement core,
  events. (Forge unit green.)
- **F-2** Public surface: transferFrom/transfer overrides, transferFake/burnFake/
  mintFake + `_authorizeFakeMinter`, hooks.
- **F-3** Factory + beacon deployment; per-instance underlying init-once; upgrade
  regression test.
- **F-4** Invariants + fuzzing; fee-on-transfer-underlying hostility tests; size gate.
- **F-5** Docs (NatSpec + README), master-plan integration, interface freeze for the
  future system.

## 8. Decisions (owner review round 1) + remaining open questions

- **OQ-1 → yes**: `transferReal` on the base, and `*From` allowance variants for the
  specific-leg methods (`transferFakeFrom`, `transferRealFrom`, `burnFakeFrom`).
- **OQ-2 → support**: fee-on-transfer/rebasing underlyings — wrap credits the vault
  balance delta.
- **OQ-3 → yes**: the allowance variants live on the base (§2.2).
- **OQ-4 → abstract**: the minter gate stays purely abstract; the future system
  combines owner minting with a transfer-from-existing reserve model; any policy is
  expressible.
- **OQ-5 → external vaults supported**: the `_vault()` + deposit/withdraw seam; the
  future system has its own vault.
- **OQ-6 → fallback**: `decimals()` low-level staticcall at init, 18 fallback.
