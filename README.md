# FakeableERC20 — abstract wrapped ERC20 with real/fake balance components

A wrapped token for the future system: accounts carry **real** (asset-backed,
redeemable) + **fake** (synthetic, non-redeemable) balances. Normal transfers move
both proportionally (floor on the real leg, fake absorbs the dust); each leg has an
exact specific-transfer path; fake mint/burn are privileged; wrap measures the
vault's received delta (fee-on-transfer safe); instances deploy as beacon proxies.

## Layout

- `src/FakeableERC20.sol` — the abstract base (OZ upgradeable-compatible:
  `Initializable`, ERC-7201 namespaced storage `fakeable.erc20.v1`, 50-slot gap).
- `src/FakeableFactory.sol` — deploys beacon-proxied wrappers over one
  `UpgradeableBeacon`; one beacon upgrade upgrades every instance.
- `test/` — `FakeableCore.t.sol` (14 tests), `FactoryBeacon.t.sol` (3, incl. the
  upgrade regression), `Invariant.t.sol` (conservation fuzzer).
- `test/mocks/` — the concrete `FakeableTest` (owner-gated minter) and ERC20 mocks.

## For the future system (interface freeze)

Implement on derivation:
- `_authorizeFakeMint(caller)` — the minting policy (owner minting,
  transfer-from-existing reserves, anything else).
- The init-once `underlying` (via `__FakeableERC20_init`); override `_setVault` for
  an external vault (the vault pays out on `unwrap`).
- The derived contract owns beacon admin + naming.

Functions the future system gets: `wrap`, `unwrap`, `transfer`, `transferFrom`,
`transferFake(+From)`, `transferReal(+From)`, `burnFake(+From)`, `mintFake`,
plus views `balanceOf`, `realOf`, `fakeOf`, `totalSupply`, `underlying`, `vault`.

## Gates

`forge test` (19 green), `forge build --sizes` (impl ≤ 16 KiB — currently ~12 KiB).
